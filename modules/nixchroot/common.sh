# shellcheck shell=sh
# Shared by post-fs-data.sh, service.sh, action.sh, uninstall.sh, bootstrap.sh and nixroot.
# Runs under KernelSU's busybox ash (module stages) or the Android mksh with
# busybox re-exec (nixroot). POSIX sh only.

NIXCHROOT_CONF_DIR=${NIXCHROOT_CONF_DIR:-/data/adb/nixchroot}
NIXCHROOT_CONF=$NIXCHROOT_CONF_DIR/config
NIXCHROOT_LOG=$NIXCHROOT_CONF_DIR/nixchroot.log

# defaults (overridden by the config file)
NIXROOT=/data/local/nix
BIND_SDCARD=1
SDCARD_SRC=/storage/emulated/0
DEV_EXTRAS=1
DNS="1.1.1.1 9.9.9.9"
SSHD=0
SSHD_PORT=8022
SSHD_LISTEN=127.0.0.1

# shellcheck disable=SC1090
[ -r "$NIXCHROOT_CONF" ] && . "$NIXCHROOT_CONF"

log() {
  _msg="[$(date '+%F %T' 2>/dev/null)] nixchroot: $*"
  [ -d "$NIXCHROOT_CONF_DIR" ] && echo "$_msg" >> "$NIXCHROOT_LOG"
  [ -n "$NIXCHROOT_VERBOSE" ] && echo "$_msg" >&2
  return 0
}

die() { log "ERROR: $*"; echo "nixchroot: $*" >&2; exit 1; }

