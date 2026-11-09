#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR/../..
# KernelSU manager "Action" button.
#  - no rootfs yet  -> download (resumable), verify sha256, extract, mount
#  - rootfs present -> (re)apply mounts / sshd and print status
MODDIR=${0%/*}
# The manager may run us in its own mount namespace; mounts must land in
# init's so Termux/adb shells see them.
if [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ] && [ -z "$NIXROOT_NSENTERED" ]; then
  for b in /data/adb/ksu/bin/busybox ""; do
    if [ -n "$b" ] && [ -x "$b" ]; then NIXROOT_NSENTERED=1 exec "$b" nsenter -t 1 -m -- "$b" sh "$0" "$@"; fi
    if [ -z "$b" ] && command -v nsenter >/dev/null 2>&1; then NIXROOT_NSENTERED=1 exec nsenter -t 1 -m -- /system/bin/sh "$0" "$@"; fi
  done
fi
NIXCHROOT_VERBOSE=
# shellcheck source=modules/nixchroot/common.sh
. "$MODDIR/common.sh"
# shellcheck source=modules/nixchroot/bootstrap.sh
. "$MODDIR/bootstrap.sh"
BB=/data/adb/ksu/bin/busybox; [ -x "$BB" ] || BB=""
mkdir -p "$NIXCHROOT_CONF_DIR"

if ! rootfs_present; then
  echo "== nixchroot: installing the Nix rootfs (no PC needed) =="
  nixchroot_bootstrap "" || { echo "!! bootstrap failed, see $NIXCHROOT_LOG; tap Action again to resume"; exit 1; }
  exit 0
fi

nixchroot_mount_core
nixchroot_mount_sdcard
nixchroot_start_sshd
echo "rootfs: $NIXROOT"
echo "mounts:"
cut -d' ' -f5 /proc/self/mountinfo | grep "^$NIXROOT"
if p=$(sshd_pid); then echo "sshd: running (pid $p) on $SSHD_LISTEN:$SSHD_PORT"; else echo "sshd: off (SSHD=1 in $NIXCHROOT_CONF)"; fi
echo "enter: su -c nixroot"
