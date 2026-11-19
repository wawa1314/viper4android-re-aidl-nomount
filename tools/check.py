#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 PortableGit 的 bash -n 对模块里所有 shell 脚本做语法检查 + NoMount 规则模拟。"""
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding='utf-8')

BASH = r'D:\tools\PortableGit\usr\bin\bash.exe'
BUILD = Path(r'D:\Documents\工作区\作业\ViPER4Android-nomount\工作脚本\build')
SH = Path(r'D:\Documents\工作区\作业\移除温控-nomount\工作脚本\sim_rules.py')

TARGETS = ['customize.sh', 'service.sh', 'post-fs-data.sh', 'uninstall.sh',
           'META-INF/com/google/android/update-binary']


def main():
    ok = True
    for name in TARGETS:
        p = BUILD / name
        if not p.exists():
            print('MISSING', name)
            ok = False
            continue
        raw = p.read_bytes()
        bom = raw[:3] == b'\xef\xbb\xbf'
        crlf = b'\r\n' in raw
        # bash -n 需要可读路径；PortableGit 能直接吃 Windows 路径
        r = subprocess.run([BASH, '-n', str(p)], capture_output=True, text=True,
                           encoding='utf-8', errors='replace')
        status = '语法OK' if r.returncode == 0 else '语法错'
        if r.returncode != 0:
            ok = False
        print('%-46s %s  BOM=%s CRLF=%s' % (name, status, bom, crlf))
        if r.stderr.strip():
            for line in r.stderr.strip().splitlines():
                print('      ', line)

    # 关键内容核对
    print()
    checks = [
        ('customize.sh', 'rm -f $MODPATH/skip_mount $MODPATH/skip_mountify', True),
        ('customize.sh', 'touch $MODPATH/skip_mount', False),
        ('customize.sh', 's|^/odm|/odm|g', True),
        ('customize.sh', 's|^/odm|/system/vendor/odm|g', False),
        ('service.sh', 'find "$MODDIR/system" "$MODDIR/odm"', True),
        ('service.sh', '[ -f "$MODDIR/skip_mount" ] && SELF_MOUNT=true', False),
        ('post-fs-data.sh', '"$MODDIR"/odm/etc/audio_effects*.xml', True),
        ('module.prop', 'version=v2.1.2-nomount', True),
        ('module.prop', 'versionCode=20261119', True),
    ]
    for name, needle, want in checks:
        got = needle in (BUILD / name).read_text(encoding='utf-8')
        flag = '✓' if got == want else '✗'
        if got != want:
            ok = False
        print('  %s %s: %r 存在=%s 期望=%s' % (flag, name, needle[:44], got, want))

    print()
    print('残留标记文件:', [m for m in ('skip_mount', 'skip_mountify') if (BUILD / m).exists()])
    print('\n总体:', 'PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
