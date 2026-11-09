# shellcheck shell=sh
# On-device rootfs installer for the nixchroot module. Sourced (after
# common.sh) by action.sh and `nixroot --bootstrap`. No PC needed.
#
# Pinned to one release asset; the sha256 is baked in and checked before
# anything is extracted, so the transport (and busybox's non-verifying TLS,
# if we ever fall back to it) can't hand us a different rootfs.

ROOTFS_URL=${ROOTFS_URL:-https://github.com/legendarymsr/flip4-nix-lab/releases/download/v0.2.0/flip4-nix-rootfs-aarch64.tar.gz}
ROOTFS_SHA256=${ROOTFS_SHA256:-88e34433ca4e351df07b80527b4e1c992b9dd516ec929cda01fbd4bb27fbf45d}
ROOTFS_SIZE=${ROOTFS_SIZE:-1291305521}       # bytes, compressed
ROOTFS_UNPACKED_MB=3011       # ~3.0 GiB extracted
ROOTFS_NAME=flip4-nix-rootfs-aarch64.tar.gz
BOOTSTRAP_DOH=${BOOTSTRAP_DOH:-https://1.1.1.1/dns-query https://9.9.9.9/dns-query}

# Downloads live on /data (same fs as the target, never FUSE /sdcard).
DL_DIR=${DL_DIR:-/data/local/tmp/nixchroot-dl}
DL_PART=$DL_DIR/$ROOTFS_NAME.part
DL_FILE=$DL_DIR/$ROOTFS_NAME

say() { echo "$*"; log "bootstrap: $*"; }

bb() { if [ -n "$BB" ]; then "$BB" "$@"; else "$@"; fi; }

file_size() { if [ -f "$1" ]; then stat -c %s "$1" 2>/dev/null || wc -c < "$1"; else echo 0; fi; }

free_mb() {
  # statfs first (works on any path); df as a fallback.
  set -- "$1" "$(stat -f -c '%a %S' "$1" 2>/dev/null)"
  case "$2" in
    *[0-9]\ [0-9]*) echo $(( ${2% *} * ${2#* } / 1048576 )); return ;;
  esac
  _k=$(df -k "$1" 2>/dev/null | tail -1 | tr -s ' ' | cut -d' ' -f4)
  case "$_k" in ''|*[!0-9]*) echo 0 ;; *) echo $((_k / 1024)) ;; esac
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else bb sha256sum "$1" | cut -d' ' -f1; fi
}

# Android keeps roots as hashed PEM files; glue them into one bundle for curl.
ca_bundle() {
  _b=$DL_DIR/ca-bundle.pem
  : > "$_b"
  for d in /apex/com.android.conscrypt/cacerts /system/etc/security/cacerts; do
    [ -d "$d" ] || continue
    for c in "$d"/*; do sed -n '/BEGIN CERT/,/END CERT/p' "$c" >> "$_b"; done
    break
  done
  [ -s "$_b" ] && echo "$_b"
}

# Background progress printer (works with any downloader, and the KernelSU
# Action screen shows plain lines better than \r progress bars).
progress_start() {
  ( while sleep 5; do
      s=$(file_size "$DL_PART"); [ "$s" -gt 0 ] 2>/dev/null || continue
      echo "  ... $((s / 1048576)) / $((ROOTFS_SIZE / 1048576)) MiB ($((s * 100 / ROOTFS_SIZE))%)"
    done ) &
  PROGRESS_PID=$!
}
progress_stop() { [ -n "$PROGRESS_PID" ] && kill "$PROGRESS_PID" 2>/dev/null; PROGRESS_PID=""; }

# One resumable pass over the available clients, best first; a client that
# fails (DNS, TLS, network) hands the .part over to the next one. Returns 0
# when the .part has the full size, 2 when there is no client at all.
fetch_once() {
  _tried=0
  MODCURL=$MODDIR/bin/curl
  if [ -x "$MODCURL" ]; then
    _tried=1
    # Prefer Android's trust store; the binary also embeds a CA bundle.
    _ca=$(ca_bundle) && _ca="--cacert $_ca" || _ca=""
    say "downloader: bundled curl ($("$MODCURL" --version | head -1 | cut -d' ' -f1-2))"
    # Static musl curl can't use Android's netd resolver and there is no
    # /etc/resolv.conf, so resolve over DNS-over-HTTPS to an IP literal.
    for _doh in $BOOTSTRAP_DOH; do
      # shellcheck disable=SC2086
      "$MODCURL" -fL --retry 3 --retry-delay 3 --connect-timeout 20 -sS \
        --doh-url "$_doh" $_ca -C - -o "$DL_PART" "$ROOTFS_URL" \
        || say "bundled curl via $_doh failed (rc=$?)"
      [ "$(file_size "$DL_PART")" -ge "$ROOTFS_SIZE" ] && return 0
    done
  fi
  if [ -x /system/bin/curl ]; then
    _tried=1
    say "downloader: /system/bin/curl"
    /system/bin/curl -fL --retry 3 -sS -C - -o "$DL_PART" "$ROOTFS_URL" \
      || say "/system/bin/curl failed (rc=$?)"
    [ "$(file_size "$DL_PART")" -ge "$ROOTFS_SIZE" ] && return 0
  fi
  if bb wget --help 2>&1 | grep -q -- '-c'; then
    _tried=1
    # busybox wget: TLS without certificate verification; the baked-in
    # sha256 is the integrity check that matters.
    say "downloader: busybox wget (no TLS cert check; sha256 enforced)"
    bb wget -c -O "$DL_PART" "$ROOTFS_URL" || say "busybox wget failed (rc=$?)"
    [ "$(file_size "$DL_PART")" -ge "$ROOTFS_SIZE" ] && return 0
  fi
  [ $_tried = 1 ] || { say "no downloader available (bundled curl missing?)"; return 2; }
  return 1
}

download_rootfs() {
  mkdir -p "$DL_DIR" && chmod 700 "$DL_DIR"
  if [ -f "$DL_FILE" ] && [ "$(sha_of "$DL_FILE")" = "$ROOTFS_SHA256" ]; then
    say "already downloaded and verified: $DL_FILE"; return 0
  fi
  have=$(file_size "$DL_PART")
  [ "$have" -gt 0 ] 2>/dev/null && say "resuming at $((have / 1048576)) MiB"
  say "downloading $ROOTFS_URL ($((ROOTFS_SIZE / 1048576)) MiB)"
  progress_start
  ok=1; n=0
  while [ $n -lt 5 ]; do
    n=$((n + 1))
    fetch_once; rc=$?
    [ $rc = 0 ] && { ok=0; break; }
    [ $rc = 2 ] && break
    say "attempt $n interrupted at $(( $(file_size "$DL_PART") / 1048576 )) MiB, retrying in 5s"
    sleep 5
  done
  progress_stop
  [ $ok = 0 ] || { say "download failed; run it again to resume (partial file kept: $DL_PART)"; return 1; }
  mv -f "$DL_PART" "$DL_FILE"
}

verify_file() { # path
  say "verifying sha256 of $1 (takes ~30 s) ..."
  got=$(sha_of "$1")
  if [ "$got" != "$ROOTFS_SHA256" ]; then
    say "sha256 MISMATCH: got $got, want $ROOTFS_SHA256"
    return 1
  fi
  say "sha256 OK"
}

extract_rootfs() { # tarball
  sane_root
  R=$NIXROOT
  if has_mounts_below || is_mnt "$R"; then
    if [ "$BOOTSTRAP_FORCE" = 1 ]; then
      say "unmounting existing chroot (--force)"; nixchroot_umount_all
    fi
    if has_mounts_below || is_mnt "$R"; then
      say "refusing: $R has active mounts (use --force, or reboot with the module disabled)"; return 1
    fi
  fi
  need=$((ROOTFS_UNPACKED_MB + 512))
  avail=$(free_mb /data)
  say "/data free: ${avail} MiB, need ~${need} MiB to extract"
  [ "$avail" -ge "$need" ] 2>/dev/null || { say "not enough space on /data"; return 1; }
  if [ -d "$R/etc" ]; then
    ts=$(date +%Y%m%d-%H%M%S)
    say "existing rootfs: backing up $R/etc -> $R/etc.bak-$ts"
    cp -a "$R/etc" "$R/etc.bak-$ts"
  fi
  mkdir -p "$R" && chown 0:0 "$R" && chmod 755 "$R"
  say "extracting to $R (a few minutes) ..."
  if ! ( cd "$R" && bb gzip -dc "$1" | bb tar -xpf - ); then
    say "extraction failed"; return 1
  fi
  touch "$R/.nix-db-pending"
  chown 0:0 "$R"; chmod 755 "$R"; chmod 1777 "$R/tmp"
  if ! { [ -L "$R/bin/sh" ] && [ -L "$R/nix/var/nix/profiles/default" ]; }; then
    say "rootfs looks incomplete"; return 1
  fi
  say "extracted: $(find "$R/nix/store" -mindepth 1 -maxdepth 1 | wc -l) store paths"
}

# bootstrap [local-file]
nixchroot_bootstrap() {
  sane_root
  if rootfs_present && [ "$BOOTSTRAP_FORCE" != 1 ]; then
    say "rootfs already installed at $NIXROOT (reinstall: su -c 'nixroot --bootstrap --force')"; return 0
  fi
  src=$1
  if [ -z "$src" ]; then
    for f in /sdcard/Download/$ROOTFS_NAME /storage/emulated/0/Download/$ROOTFS_NAME; do
      [ -f "$f" ] && { src=$f; say "found browser download: $f"; break; }
    done
  fi
  if [ -n "$src" ]; then
    [ -r "$src" ] || { say "cannot read $src"; return 1; }
    verify_file "$src" || return 1
    tarball=$src
  else
    need=$(( ROOTFS_SIZE / 1048576 + ROOTFS_UNPACKED_MB + 512 ))
    avail=$(free_mb /data)
    [ "$avail" -ge "$need" ] 2>/dev/null || { say "need ~${need} MiB free on /data (have ${avail})"; return 1; }
    download_rootfs || return 1
    verify_file "$DL_FILE" || { rm -f "$DL_FILE"; say "deleted bad download; run again"; return 1; }
    tarball=$DL_FILE
  fi
  extract_rootfs "$tarball" || return 1
  [ "$tarball" = "$DL_FILE" ] && rm -f "$DL_FILE" "$DL_DIR/ca-bundle.pem"
  rmdir "$DL_DIR" 2>/dev/null
  say "mounting ..."
  nixchroot_mount_core
  nixchroot_mount_sdcard
  nixchroot_start_sshd
  say "done. Enter with:  su -c nixroot   (from Termux or any terminal app)"
  say "first entry registers the Nix store (~10 s)."
}
