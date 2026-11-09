# shellcheck shell=sh
# mitm-cacert: put user CAs into the Conscrypt APEX trust store on Android 14+.
#
# Why this is fiddly on 14/15: the trust store lives in the Conscrypt APEX
# (/apex/com.android.conscrypt/cacerts), a read-only, Mainline-updatable
# image. /apex mounts are PRIVATE per mount namespace, and zygote + every app
# get their own mount namespace, so a bind mount in init's namespace (what a
# KernelSU/Magisk module overlay or a plain `mount --bind` gives you) is not
# seen by apps. We therefore nsenter into zygote/zygote64/webview_zygote and
# every already-running zygote descendant and bind there too. New apps fork
# from zygote after that and inherit the mount.

MITMCA_DIR=/data/adb/mitmca
MITMCA_CERTS=$MITMCA_DIR/certs.d
MITMCA_LOG=$MITMCA_DIR/mitmca.log
APEX_CACERTS=/apex/com.android.conscrypt/cacerts
SYS_CACERTS=/system/etc/security/cacerts
CACERT_CTX=u:object_r:system_security_cacerts_file:s0
# shellcheck disable=SC2034  # consumed by service.sh
WATCH=1
# shellcheck disable=SC2034
WATCH_INTERVAL=15
LEGACY_SYSTEM_STORE=1
# shellcheck disable=SC1091
[ -r "$MITMCA_DIR/config" ] && . "$MITMCA_DIR/config"

BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=$(command -v busybox 2>/dev/null)
[ -n "$BB" ] || { echo "mitmca: no busybox (KernelSU ships /data/adb/ksu/bin/busybox)" >&2; exit 1; }

mlog() { echo "[$(date '+%F %T')] mitmca: $*" >> "$MITMCA_LOG"; [ -n "$MITMCA_VERBOSE" ] && echo "mitmca: $*" >&2; return 0; }

boot_id() { tr -d '-' < /proc/sys/kernel/random/boot_id; }

# Per-boot staging dir. Never modified once bind-mounted anywhere (deleting
# files in a bind source deletes them in every namespace that sees it), so a
# new boot gets a new dir and old boots' dirs are cleaned up.
STAGE=$MITMCA_DIR/stage-$(boot_id)

first_cert() { for c in "$MITMCA_CERTS"/*.0; do [ -f "$c" ] && { basename "$c"; return 0; }; done; return 1; }

build_stage() { # $1 = source store dir, $2 = stage dir
  [ -d "$2" ] && return 0
  _t="$2.tmp.$$"
  mkdir -p "$_t" || return 1
  # Copy AOSP/Mainline roots first, then ours (ours win on hash collision).
  cp -p "$1"/* "$_t"/ 2>/dev/null
  cp "$MITMCA_CERTS"/*.0 "$_t"/
  chown -R 0:0 "$_t"
  chmod 755 "$_t"; chmod 644 "$_t"/*
  # Label like the real store or untrusted_app can't read it (Conscrypt fails
  # closed -> every TLS connection in the app breaks, not just yours).
  chcon -R "$CACERT_CTX" "$_t"
  mv "$_t" "$2"
  mlog "staged $(find "$2" -type f | wc -l) certs from $1 into $2"
}

stage_all() {
  sentinel=$(first_cert) || { mlog "no certs in $MITMCA_CERTS, nothing to do"; return 1; }
  # cleanup previous boots (nothing can have them mounted any more)
  for d in "$MITMCA_DIR"/stage-*; do
    case "$d" in "$STAGE"|"$STAGE".*) ;; *) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
  [ -d "$APEX_CACERTS" ] && build_stage "$APEX_CACERTS" "$STAGE/apex"
  [ "$LEGACY_SYSTEM_STORE" = 1 ] && [ -d "$SYS_CACERTS" ] && build_stage "$SYS_CACERTS" "$STAGE/system"
  return 0
}

# inject_ns PID : bind the stage over the trust store(s) inside PID's mount ns.
inject_ns() {
  _pid=$1
  for pair in "apex:$APEX_CACERTS" "system:$SYS_CACERTS"; do
    _src="$STAGE/${pair%%:*}"; _dst=${pair#*:}
    [ -d "$_src" ] || continue
    # idempotent: skip if this namespace already sees our sentinel cert
    if "$BB" nsenter -t "$_pid" -m -- /system/bin/sh -c "[ -e '$_dst/$sentinel' ]" 2>/dev/null; then
      continue
    fi
    if "$BB" nsenter -t "$_pid" -m -- "$BB" mount -o bind "$_src" "$_dst" 2>>"$MITMCA_LOG"; then
      mlog "pid $_pid ($(cat "/proc/$_pid/comm" 2>/dev/null)) ns $(readlink "/proc/$_pid/ns/mnt"): bound $_dst"
    else
      mlog "pid $_pid: bind $_dst FAILED"
    fi
  done
}

zygote_pids() {
  # zygote, zygote64, webview_zygote, plus per-app app_zygotes (comm *_zygote)
  for p in /proc/[0-9]*; do
    read -r c < "$p/comm" 2>/dev/null || continue
    case "$c" in zygote|zygote64|webview_zygote|*_zygote) echo "${p#/proc/}" ;; esac
  done
}

ppid_of() { sed -n 's/^PPid:[[:space:]]*//p' "/proc/$1/status" 2>/dev/null; }

# Inject into: init's ns, each zygote's ns, and each distinct ns among running
# zygote descendants (apps, system_server, USAPs, isolated/app_zygote kids).
inject_all() {
  sentinel=$(first_cert) || return 0
  zs=" $(zygote_pids | tr '\n' ' ') "
  seen=" "
  for p in 1 $zs; do
    ns=$(readlink "/proc/$p/ns/mnt" 2>/dev/null) || continue
    case "$seen" in *" $ns "*) continue ;; esac
    seen="$seen$ns "; inject_ns "$p"
  done
  for d in /proc/[0-9]*; do
    p=${d#/proc/}
    pp=$(ppid_of "$p"); [ -n "$pp" ] || continue
    gp=$(ppid_of "$pp")
    case "$zs" in *" $pp "*|*" $gp "*) ;; *) continue ;; esac
    ns=$(readlink "/proc/$p/ns/mnt" 2>/dev/null) || continue
    case "$seen" in *" $ns "*) continue ;; esac
    seen="$seen$ns "; inject_ns "$p"
  done
}
