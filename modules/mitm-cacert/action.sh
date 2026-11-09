#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR/../..
# KernelSU "Action": re-inject into every zygote/app namespace now and report.
MODDIR=${0%/*}
MITMCA_VERBOSE=1
# shellcheck source=modules/mitm-cacert/common.sh
. "$MODDIR/common.sh"
stage_all || { echo "no certs in $MITMCA_CERTS"; exit 0; }
inject_all
s=$(first_cert)
echo "sentinel: $s"
for z in $(zygote_pids); do
  if "$BB" nsenter -t "$z" -m -- /system/bin/sh -c "[ -e '$APEX_CACERTS/$s' ]"; then st=ok; else st=MISSING; fi
  echo "  $(cat "/proc/$z/comm") ($z): $st"
done
echo "Changed certs.d? Reboot: the per-boot stage is immutable by design."
