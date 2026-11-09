# shellcheck shell=sh
# KernelSU install-time hook (sourced by ksud; MODPATH, ui_print, set_perm provided).
# shellcheck disable=SC2154
{
  ui_print "- nixchroot: aarch64 Nix chroot for the flip4 lab"
  if [ "$ARCH" != arm64 ]; then abort "! arm64 only (got $ARCH)"; fi
  mkdir -p /data/adb/nixchroot
  chmod 700 /data/adb/nixchroot
  if [ ! -f /data/adb/nixchroot/config ]; then
    cp "$MODPATH/config.default" /data/adb/nixchroot/config
    ui_print "- wrote default /data/adb/nixchroot/config"
  else
    ui_print "- keeping existing /data/adb/nixchroot/config"
  fi
  for f in nixroot system/bin/nixroot post-fs-data.sh service.sh action.sh uninstall.sh; do
    [ -e "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
  done
  [ -d /data/local/nix/nix/store ] || ui_print "- no rootfs yet: run 'nix run .#install' from your machine"
}
