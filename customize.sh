SKIPUNZIP=1

V4A_LOG=/data/adb/viper_install.log

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [install] $1" >>$V4A_LOG; }

echo "" >$V4A_LOG
log "---> ViPER4Android AIDL Installation <---"

ui_print "**************************************"
ui_print "* ViPER4Android RE (AIDL) Installer  *"
ui_print "**************************************"
ui_print " "

log "Device: $(getprop ro.product.brand) $(getprop ro.product.model)"
log "ROM: $(getprop ro.build.display.id)"
log "Android: $(getprop ro.build.version.release) (API $API)"
log "Arch: $ARCH"
log "Kernel: $(uname -r)"
if [ -n "$KSU" ]; then
  log "Root: KernelSU $(ksud --version 2>/dev/null || echo unknown)"
elif [ -n "$APATCH" ]; then
  log "Root: APatch $(apd --version 2>/dev/null || echo unknown)"
elif [ -n "$MAGISK_VER" ]; then
  log "Root: Magisk $MAGISK_VER ($MAGISK_VER_CODE)"
else
  log "Root: unknown (su: $(which su 2>/dev/null || echo not found))"
fi
log "SELinux: $(getenforce 2>/dev/null || echo unknown)"
log "Audio HAL service: $(ps -A 2>/dev/null | grep -o 'android\.hardware\.audio[^ ]*' | head -1 || echo unknown)"
log "ro.audio.ignore_effects: $(getprop ro.audio.ignore_effects)"
log "ro.vendor.audio.effect.type: $(getprop ro.vendor.audio.effect.type)"
log "persist.vendor.audio.effects.enable: $(getprop persist.vendor.audio.effects.enable)"

if [ "$API" -lt 35 ]; then
  ui_print "! This module requires Android 15+ (API 35+)"
  ui_print "! Your device is API $API"
  ui_print "! Use the HIDL module (ViPER4Android-RE) instead"
  abort "! Aborting installation"
fi

if ! $BOOTMODE; then
  ui_print "- Only uninstall is supported in recovery"
  ui_print "  Uninstalling!"
  touch $MODPATH/remove
  recovery_cleanup
  rm -rf $TMPDIR 2>/dev/null
  exit 0
fi

if ! service list 2>/dev/null | grep -qi 'android.hardware.audio.effect.IFactory'; then
  ui_print "! AIDL audio effect HAL not detected"
  abort "! Use the HIDL module (ViPER4Android-RE) instead"
fi

ui_print "- Extracting module files"
unzip -o "$ZIPFILE" -x 'META-INF/*' -d $MODPATH >&2
# 挂载交给 NoMount 元模块做 VFS 注入，所以这里不能再打 skip_mount：
# 元模块的 metamount.sh 见到 skip_mount 会整个跳过本模块。
# 从老版本升级过来时顺带清掉残留标记。
rm -f $MODPATH/skip_mount $MODPATH/skip_mountify
ui_print "- Mounting: hand over to NoMount metamodule (VFS redirection)"
log "skip_mount / skip_mountify removed; injection handled by metamodule"

V4A_DIR=/data/local/tmp/v4a
if [ -d "$V4A_DIR" ]; then
  rm -rf "$V4A_DIR"
  ui_print "  Removed stale $V4A_DIR"
  log "Removed stale $V4A_DIR (legacy shm/kernel staging)"
fi

ui_print "- Installing for $ARCH SDK $API device..."
log "Installing for $ARCH SDK $API"

mkdir -p $MODPATH/system/vendor/lib/soundfx
mkdir -p $MODPATH/system/vendor/lib64/soundfx

if [ -f $MODPATH/common/files/libv4a_aidl_armeabi-v7a.so ]; then
  cp -f $MODPATH/common/files/libv4a_aidl_armeabi-v7a.so $MODPATH/system/vendor/lib/soundfx/libv4a_aidl.so
  ui_print "  Installed arm32 library"
  log "Installed arm32 library"
fi

if [ -f $MODPATH/common/files/libv4a_aidl_arm64-v8a.so ]; then
  cp -f $MODPATH/common/files/libv4a_aidl_arm64-v8a.so $MODPATH/system/vendor/lib64/soundfx/libv4a_aidl.so
  ui_print "  Installed arm64 library"
  log "Installed arm64 library"
fi

ui_print "- Setting up audio effects config"

V4A_LIB='<library name="v4a_aidl" path="libv4a_aidl.so"\/>'
V4A_EFFECT='<effect name="v4a_standard_aidl" library="v4a_aidl" uuid="90380da3-8536-4744-a6a3-5731970e640f" type="7261676f-6d75-7369-6364-28e2fd3ac39e"\/>'

patch_xml() {
  local SRC="$1"
  # /odm 放模块根的顶层 odm/。不能放 system/vendor/odm：NoMount 只把 system/ 后
  # 第一段当分区名，第二段 odm 不认，会被错误映射成 /vendor/odm/etc
  local DEST="$MODPATH$(echo $SRC | sed "s|^/vendor|/system/vendor|g; s|^/odm|/odm|g")"
  mkdir -p "$(dirname $DEST)"
  cp -f "$SRC" "$DEST"
  sed -i "/v4a_standard_aidl/d" "$DEST"
  sed -i "/v4a_aidl/d" "$DEST"
  sed -i "/<libraries>/ a\\        $V4A_LIB" "$DEST"
  sed -i "/<effects>/ a\\        $V4A_EFFECT" "$DEST"
  patch_device_effects "$DEST"
  ui_print "  Patched: $SRC"
  log "Patched: $SRC -> $DEST"
}

