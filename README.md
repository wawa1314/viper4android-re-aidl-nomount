# ViPER4Android RE (AIDL) v2.1.2-nomount

基于上游 [ViPER4Android RE (AIDL)](https://github.com/likelikeslike/ViPERFX_RE) v2.1.2（2026-11-16）的修改版，**只改挂载方式**：从「模块自己 bind 挂载」改为「交给 NoMount 元模块做 VFS 路径注入」。

## 为什么改

上游在 KernelSU / APatch 下会主动打 `skip_mount`、`skip_mountify` 两个标记，让所有元模块整个跳过本模块，然后开机自己 `mount -o bind`。这与 NoMount 元模块的注入机制互斥（`metamount.sh` 见到 `skip_mount` 直接 continue）。

## 改了什么（其余与上游逐字节一致）

1. 删除 `skip_mount` / `skip_mountify` 标记
2. `/odm` 的配置产物从 `system/vendor/odm/etc` 改到模块根顶层 `odm/etc`
   - 原因：NoMount 的 `rule-paths.sh` 只把 `system/` 后**第一段**当分区名映射，`system/vendor/odm/...` 会被算成 `/vendor/odm/...`（真实路径是 `/odm/...`），注入白做
3. `service.sh` 不再看 `skip_mount` 标记决定是否自挂，改为：挂载函数自带自跳过守卫（目标已有 `libv4a_aidl.so` 就 return、配置内容 `cmp -s` 一致就跳过），元模块注入到位时自动不重复 bind；没装元模块时行为与上游一致
4. `module.prop`：`version=v2.1.2-nomount`，`versionCode=20261119`

## 使用前提

- 先安装 **NoMount 元模块 v2.2.0+**（驱动协议 v22）并重启，再刷本包
- Android 15+（API 35+），AIDL 音频 HAL
- 音频逻辑、so 本体、audio_effects 配置内容、sepolicy 均未动

## 验证注入

```
cat /data/adb/viper_install.log
/data/adb/modules/nomount/bin/nm rule list | grep -iE 'v4a|audio_effects'
```

## 目录

- 模块源码：根目录（`module.prop`、`customize.sh`、`service.sh`、`post-fs-data.sh`、`sepolicy.rule`、`uninstall.sh`、`META-INF/`、`common/`）
- 制作脚本：`tools/`（`apply_patch.py` 一键改造、`pack_module.py` 打包、`check.py` 语法+内容校验）
- 成品刷机包在发行版附件里，不进 git

## 说明

- `/apex/*` 下的音效库 NoMount 不接管，仍由 `service.sh` 自挂载补（目标已有时自动跳过）
- `updateJson` 仍指向作者上游，走云更新会被覆盖回原版；手动刷不受影响
