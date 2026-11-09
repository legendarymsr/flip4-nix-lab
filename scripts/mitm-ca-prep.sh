#!/usr/bin/env bash
# flip4-mitm-ca-prep [-s SERIAL] [CA.pem]
# Converts a CA cert to Android's <subject_hash_old>.0 PEM format and installs
# it into /data/adb/mitmca/certs.d on the phone (for the mitm-cacert module).
# Default cert: ~/.mitmproxy/mitmproxy-ca-cert.pem
set -euo pipefail
SERIAL=""
if [ "${1:-}" = -s ]; then SERIAL=$2; shift 2; fi
CERT=${1:-$HOME/.mitmproxy/mitmproxy-ca-cert.pem}
[ -r "$CERT" ] || { echo "no cert at $CERT" >&2; exit 1; }
adbc() { local -a a=(adb); [ -n "$SERIAL" ] && a+=(-s "$SERIAL"); "${a[@]}" "$@"; }

inform=PEM; grep -q 'BEGIN CERTIFICATE' "$CERT" || inform=DER
# Android names store entries by the *old* (MD5-based) subject hash.
h=$(openssl x509 -inform "$inform" -subject_hash_old -noout -in "$CERT")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
openssl x509 -inform "$inform" -outform PEM -in "$CERT" > "$tmp/$h.0"
openssl x509 -in "$tmp/$h.0" -noout -subject -enddate -ext basicConstraints
openssl x509 -in "$tmp/$h.0" -noout -ext basicConstraints | grep -q 'CA:TRUE' \
  || { echo "warning: not a CA cert (basicConstraints CA:TRUE missing); Conscrypt won't use it as a root" >&2; }

adbc push "$tmp/$h.0" "/data/local/tmp/$h.0"
adbc shell "su -c 'mkdir -p /data/adb/mitmca/certs.d && mv /data/local/tmp/$h.0 /data/adb/mitmca/certs.d/ && chown 0:0 /data/adb/mitmca/certs.d/$h.0 && chmod 644 /data/adb/mitmca/certs.d/$h.0 && ls -l /data/adb/mitmca/certs.d'"
echo "installed $h.0 -- reboot (the per-boot stage is immutable), then check the module's Action output"