patch_device_effects() {
  local DEST="$1"
  grep -q "AUDIO_DEVICE_OUT_REMOTE_SUBMIX" "$DEST" && return 0
  local BLOCK='        <devicePort type="AUDIO_DEVICE_OUT_REMOTE_SUBMIX" address="">\n            <apply effect="v4a_standard_aidl"\/>\n        <\/devicePort>\n        <devicePort type="AUDIO_DEVICE_OUT_USB_DEVICE" address="">\n            <apply effect="v4a_standard_aidl"\/>\n        <\/devicePort>'
  if grep -q "<deviceEffects>" "$DEST"; then
    sed -i "/<deviceEffects>/ a\\$BLOCK" "$DEST"
  else
    sed -i "s|</audio_effects_conf>|    <deviceEffects>\n$BLOCK\n    </deviceEffects>\n</audio_effects_conf>|" "$DEST"
  fi
  log "Added REMOTE_SUBMIX + USB device effects: $DEST"
}

PATCHED=0
CONFIG_PATCHED=0
log "Scanning config dirs: /odm/etc /vendor/etc /system/etc /product/etc /system_ext/etc + SKU subdirs"
for dir in /odm/etc /vendor/etc /system/etc /product/etc /system_ext/etc; do
  for cfg in "$dir"/audio_effects*.xml; do
    [ -f "$cfg" ] || continue
    log "Found config: $cfg"
    patch_xml "$cfg"
    PATCHED=$((PATCHED + 1))
    case "$(basename "$cfg")" in
    *audio_effects_config.xml) CONFIG_PATCHED=$((CONFIG_PATCHED + 1)) ;;
    esac
  done
done

for sku_dir in /vendor/etc/audio/sku_*; do
  [ -d "$sku_dir" ] || continue
  for cfg in "$sku_dir"/audio_effects*.xml; do
    [ -f "$cfg" ] || continue
    log "Found config (SKU): $cfg"
    patch_xml "$cfg"
    PATCHED=$((PATCHED + 1))
    case "$(basename "$cfg")" in
    *audio_effects_config.xml) CONFIG_PATCHED=$((CONFIG_PATCHED + 1)) ;;
    esac
  done
done

if [ $CONFIG_PATCHED -eq 0 ]; then
  ui_print "  No audio_effects_config.xml found, using bundled template"
  log "No audio_effects_config.xml found on device, copying bundled template"
  mkdir -p $MODPATH/system/vendor/etc
  cp -f $MODPATH/common/audio_effects_config.xml $MODPATH/system/vendor/etc/audio_effects_config.xml
fi

if [ $PATCHED -eq 0 ]; then
  ui_print "  No configs found, using bundled template"
  log "WARNING: No audio_effects*.xml found on device, using bundled template"
  mkdir -p $MODPATH/system/vendor/etc
  cp -f $MODPATH/common/audio_effects_config.xml $MODPATH/system/vendor/etc/audio_effects_config.xml
fi
log "Total configs patched: $PATCHED (config.xml: $CONFIG_PATCHED)"

rm -rf $MODPATH/common

ui_print "- Declaring viper.control service type"
VENDOR_SC=/vendor/etc/selinux/vendor_service_contexts
SC_LINE='viper.control    u:object_r:viper_control_service:s0'
if [ -f "$VENDOR_SC" ]; then
  SC_DEST=$MODPATH/system/vendor/etc/selinux/vendor_service_contexts
  mkdir -p "$(dirname "$SC_DEST")"
  cp -f "$VENDOR_SC" "$SC_DEST"
  sed -i "\|^viper\.control[[:space:]]|d" "$SC_DEST"
  printf '%s\n' "$SC_LINE" >>"$SC_DEST"
  chcon u:object_r:vendor_service_contexts_file:s0 "$SC_DEST" 2>/dev/null
  ui_print "  Overlaid: $VENDOR_SC (+viper.control)"
  log "Overlaid vendor_service_contexts with viper.control -> viper_control_service"
else
  log "WARNING: $VENDOR_SC not found; viper.control will type as default_android_service"
fi

ui_print " "
ui_print "- Setting permissions"
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive $MODPATH/system/vendor/lib/soundfx 0 0 0755 0644
set_perm_recursive $MODPATH/system/vendor/lib64/soundfx 0 0 0755 0644
CHCON_ERR=$(chcon -R u:object_r:vendor_file:s0 $MODPATH/system/vendor/lib/soundfx 2>&1) || log "chcon lib/soundfx failed: $CHCON_ERR"
CHCON_ERR=$(chcon -R u:object_r:vendor_file:s0 $MODPATH/system/vendor/lib64/soundfx 2>&1) || log "chcon lib64/soundfx failed: $CHCON_ERR"
find $MODPATH -name 'audio_effects*.xml' | while read f; do
  CHCON_ERR=$(chcon u:object_r:vendor_configs_file:s0 "$f" 2>&1) || log "chcon failed: $f: $CHCON_ERR"
done

ui_print " "
ui_print "- Installation complete"
ui_print "- Reboot to activate"
ui_print "- Log: $V4A_LOG"

log "Installed files:"
find $MODPATH -type f -name '*.so' -o -name '*.xml' -o -name '*.rule' 2>/dev/null | while read f; do
  log "  $f ($(ls -lZ "$f" 2>/dev/null | awk '{print $1, $5}'))"
done
log "Installation complete"