sane_root() {
  case "$NIXROOT" in
    ''|/|*' '*|*'..'*) die "refusing NIXROOT='$NIXROOT'" ;;
    /*) ;;
    *) die "NIXROOT must be absolute: '$NIXROOT'" ;;
  esac
}

# Is $1 a mount point in *this* mount namespace? (mountinfo field 5)
is_mnt() {
  cut -d' ' -f5 /proc/self/mountinfo | grep -qxF "$1"
}

# Any mounts at or below $NIXROOT? (used to refuse destructive ops)
has_mounts_below() {
  cut -d' ' -f5 /proc/self/mountinfo | grep -q "^$NIXROOT/"
}

rootfs_present() {
  # -L, not -e: the profile link points at an absolute /nix/store path that
  # only resolves inside the chroot.
  [ -d "$NIXROOT/nix/store" ] && [ -L "$NIXROOT/nix/var/nix/profiles/default" ]
}

same_ns_as_init() {
  [ "$(readlink /proc/self/ns/mnt)" = "$(readlink /proc/1/ns/mnt)" ]
}

mnt_bind() { # src dst
  is_mnt "$2" && return 0
  [ -e "$1" ] || { log "skip bind $1 -> $2 (missing source)"; return 1; }
  mkdir -p "$2"
  mount -o bind "$1" "$2" && log "bind $1 -> $2"
}

mnt_fs() { # type opts dst
  is_mnt "$3" && return 0
  mkdir -p "$3"
  mount -t "$1" -o "$2" "$1" "$3" && log "mount $1 $3 ($2)"
}

# Core mounts. Needs only /data (post-fs-data safe).
nixchroot_mount_core() {
  sane_root
  rootfs_present || { log "no rootfs at $NIXROOT, nothing to do"; return 0; }
  R=$NIXROOT

  # Make the chroot its own private mount so nothing below it propagates into
  # the zygote/app namespaces that are slaves of /data's peer group (and so
  # app namespaces never pin our mounts busy).
  if ! is_mnt "$R"; then
    mount -o bind "$R" "$R" && log "self-bind $R"
  fi
  mount --make-private "$R" 2>/dev/null || mount -o private "$R" 2>/dev/null \
    || log "warn: could not make $R private"

  mnt_fs   proc  nosuid,nodev,noexec     "$R/proc"
  mnt_bind /sys                          "$R/sys"
  mnt_bind /dev                          "$R/dev"
  mnt_bind /dev/pts                      "$R/dev/pts"
  mnt_fs   tmpfs mode=1777,nosuid,nodev  "$R/tmp"
  mnt_fs   tmpfs mode=0755,nosuid,nodev  "$R/run"

  if [ "$DEV_EXTRAS" = 1 ]; then
    [ -e /dev/fd ]     || ln -s /proc/self/fd   /dev/fd
    [ -e /dev/stdin ]  || ln -s /proc/self/fd/0 /dev/stdin
    [ -e /dev/stdout ] || ln -s /proc/self/fd/1 /dev/stdout
    [ -e /dev/stderr ] || ln -s /proc/self/fd/2 /dev/stderr
    mnt_fs tmpfs mode=1777,nosuid,nodev "$R/dev/shm"
  fi

  nixchroot_write_resolv
}

nixchroot_write_resolv() {
  R=$NIXROOT
  [ -d "$R/etc" ] || return 0
  _tmp="$R/etc/.resolv.conf.$$"
  : > "$_tmp"
  for ns in $DNS; do echo "nameserver $ns" >> "$_tmp"; done
  echo "options edns0 timeout:2 attempts:2" >> "$_tmp"
  # replace symlinks too (never follow one out of the chroot)
  rm -f "$R/etc/resolv.conf"
  mv "$_tmp" "$R/etc/resolv.conf"
  chmod 644 "$R/etc/resolv.conf"
}

# Needs CE storage + FUSE: call after boot_completed / unlock.
nixchroot_mount_sdcard() {
  [ "$BIND_SDCARD" = 1 ] || return 0
  sane_root
  rootfs_present || return 0
  mnt_bind "$SDCARD_SRC" "$NIXROOT/mnt/sdcard"
}

sshd_pid() {
  _p=$(cat "$NIXROOT/run/sshd.pid" 2>/dev/null) || return 1
  [ -n "$_p" ] && [ -d "/proc/$_p" ] && grep -q sshd "/proc/$_p/cmdline" 2>/dev/null && echo "$_p"
}

nixchroot_start_sshd() {
  [ "$SSHD" = 1 ] || return 0
  sane_root
  rootfs_present || return 0
  R=$NIXROOT
  if sshd_pid >/dev/null; then log "sshd already running"; return 0; fi
  P=/nix/var/nix/profiles/default
  if [ -r "$NIXCHROOT_CONF_DIR/authorized_keys" ]; then
    mkdir -p "$R/root/.ssh"
    cat "$NIXCHROOT_CONF_DIR/authorized_keys" > "$R/root/.ssh/authorized_keys"
    chmod 700 "$R/root/.ssh"; chmod 600 "$R/root/.ssh/authorized_keys"
    chown -R 0:0 "$R/root/.ssh"
  fi
  chroot "$R" $P/bin/env -i PATH=$P/bin:$P/sbin $P/bin/ssh-keygen -A >/dev/null 2>&1
  # sshd must be exec'd by absolute path (it re-execs itself / sshd-session).
  # Resolve inside the chroot: the profile links point at /nix/store/...
  _sshd=$(chroot "$R" $P/bin/readlink -f $P/bin/sshd) || { log "sshd not found in profile"; return 1; }
  if chroot "$R" $P/bin/env -i PATH=$P/bin:$P/sbin HOME=/root LANG=C.UTF-8 \
      "$_sshd" -f /etc/ssh/sshd_config -o "Port=$SSHD_PORT" -o "ListenAddress=$SSHD_LISTEN"; then
    # sshd daemonizes before writing its pidfile; wait so a second caller
    # (service.sh racing action.sh) sees it and stays idempotent.
    _i=0; while ! sshd_pid >/dev/null && [ $_i -lt 20 ]; do sleep 0.5; _i=$((_i + 1)); done
    if _p=$(sshd_pid); then log "sshd started on $SSHD_LISTEN:$SSHD_PORT (pid $_p)"
    else log "sshd exited right after start (debug: nixroot $_sshd -d -p $SSHD_PORT)"; fi
  else
    log "sshd failed to start (debug: nixroot $_sshd -d -f /etc/ssh/sshd_config)"
  fi
}

nixchroot_stop_sshd() {
  _p=$(sshd_pid) && kill "$_p" && log "sshd ($_p) stopped"
  return 0
}

# Reverse order, lazy as a fallback. Never rm anything here.
nixchroot_umount_all() {
  sane_root
  nixchroot_stop_sshd
  # deepest first; paths are space-free (sane_root), mountinfo is one mount per line
  cut -d' ' -f5 /proc/self/mountinfo | grep "^$NIXROOT/" | sort -r | while read -r m; do
    umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || log "warn: could not umount $m"
  done
  if is_mnt "$NIXROOT"; then umount "$NIXROOT" 2>/dev/null || umount -l "$NIXROOT"; fi
  log "unmounted everything under $NIXROOT"
}
