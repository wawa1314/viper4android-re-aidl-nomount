#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 ViPER4Android-RE-AIDL 从「自己 bind 挂载」改造成「走 NoMount 元模块注入」。

原包行为
--------
customize.sh 在 KernelSU/APatch 下无条件 touch skip_mount + skip_mountify，
让所有元模块整个跳过本模块，再由 service.sh 自己 mount -o bind。
NoMount 的 metamount.sh 判据是：
    if [ -f "$mod_path/disable" ] || [ -f "$mod_path/remove" ] || [ -f "$mod_path/skip_mount" ]; then continue
所以标记在，元模块就永远不会接管。

改动清单（只动挂载层；不碰音频逻辑 / so 本体 / 配置内容 / sepolicy）
--------------------------------------------------------------------
1) 删掉包根两个静态空标记 skip_mount、skip_mountify。

2) customize.sh：touch 标记改成 rm -f 标记（并清掉老版本残留）。

3) customize.sh：/odm 的配置产物从 $MODPATH/system/vendor/odm/etc 改到 $MODPATH/odm/etc。
   依据（读 NoMount 的 rule-paths.sh）：它只把 system/ 后**第一段**当分区名去掉，
   名单 vendor|system_ext|product|odm|apex|oem|optics|prism|mi_ext|my_*；
   system/vendor/odm 的第二段 odm 不在处理范围，结果是 system/vendor/odm/etc/x
   被映射成 /vendor/odm/etc/x，跟真实的 /odm/etc/x 不是一个路径，注入等于白做。
   模块根下放顶层 odm/ 才两边都对：NoMount 的 TARGET_PARTITIONS 含 odm，
   Magisk / KernelSU 的 magic mount 也认顶层分区目录。

4) service.sh：SELF_MOUNT 从「看有没有 skip_mount 文件」改成恒为 true。
   这不是"两条路都跑一遍"——原包的挂载函数内部本来就有自跳过守卫：
     - mount_effect_lib：目标目录已有 libv4a_aidl.so 就 return（第 35 行）
     - mount_config：patched 与原文件 cmp -s 相同就 return（第 122 行）
     - mount_bundled_config：/vendor/etc/audio_effects_config.xml 已存在就 return
   NoMount 的 VFS 注入会让这些探测直接命中，于是全部自跳过，实际不产生任何 bind；
   没装元模块时探测不命中，行为和原来完全一致。比再加一层探针更省、也更不会误判。

5) service.sh：mount_config 找 patched 文件的范围加上 $MODDIR/odm，并补 /odm 映射规则；
   ODM 缺失告警同时检查新旧两个路径。

6) post-fs-data.sh：ODM 手动 bind 的 glob 加上新路径（旧路径一并留着，兼容已刷过的模块）。

7) module.prop：version 加 -nomount，versionCode 递增（同码重装只写 staging 不覆盖）。

