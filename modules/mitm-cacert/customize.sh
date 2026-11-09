# shellcheck shell=sh
# shellcheck disable=SC2154
{
  ui_print "- mitm-cacert: user CA -> Conscrypt APEX trust store (Android 14+)"
  ui_print "  LAB DEVICE ONLY: every app on this phone will trust these CAs."
  mkdir -p /data/adb/mitmca/certs.d
  chmod 700 /data/adb/mitmca
  [ -f /data/adb/mitmca/config ] || cp "$MODPATH/config.default" /data/adb/mitmca/config
  for f in service.sh action.sh uninstall.sh mitmca-add; do
    [ -e "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
  done
  n=$(find /data/adb/mitmca/certs.d -name '*.0' 2>/dev/null | wc -l)
  ui_print "- $n cert(s) in /data/adb/mitmca/certs.d"
}
