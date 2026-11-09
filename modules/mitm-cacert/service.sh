#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR/../..
# late_start: /apex is active, zygote is (about to be) up.
MODDIR=${0%/*}
mkdir -p /data/adb/mitmca/certs.d && chmod 700 /data/adb/mitmca
[ -f /data/adb/mitmca/config ] || cp "$MODDIR/config.default" /data/adb/mitmca/config
# shellcheck source=modules/mitm-cacert/common.sh
. "$MODDIR/common.sh"
[ -f "$MITMCA_LOG" ] && mv -f "$MITMCA_LOG" "$MITMCA_LOG.1"

(
  i=0; until [ -d "$APEX_CACERTS" ] || [ $i -ge 120 ]; do sleep 1; i=$((i + 1)); done
  stage_all || exit 0
  # zygote may not exist yet, and gets restarted at least once on some boots
  i=0; until [ -n "$(zygote_pids)" ] || [ $i -ge 120 ]; do sleep 1; i=$((i + 1)); done
  inject_all
  until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
  inject_all
  [ "$WATCH" = 1 ] || exit 0
  last=$(zygote_pids | tr '\n' ' ')
  while sleep "$WATCH_INTERVAL"; do
    now=$(zygote_pids | tr '\n' ' ')
    [ "$now" = "$last" ] && continue
    mlog "zygote set changed: [$last] -> [$now]"
    last=$now
    sleep 2; inject_all
  done
) &
