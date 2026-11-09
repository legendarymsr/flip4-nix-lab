#!/system/bin/sh
# Leaves /data/adb/mitmca/certs.d in place; the binds disappear at reboot.
rm -rf /data/adb/mitmca/stage-*
