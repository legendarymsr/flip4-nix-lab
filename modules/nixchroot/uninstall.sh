#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR/../..
# Runs when the module is removed. Unmounts only; the rootfs at $NIXROOT and
# /data/adb/nixchroot are left alone (delete them yourself, AFTER a reboot or
# `nixroot --umount`, never while /dev is bound in there).
MODDIR=${0%/*}
# shellcheck source=modules/nixchroot/common.sh
. "$MODDIR/common.sh"
nixchroot_umount_all
