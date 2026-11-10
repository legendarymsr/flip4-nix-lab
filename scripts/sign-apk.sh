# sign-apk UNSIGNED.apk OUT.apk
# Signs the reproducible unsigned companion APK (v2+v3). Key from env:
#   FLIP4_KEYSTORE   path to a PKCS12/JKS keystore
#   FLIP4_KEY_PASS   its password (store and key)
#   FLIP4_KEY_ALIAS  alias (default: flip4)
set -euo pipefail
in=${1:?unsigned apk}; out=${2:?output apk}
: "${FLIP4_KEYSTORE:?set FLIP4_KEYSTORE}" "${FLIP4_KEY_PASS:?set FLIP4_KEY_PASS}"
apksigner sign --ks "$FLIP4_KEYSTORE" --ks-key-alias "${FLIP4_KEY_ALIAS:-flip4}" \
  --ks-pass env:FLIP4_KEY_PASS --key-pass env:FLIP4_KEY_PASS \
  --v1-signing-enabled false --v2-signing-enabled true --v3-signing-enabled true \
  --out "$out" "$in"
rm -f "$out.idsig"
apksigner verify --print-certs "$out" | grep -E 'SHA-256|DN'
