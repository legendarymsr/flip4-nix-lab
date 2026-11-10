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
    # 0.3.1 and older defaulted to Cloudflare + Quad9; move the untouched
    # default to Quad9 only (a DNS line the user edited is left alone).
    if grep -q '^DNS="1.1.1.1 9.9.9.9"$' /data/adb/nixchroot/config; then
      sed -i 's/^DNS="1.1.1.1 9.9.9.9"$/DNS="9.9.9.9 149.112.112.112 2620:fe::fe"/' /data/adb/nixchroot/config
      ui_print "- DNS default changed to Quad9 only"
    fi
  fi
  for f in nixroot system/bin/nixroot bin/curl post-fs-data.sh service.sh action.sh uninstall.sh; do
    [ -e "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
  done
  # `nixroot` on PATH for `su -c nixroot`: KernelSU puts /data/adb/ksu/bin
  # on su's PATH; the system/bin overlay only exists with a mounting metamodule.
  if [ -d /data/adb/ksu/bin ]; then
    ln -sf /data/adb/modules/nixchroot/nixroot /data/adb/ksu/bin/nixroot
  fi
  if [ -d /data/local/nix/nix/store ]; then
    ui_print "- rootfs present at /data/local/nix"
  else
    ui_print "- no rootfs yet: reboot, then tap Action on this module"
    ui_print "  (or: su -c 'nixroot --bootstrap'). Downloads ~1.2 GiB."
  fi
}
