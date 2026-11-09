#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR/../..
# KernelSU late_start service stage: non-blocking. Waits for boot + user
# unlock (CE storage/FUSE) for the /sdcard bind, then optionally sshd.
MODDIR=${0%/*}
# shellcheck source=modules/nixchroot/common.sh
. "$MODDIR/common.sh"

# Re-assert core mounts (no-op if post-fs-data already did them).
nixchroot_mount_core

(
  until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
  # wait (up to ~30 min) for the first unlock so CE storage is available
  i=0
  while [ ! -d "$SDCARD_SRC/Android" ] && [ $i -lt 900 ]; do sleep 2; i=$((i + 1)); done
  nixchroot_mount_sdcard
  nixchroot_start_sshd
) &
