#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR/../..
# KernelSU post-fs-data stage: blocking, runs in the global (init) mount
# namespace, before zygote. /data is decrypted with the DE key here, which is
# all /data/local needs. Keep it fast.
MODDIR=${0%/*}
# shellcheck source=modules/nixchroot/common.sh
. "$MODDIR/common.sh"
mkdir -p "$NIXCHROOT_CONF_DIR" && chmod 700 "$NIXCHROOT_CONF_DIR"
[ -f "$NIXCHROOT_CONF" ] || cp "$MODDIR/config.default" "$NIXCHROOT_CONF"
# rotate log
[ -f "$NIXCHROOT_LOG" ] && mv -f "$NIXCHROOT_LOG" "$NIXCHROOT_LOG.1"
log "post-fs-data: ns=$(readlink /proc/self/ns/mnt) init_ns=$(readlink /proc/1/ns/mnt)"
same_ns_as_init || log "warn: not in init mount ns; mounts may be invisible to adb shell"
nixchroot_mount_core
