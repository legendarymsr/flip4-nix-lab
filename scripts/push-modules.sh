#!/usr/bin/env bash
# flip4-push-modules [-s SERIAL] [ZIP...]
# adb push KernelSU module zips and install them with ksud. Defaults to the
# zips built by this flake ($FLIP4_MODULES, set by `nix run .#push-modules`).
set -euo pipefail
SERIAL=""
if [ "${1:-}" = -s ]; then SERIAL=$2; shift 2; fi
adbc() { local -a a=(adb); [ -n "$SERIAL" ] && a+=(-s "$SERIAL"); "${a[@]}" "$@"; }
if [ $# -eq 0 ]; then
  # shellcheck disable=SC2086
  set -- ${FLIP4_MODULES:-}
fi
[ $# -gt 0 ] || { echo "usage: $0 [-s SERIAL] module.zip..." >&2; exit 1; }
for z in "$@"; do
  b=$(basename "$z")
  adbc push "$z" "/data/local/tmp/$b"
  adbc shell "su -c '/data/adb/ksud module install /data/local/tmp/$b; rm -f /data/local/tmp/$b'"
done
echo "installed: $* -- reboot to activate"
