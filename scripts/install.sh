#!/usr/bin/env bash
# flip4-lab-install: put the rootfs tarball on the phone at $NIXROOT.
#
#   nix run .#install                       # builds .#rootfs, pushes, extracts
#   nix run .#install -- -s SERIAL --force  # specific device; umount + upgrade in place
#   ./scripts/install.sh result/flip4-nix-rootfs-aarch64.tar.gz
#   ./scripts/install.sh --stream ...       # no temp copy on /data/local/tmp (adb exec-in)
#   (on the phone, as root)  sh install.sh /sdcard/Download/flip4-nix-rootfs-aarch64.tar.gz
#
# Ownership is forced to 0:0 in the archive (--numeric-owner) and extraction
# runs as root, so the store comes out root-owned with modes intact;
# symlinks are stored as symlinks and extracted as such (no -h/--dereference).
set -euo pipefail

NIXROOT=${NIXROOT:-/data/local/nix}
SERIAL=""
FORCE=0
STREAM=0
TARBALL=${FLIP4_ROOTFS:-}
REMOTE_TMP=/data/local/tmp/flip4-nix-rootfs.tar.gz

usage() { sed -n '2,13p' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -s) SERIAL=$2; shift 2 ;;
    --root) NIXROOT=$2; shift 2 ;;
    --force) FORCE=1; shift ;;
    --stream) STREAM=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option $1" >&2; usage 1 ;;
    *) TARBALL=$1; shift ;;
  esac
done

[ -z "$TARBALL" ] && [ -e result/flip4-nix-rootfs-aarch64.tar.gz ] && TARBALL=result/flip4-nix-rootfs-aarch64.tar.gz
[ -d "$TARBALL" ] && TARBALL=$TARBALL/flip4-nix-rootfs-aarch64.tar.gz
[ -r "$TARBALL" ] || { echo "rootfs tarball not found: '${TARBALL}' (nix build .#rootfs)" >&2; exit 1; }

case "$NIXROOT" in ''|/|*' '*|*..*) echo "refusing NIXROOT=$NIXROOT" >&2; exit 1 ;; esac

ON_DEVICE=0
[ -e /system/build.prop ] && ON_DEVICE=1

# dev 'shell snippet'  -> runs as root on the phone (adb+su, or locally)
dev() {
  if [ "$ON_DEVICE" = 1 ]; then
    sh -c "$1"
  else
    local -a a=(adb); [ -n "$SERIAL" ] && a+=(-s "$SERIAL")
    "${a[@]}" shell "su -c '$1'"
  fi
}
adbc() { local -a a=(adb); [ -n "$SERIAL" ] && a+=(-s "$SERIAL"); "${a[@]}" "$@"; }

echo ">> target: $([ "$ON_DEVICE" = 1 ] && echo local || echo "adb ${SERIAL:-default}")  NIXROOT=$NIXROOT"
if [ "$ON_DEVICE" = 0 ]; then
  adbc get-state >/dev/null || { echo "no adb device (One UI 7: check Auto Blocker is off)" >&2; exit 1; }
fi
uid=$(dev 'id -u' | tr -d '\r')
[ "$uid" = 0 ] || { echo "su failed (grant Shell root in the KernelSU manager)" >&2; exit 1; }

# The phone side always uses KernelSU's busybox when available.
# shellcheck disable=SC2016  # expanded on the phone, not here
BBX='BB=/data/adb/ksu/bin/busybox; [ -x $BB ] || BB=""'

# Refuse to touch a live chroot: extracting/overwriting under a bound /dev
# or /proc is how you brick a phone's runtime state.
if dev "cut -d\" \" -f5 /proc/self/mountinfo | grep -q \"^$NIXROOT/\"" ; then
  if [ "$FORCE" = 1 ]; then
    echo ">> chroot is mounted; unmounting (--force)"
    dev "if [ -x /data/adb/modules/nixchroot/nixroot ]; then sh /data/adb/modules/nixchroot/nixroot --umount; fi"
    if dev "cut -d\" \" -f5 /proc/self/mountinfo | grep -q \"^$NIXROOT/\""; then
      echo "still mounted under $NIXROOT; reboot with the module disabled and retry" >&2; exit 1
    fi
  else
    echo "$NIXROOT has active mounts. Use --force (runs nixroot --umount) or reboot." >&2; exit 1
  fi
fi

size=$(stat -c %s "$TARBALL")
avail_kb=$(dev 'df -k /data | tail -1' | tr -s ' ' | cut -d' ' -f4 | tr -d '\r')
need_kb=$(( size * 4 / 1024 ))   # gz ratio ~3x, plus the temp copy
echo ">> tarball $(( size / 1048576 )) MiB, /data free $(( avail_kb / 1024 )) MiB"
[ "$avail_kb" -gt "$need_kb" ] || { echo "not enough space on /data (want ~$(( need_kb / 1024 )) MiB)" >&2; exit 1; }

if dev "[ -d $NIXROOT/etc ]"; then
  ts=$(date +%Y%m%d-%H%M%S)
  echo ">> existing rootfs: backing up $NIXROOT/etc -> $NIXROOT/etc.bak-$ts (host keys etc.)"
  dev "cp -a $NIXROOT/etc $NIXROOT/etc.bak-$ts"
fi
dev "mkdir -p $NIXROOT && chown 0:0 $NIXROOT && chmod 755 $NIXROOT"

EXTRACT="$BBX; cd $NIXROOT && \${BB:+\$BB} gzip -dc | \${BB:+\$BB} tar -xpf -"

if [ "$ON_DEVICE" = 1 ]; then
  sh -c "$EXTRACT" < "$TARBALL"
elif [ "$STREAM" = 1 ]; then
  echo ">> streaming via adb exec-in"
  adbc exec-in "su -c '$EXTRACT'" < "$TARBALL"
else
  echo ">> pushing to $REMOTE_TMP"
  adbc push "$TARBALL" "$REMOTE_TMP"
  want=$(cut -d' ' -f1 < "$TARBALL.sha256" 2>/dev/null || sha256sum "$TARBALL" | cut -d' ' -f1)
  got=$(dev "sha256sum $REMOTE_TMP" | cut -d' ' -f1 | tr -d '\r')
  [ "$want" = "$got" ] || { echo "sha256 mismatch after push ($got != $want)" >&2; exit 1; }
  echo ">> extracting"
  dev "$BBX; cd $NIXROOT && \${BB:+\$BB} gzip -dc $REMOTE_TMP | \${BB:+\$BB} tar -xpf - && rm -f $REMOTE_TMP"
fi

# Force a db (re)load on next entry so the new closure is registered.
dev "touch $NIXROOT/.nix-db-pending && chown 0:0 $NIXROOT && chmod 755 $NIXROOT && chmod 1777 $NIXROOT/tmp"
echo ">> sanity:"
dev "ls -ld $NIXROOT/nix/var/nix/profiles/default; ls -Zd $NIXROOT; [ -L $NIXROOT/bin/sh ] && echo symlinks-ok"
cat <<MSG
>> done. Next:
   - install the KernelSU module (nix run .#push-modules) and reboot, or
   - adb shell su -c 'sh /data/adb/modules/nixchroot/nixroot'   (first entry loads the Nix db)
MSG
