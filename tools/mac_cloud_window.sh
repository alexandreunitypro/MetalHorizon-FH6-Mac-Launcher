#!/bin/bash
# Read-only: from out/fh6-small.log keep what happens between the PlayFab save configuration being created and the
# "cloud save sync failed" warning (tools/mac_trace_cloudsave.sh), minus boilerplate, plus every network / Xbox-user line.
# Writes out/cloud-window.txt and opens it in TextEdit.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$REPO/out/fh6-small.log"
OUT="$REPO/out/cloud-window.txt"
NOISE='FHTRACE|fixme|opentype|QueryInterface|AddRef|Release iface|QueryApiImpl|XThread|XTaskQueue|XAsyncGetStatus|XAsyncSchedule|XAsyncBegin|XAsyncComplete|deliver_one|complete_without|open_mapped_image_file|no mapped image'
{
echo "journal: $(ls -l "$LOG" | awk '{print $6,$7,$8}')  lignes: $(wc -l < "$LOG")"
FAIL=$(grep -n "ui_failed cloud save sync failed" "$LOG" | head -1 | cut -d: -f1)
START=$(grep -n "pfx_config_create created" "$LOG" | awk -F: -v f="${FAIL:-0}" '$1 < f {l=$1} END {print l}')
echo "premiere creation de config: ligne ${START:-?}   premier echec: ligne ${FAIL:-?}"
echo "=== compte de lignes par canal (tout le journal)"
for c in winhttp wininet winsock secur32 schannel gdkc xgameruntime pfxgamesave; do printf "%s: %s\n" "$c" "$(grep -c ":$c:" "$LOG")"; done
echo "=== lignes Xbox user / token / HTTP (toutes, 40 max)"
grep -n "XUser\|XCurl\|GetToken\|token\|WinHttp\|InternetOpen\|HttpOpen\|HttpSend\|connect " "$LOG" | grep -v "$NOISE" | cut -c1-260 | head -40
if [ -n "${START:-}" ] && [ -n "${FAIL:-}" ]; then
    echo "=== fenetre $START - $FAIL (sans bruit, 100 max)"
    sed -n "${START},${FAIL}p" "$LOG" | grep -vE "$NOISE" | cut -c1-260 | head -100
fi
} 2>&1 | sed -E 's/XBL3\.0 x=[^";]*;[A-Za-z0-9._+\/=-]*/XBL3.0 <masque>/g; s/eyJ[A-Za-z0-9._-]*/<jwt masque>/g; s/(L"Signature": L")[^"]*/\1<masque>/; s/(Signature:)[A-Za-z0-9+\/=]*/\1<masque>/g' > "$OUT"
wc -l "$OUT"
open -e "$OUT"
