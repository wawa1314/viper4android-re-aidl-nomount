#!/system/bin/sh
MODDIR=${0%/*}

V4A_LOG=/data/adb/viper_install.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [service] $1" >>$V4A_LOG; }

log "---> service.sh start <---"

EFFECT_LIB="libv4a_aidl.so"
MOD_VENDOR="$MODDIR/system/vendor"
# 本模块不再打 skip_mount，挂载改由 NoMount 元模块接管，所以这里不能再靠
# skip_mount 文件判断。直接跑下去即可：下面的挂载函数本来就有自跳过守卫
# （目标已有 libv4a_aidl.so 就 return、配置内容已一致就 cmp 跳过），
# 元模块注入到位时它们会全部自跳过，不会产生多余的 bind。
SELF_MOUNT=true

ns_mount() {
  if nsenter -t 1 -m -- mount -o bind "$1" "$2" 2>/dev/null; then
    return 0
  fi
  mount -o bind "$1" "$2"
}

mount_effect_lib() {
  local SYS_TARGET="$1"
  local MOD_SOURCE_DIR="$2"
  local WORK_DIR="$MODDIR/work_mount$SYS_TARGET"

  if [ ! -d "$SYS_TARGET" ]; then
    log "mount_effect_lib: skip $SYS_TARGET (dir not found)"
    return
  fi
  if [ ! -f "$MOD_SOURCE_DIR/$EFFECT_LIB" ]; then
    log "mount_effect_lib: skip $SYS_TARGET (source lib not found in $MOD_SOURCE_DIR)"
    return
  fi
  if [ -f "$SYS_TARGET/$EFFECT_LIB" ]; then
    log "mount_effect_lib: skip $SYS_TARGET (lib already exists)"
    return
  fi

  [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR"

  CP_ERR=$(cp -af "$SYS_TARGET"/* "$WORK_DIR/" 2>&1) || log "mount_effect_lib: cp failed $SYS_TARGET -> $WORK_DIR: $CP_ERR"
  cp -f "$MOD_SOURCE_DIR/$EFFECT_LIB" "$WORK_DIR/$EFFECT_LIB"
  CHCON_ERR=$(chcon -R --reference="$SYS_TARGET" "$WORK_DIR" 2>&1) || log "mount_effect_lib: chcon failed $WORK_DIR: $CHCON_ERR"
  ns_mount "$WORK_DIR" "$SYS_TARGET"
  local RC=$?
  log "mount_effect_lib: bind mount $WORK_DIR -> $SYS_TARGET (rc=$RC)"
}

mount_vendor() {
  for arch in lib lib64; do
    mount_effect_lib "/vendor/$arch/soundfx" "$MOD_VENDOR/$arch/soundfx"
  done
}

mount_apex() {
  for sfx_dir in /apex/*/lib64/soundfx /apex/*/lib/soundfx; do
    [ -d "$sfx_dir" ] || continue
    local arch
    case "$sfx_dir" in
    */lib64/*) arch="lib64" ;;
    *) arch="lib" ;;
    esac
    mount_effect_lib "$sfx_dir" "$MOD_VENDOR/$arch/soundfx"
  done
}

if [ "$SELF_MOUNT" = true ]; then
  mount_vendor
  mount_apex
else
  log "Manager mounts module tree; skipping direct mounts"
fi

log "Library presence after mount:"
for d in /vendor/lib/soundfx /vendor/lib64/soundfx /apex/*/lib64/soundfx /apex/*/lib/soundfx; do
  [ -f "$d/$EFFECT_LIB" ] && log "  FOUND: $d/$EFFECT_LIB ($(ls -lZ "$d/$EFFECT_LIB" 2>/dev/null | awk '{print $1, $4, $5}'))"
done

V4A_LIB='<library name="v4a_aidl" path="libv4a_aidl.so"\/>'
V4A_EFFECT='<effect name="v4a_standard_aidl" library="v4a_aidl" uuid="90380da3-8536-4744-a6a3-5731970e640f" type="7261676f-6d75-7369-6364-28e2fd3ac39e"\/>'

MOUNTED=false

mount_config() {
  local original="$1"
  local patched=""

  for p in $(find "$MODDIR/system" "$MODDIR/odm" -type f -name "$(basename "$original")" 2>/dev/null); do
    local mapped="$(echo "$p" | sed "s|$MODDIR/odm|/odm|; s|$MODDIR/system/vendor/odm|/odm|; s|$MODDIR/system/vendor|/vendor|; s|$MODDIR/system|/system|")"
    if [ "$mapped" = "$original" ]; then
      patched="$p"
      break
    fi
  done

  if [ -z "$patched" ]; then
    patched="$MODDIR/work_cfg/$(echo "$original" | tr '/' '_')"
    mkdir -p "$MODDIR/work_cfg"
    cp -f "$original" "$patched"
    sed -i "/v4a_standard_aidl/d" "$patched"
    sed -i "/v4a_aidl/d" "$patched"
    if grep -q '<libraries>' "$patched"; then
      sed -i "/<libraries>/ a\\        $V4A_LIB" "$patched"
      sed -i "/<effects>/ a\\        $V4A_EFFECT" "$patched"
    elif grep -q '<library ' "$patched"; then
      sed -i "/<library /i\\        $V4A_LIB" "$patched"
      if grep -q '<effect ' "$patched"; then
        sed -i "/<effect /i\\        $V4A_EFFECT" "$patched"
      fi
    else
      log "mount_config: skip $original (no library/effect tags found)"
      rm -f "$patched"
      return
    fi
    CHCON_ERR=$(chcon --reference="$original" "$patched" 2>&1) || log "mount_config: chcon failed $patched: $CHCON_ERR"
    local V4A_CNT=$(grep -c 'v4a_aidl' "$patched" 2>/dev/null)
    log "Config patched on-the-fly: $original (v4a_aidl entries in patched: $V4A_CNT)"
  fi

  if cmp -s "$patched" "$original"; then
    log "Config skip: $original (already matches patched)"
    return
  fi

  ns_mount "$patched" "$original"
  local RC=$?
  log "Config mount: $patched -> $original (rc=$RC)"
  [ "$RC" -eq 0 ] && MOUNTED=true
}

mount_bundled_config() {
  local target_dir=/vendor/etc
  local target="$target_dir/audio_effects_config.xml"
  local source="$MODDIR/system/vendor/etc/audio_effects_config.xml"
  local work_dir="$MODDIR/work_cfg/vendor_etc"

  [ -d "$target_dir" ] || return 0
  [ -f "$source" ] || return 0
  [ -f "$target" ] && return 0

  [ -d "$work_dir" ] && rm -rf "$work_dir"
  mkdir -p "$work_dir"
  CP_ERR=$(cp -af "$target_dir"/* "$work_dir/" 2>&1) || log "mount_bundled_config: cp failed $target_dir -> $work_dir: $CP_ERR"
  cp -f "$source" "$work_dir/audio_effects_config.xml"
  CHCON_ERR=$(chcon -R --reference="$target_dir" "$work_dir" 2>&1) || log "mount_bundled_config: chcon failed $work_dir: $CHCON_ERR"
  ns_mount "$work_dir" "$target_dir"
  local RC=$?
  log "Bundled config mount: $work_dir -> $target_dir (rc=$RC)"
  [ "$RC" -eq 0 ] && MOUNTED=true
}

CONFIG_DIRS="/odm/etc /vendor/etc /system/etc /product/etc /system_ext/etc"

if [ "$SELF_MOUNT" = true ]; then
  for dir in $CONFIG_DIRS; do
    for cfg in "$dir"/audio_effects*.xml; do
      [ -f "$cfg" ] || continue
      mount_config "$cfg"
    done
  done

  for sku_dir in /vendor/etc/audio/sku_*; do
    [ -d "$sku_dir" ] || continue
    for cfg in "$sku_dir"/audio_effects*.xml; do
      [ -f "$cfg" ] || continue
      mount_config "$cfg"
    done
  done

  mount_bundled_config
fi

kill_audio_procs() {
  for proc in audioserver secaudiohalaidl audiohalservice audio.service-aidl.mediatek; do
    # busybox ps prints "PID USER ...", toybox prints "USER PID ..."
    local pids
    pids=$(ps -A 2>/dev/null | grep "$proc" | grep -v grep | awk '{ if ($1 ~ /^[0-9]+$/) print $1; else if ($2 ~ /^[0-9]+$/) print $2 }')
    if [ -n "$pids" ]; then
      for pid in $pids; do
        kill "$pid" 2>/dev/null
      done
      log "Killed $proc (pids: $pids)"
    fi
  done
}

wait_for_viper_control() {
  local counter=0
  while [ $counter -lt 10 ]; do
    if service list 2>/dev/null | grep -q 'viper.control'; then
      return 0
    fi
    sleep 1
    counter=$((counter + 1))
  done
  return 1
}

if [ "$MOUNTED" = true ]; then
  kill_audio_procs
  sleep 2
  if wait_for_viper_control; then
    log "viper.control registered after audio restart"
  else
    log "viper.control not detected after audio restart, retrying"
    kill_audio_procs
    if wait_for_viper_control; then
      log "viper.control registered after retry"
    else
      log "WARNING: viper.control not registered after audio restart retry"
    fi
  fi
fi

log "Effective audio configs (from init namespace):"
ns_grep_v4a() {
  local cnt
  cnt=$(nsenter -t 1 -m -- cat "$1" 2>/dev/null | grep -c 'v4a_aidl' 2>/dev/null)
  if [ -z "$cnt" ]; then
    cnt=$(grep -c 'v4a_aidl' "$1" 2>/dev/null)
  fi
  echo "${cnt:-0}"
}
for dir in $CONFIG_DIRS; do
  for cfg in "$dir"/audio_effects*.xml; do
    [ -f "$cfg" ] || continue
    HAS_V4A=$(ns_grep_v4a "$cfg")
    log "  $cfg (v4a entries: $HAS_V4A)"
    if [ "$HAS_V4A" -eq 0 ] && { [ -f "$MODDIR/odm/etc/${cfg##*/}" ] || [ -f "$MODDIR/system/vendor/odm/etc/${cfg##*/}" ]; } && [ "$dir" = /odm/etc ]; then
      log "WARNING: Patched ODM config is not active: $cfg"
    fi
  done
done
for sku_dir in /vendor/etc/audio/sku_*; do
  [ -d "$sku_dir" ] || continue
  for cfg in "$sku_dir"/audio_effects*.xml; do
    [ -f "$cfg" ] || continue
    HAS_V4A=$(ns_grep_v4a "$cfg")
    log "  $cfg (v4a entries: $HAS_V4A)"
  done
done

log "ro.audio.ignore_effects: $(getprop ro.audio.ignore_effects)"

(
  counter=0
  while [ "$(getprop ro.audio.ignore_effects)" = "true" ] && [ $counter -le 20 ]; do
    resetprop ro.audio.ignore_effects false
    log "resetprop ro.audio.ignore_effects false (attempt $counter)"
    sleep 1
    counter=$((counter + 1))
  done
) >/dev/null 2>&1 &

HAL_PROCS=$(ps -A 2>/dev/null | grep -i audio | grep -v grep | head -10)
if [ -n "$HAL_PROCS" ]; then
  log "Audio processes:"
  echo "$HAL_PROCS" | while read line; do
    log "  $line"
  done
else
  log "Audio processes: none detected"
fi
log "Audio HAL SELinux:"
ps -AZ 2>/dev/null | grep -i audio | grep -v grep | head -10 | while read line; do
  log "  $line"
done

log "---> service.sh done <---"
