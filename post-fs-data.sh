MODDIR=${0%/*}

V4A_LOG=/data/adb/viper_install.log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-fs-data] $1" >>$V4A_LOG; }

log "---> post-fs-data start <---"
log "SELinux: $(getenforce 2>/dev/null || echo unknown)"

for cfg in "$MODDIR"/odm/etc/audio_effects*.xml "$MODDIR"/system/vendor/odm/etc/audio_effects*.xml; do
  [ -f "$cfg" ] || continue
  target="/odm/etc/${cfg##*/}"
  [ -f "$target" ] || continue
  grep -q 'v4a_aidl' "$target" 2>/dev/null && continue
  CHCON_ERR=$(chcon u:object_r:vendor_configs_file:s0 "$cfg" 2>&1) || log "chcon ODM config failed: $cfg: $CHCON_ERR"
  if mount -o bind "$cfg" "$target"; then
    log "Bound ODM config: $cfg -> $target"
  else
    log "WARNING: Failed to bind ODM config: $cfg -> $target"
  fi
done

if [ -f "$MODDIR/system/vendor/etc/audio_effects_config.xml" ]; then
  CHCON_ERR=$(chcon u:object_r:vendor_configs_file:s0 "$MODDIR/system/vendor/etc/audio_effects_config.xml" 2>&1) || log "chcon bundled config failed: $CHCON_ERR"
  log "Set chcon on bundled audio_effects_config.xml"
fi

V4A_SEPOLICY="type viper_control_service service_manager_type
allow hal_audio_default viper_control_service service_manager add
allow mtk_hal_audio viper_control_service service_manager add
allow hal_audio_default default_android_service service_manager add
allow mtk_hal_audio default_android_service service_manager add
allow untrusted_app viper_control_service service_manager find
allow untrusted_app default_android_service service_manager find
allow hal_audio_default servicemanager binder { call transfer }
allow mtk_hal_audio servicemanager binder { call transfer }
allow untrusted_app hal_audio_default binder { call transfer }
allow untrusted_app mtk_hal_audio binder { call transfer }"

POLICY_TOOL=""
POLICY_TYPE=""
if command -v ksud >/dev/null 2>&1; then
  POLICY_TOOL="ksud"
  POLICY_TYPE="ksu"
elif [ -x /data/adb/ksu/bin/ksud ]; then
  POLICY_TOOL="/data/adb/ksu/bin/ksud"
  POLICY_TYPE="ksu"
elif command -v magiskpolicy >/dev/null 2>&1; then
  POLICY_TOOL="magiskpolicy"
  POLICY_TYPE="magisk"
elif [ -x /data/adb/magisk/magiskpolicy ]; then
  POLICY_TOOL="/data/adb/magisk/magiskpolicy"
  POLICY_TYPE="magisk"
elif [ -x /data/adb/ap/bin/apd ]; then
  POLICY_TOOL="/data/adb/ap/bin/apd"
  POLICY_TYPE="apatch"
fi

log "Applying SELinux policy rules (tool: ${POLICY_TOOL:-not found}, type: ${POLICY_TYPE:-unknown})..."
if [ -n "$POLICY_TOOL" ]; then
  case "$POLICY_TYPE" in
  ksu)
    RULE_FILE="$MODDIR/v4a_sepolicy.tmp"
    echo "$V4A_SEPOLICY" >"$RULE_FILE"
    POLICY_ERR=$($POLICY_TOOL sepolicy apply "$RULE_FILE" 2>&1)
    POLICY_RC=$?
    rm -f "$RULE_FILE"
    ;;
  apatch)
    RULE_FILE="$MODDIR/v4a_sepolicy.tmp"
    echo "$V4A_SEPOLICY" >"$RULE_FILE"
    POLICY_ERR=$($POLICY_TOOL sepolicy --live --apply "$RULE_FILE" 2>&1)
    POLICY_RC=$?
    rm -f "$RULE_FILE"
    ;;
  magisk)
    RULE_FILE="$MODDIR/v4a_sepolicy.tmp"
    echo "$V4A_SEPOLICY" >"$RULE_FILE"
    POLICY_ERR=$($POLICY_TOOL --live --apply "$RULE_FILE" 2>&1)
    POLICY_RC=$?
    rm -f "$RULE_FILE"
    ;;
  esac
  if [ $POLICY_RC -ne 0 ]; then
    log "Policy inject failed (rc=$POLICY_RC): $POLICY_ERR"
  else
    log "Policy inject applied (rc=0)"
  fi
else
  log "WARNING: No policy tool found. Relying on sepolicy.rule static rules."
fi

log "---> post-fs-data done <---"