全部保持 UTF-8 无 BOM、LF。
"""
import shutil
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8')

ROOT = Path(__file__).resolve().parent
CASE = ROOT.parent
SRC_DIR = CASE / '原始包'
BUILD = CASE / '工作脚本' / 'build'

# ---------------- 1) customize.sh：不再打 skip 标记 ----------------
CUST_MOUNT_OLD = '''if [ -n "$KSU" ] || [ -n "$APATCH" ]; then
  touch $MODPATH/skip_mount
  touch $MODPATH/skip_mountify
else
  rm -f $MODPATH/skip_mount $MODPATH/skip_mountify
fi
'''
CUST_MOUNT_NEW = '''# 挂载交给 NoMount 元模块做 VFS 注入，所以这里不能再打 skip_mount：
# 元模块的 metamount.sh 见到 skip_mount 会整个跳过本模块。
# 从老版本升级过来时顺带清掉残留标记。
rm -f $MODPATH/skip_mount $MODPATH/skip_mountify
ui_print "- Mounting: hand over to NoMount metamodule (VFS redirection)"
log "skip_mount / skip_mountify removed; injection handled by metamodule"
'''

# ---------------- 2) customize.sh：/odm 落到顶层 odm/ ----------------
CUST_ODM_OLD = '''  local DEST="$MODPATH$(echo $SRC | sed "s|^/vendor|/system/vendor|g; s|^/odm|/system/vendor/odm|g")"'''
CUST_ODM_NEW = '''  # /odm 放模块根的顶层 odm/。不能放 system/vendor/odm：NoMount 只把 system/ 后
  # 第一段当分区名，第二段 odm 不认，会被错误映射成 /vendor/odm/etc
  local DEST="$MODPATH$(echo $SRC | sed "s|^/vendor|/system/vendor|g; s|^/odm|/odm|g")"'''

# ---------------- 3) service.sh：挂载判断交给函数内的自跳过守卫 ----------------
SVC_SELFMOUNT_OLD = '''SELF_MOUNT=false
[ -f "$MODDIR/skip_mount" ] && SELF_MOUNT=true
'''
SVC_SELFMOUNT_NEW = '''# 本模块不再打 skip_mount，挂载改由 NoMount 元模块接管，所以这里不能再靠
# skip_mount 文件判断。直接跑下去即可：下面的挂载函数本来就有自跳过守卫
# （目标已有 libv4a_aidl.so 就 return、配置内容已一致就 cmp 跳过），
# 元模块注入到位时它们会全部自跳过，不会产生多余的 bind。
SELF_MOUNT=true
'''

# ---------------- 4) service.sh：patched 配置查找范围加 odm ----------------
SVC_FIND_OLD = '''  for p in $(find "$MODDIR/system" -type f -name "$(basename "$original")" 2>/dev/null); do
    local mapped="$(echo "$p" | sed "s|$MODDIR/system/vendor/odm|/odm|; s|$MODDIR/system/vendor|/vendor|; s|$MODDIR/system|/system|")"'''
SVC_FIND_NEW = '''  for p in $(find "$MODDIR/system" "$MODDIR/odm" -type f -name "$(basename "$original")" 2>/dev/null); do
    local mapped="$(echo "$p" | sed "s|$MODDIR/odm|/odm|; s|$MODDIR/system/vendor/odm|/odm|; s|$MODDIR/system/vendor|/vendor|; s|$MODDIR/system|/system|")"'''

SVC_WARN_OLD = '''    if [ "$HAS_V4A" -eq 0 ] && [ -f "$MODDIR/system/vendor/odm/etc/${cfg##*/}" ] && [ "$dir" = /odm/etc ]; then'''
SVC_WARN_NEW = '''    if [ "$HAS_V4A" -eq 0 ] && { [ -f "$MODDIR/odm/etc/${cfg##*/}" ] || [ -f "$MODDIR/system/vendor/odm/etc/${cfg##*/}" ]; } && [ "$dir" = /odm/etc ]; then'''

# ---------------- 5) post-fs-data.sh：ODM bind 兼容新旧路径 ----------------
PFD_OLD = '''for cfg in "$MODDIR"/system/vendor/odm/etc/audio_effects*.xml; do'''
PFD_NEW = '''for cfg in "$MODDIR"/odm/etc/audio_effects*.xml "$MODDIR"/system/vendor/odm/etc/audio_effects*.xml; do'''

# ---------------- 6) module.prop ----------------
PROP_OLD = 'version=v2.1.2\nversionCode=20261116'
PROP_NEW = 'version=v2.1.2-nomount\nversionCode=20261119'


def patch(rel, pairs):
    p = BUILD / rel
    raw = p.read_bytes()
    assert raw[:3] != b'\xef\xbb\xbf', '%s 有 BOM' % rel
    text = raw.decode('utf-8')
    assert '\r\n' not in text, '%s 含 CRLF' % rel
    before = len(text.encode('utf-8'))
    for old, new in pairs:
        n = text.count(old)
        assert n == 1, '锚点在 %s 出现 %d 次（应为 1）:\n%s' % (rel, n, old[:120])
        text = text.replace(old, new, 1)
    out = text.encode('utf-8')
    assert b'\r\n' not in out
    p.write_bytes(out)
    print('  %-16s %6d -> %6d bytes' % (rel, before, len(out)))


def main():
    if BUILD.exists():
        shutil.rmtree(BUILD)
    shutil.copytree(SRC_DIR, BUILD)

    for m in ('skip_mount', 'skip_mountify'):
        f = BUILD / m
        if f.exists():
            f.unlink()
            print('  删除标记 %s' % m)

    patch('customize.sh', [(CUST_MOUNT_OLD, CUST_MOUNT_NEW),
                           (CUST_ODM_OLD, CUST_ODM_NEW)])
    patch('service.sh', [(SVC_SELFMOUNT_OLD, SVC_SELFMOUNT_NEW),
                         (SVC_FIND_OLD, SVC_FIND_NEW),
                         (SVC_WARN_OLD, SVC_WARN_NEW)])
    patch('post-fs-data.sh', [(PFD_OLD, PFD_NEW)])
    patch('module.prop', [(PROP_OLD, PROP_NEW)])

    print('改造完成 ->', BUILD)


if __name__ == '__main__':
    main()
