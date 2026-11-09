#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR/../..
# KernelSU manager "Action" button: (re)apply mounts and sshd, print status.
MODDIR=${0%/*}
NIXCHROOT_VERBOSE=1
# shellcheck source=modules/nixchroot/common.sh
. "$MODDIR/common.sh"
nixchroot_mount_core
nixchroot_mount_sdcard
nixchroot_start_sshd
echo "mounts under $NIXROOT:"
cut -d' ' -f5 /proc/self/mountinfo | grep "^$NIXROOT"
if p=$(sshd_pid); then echo "sshd: running (pid $p) on $SSHD_LISTEN:$SSHD_PORT"; else echo "sshd: not running"; fi
