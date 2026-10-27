#!/bin/bash
# Read-only: how each PlayFab login response (Content-Length 1071) is handled by winhttp, to compare the game's own
# logins (which work) with the save SDK's login (after which "cloud save sync failed" appears).
# Needs a run with +winhttp +pfxgamesave. Tokens are masked. Writes out/cloud-logins.txt, opens it in TextEdit.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${CLOUD_LOG:-$REPO/out/fh6-small.log}"
OUT="${CLOUD_OUT:-$REPO/out/cloud-logins.txt}"
MASK() { sed -E 's/XBL3\.0 x=[^";]*;[A-Za-z0-9._+\/=-]*/XBL3.0 <masque>/g; s/eyJ[A-Za-z0-9._-]*/<jwt masque>/g; s/(L"Signature": L")[^"]*/\1<masque>/'; }
QUIET='addref_object|grab_object|release_object|get_header_index|process_header|free_handle|connect_destroy|request_destroy|stop_queue|task_callback|queue_task|WinHttpAddRequestHeaders|WinHttpSetOption|WinHttpSetTimeouts|netconn_secure_connect|netconn_verify|netconn_release|read_line|WinHttpOpenRequest|WinHttpConnect |full request'
{
echo "journal: $(ls -l "$LOG" | awk '{print $6,$7,$8}')  lignes: $(wc -l < "$LOG")"
FAIL=$(grep -n "ui_failed cloud save sync failed" "$LOG" | head -1 | cut -d: -f1)
echo "premier echec (boite): ligne ${FAIL:-?}   lignes winhttp: $(grep -c ':winhttp:' "$LOG")"
echo "=== requetes LoginWithXbox (ligne, 110 premiers caracteres)"
grep -n 'full request: "POST /Client/LoginWithXbox' "$LOG" | cut -c1-110
echo "=== reponses de 1071 octets (ligne)"
RESP=$(grep -n 'read_reply raw headers.*Content-Length: 1071' "$LOG" | cut -d: -f1)
echo $RESP
n=0
for r in $RESP; do
    n=$((n+1))
    echo "=== reponse $n (ligne $r): 40 lignes winhttp qui suivent, sans le bruit"
    sed -n "$((r+1)),$((r+1500))p" "$LOG" | grep ':winhttp:' | grep -vE "$QUIET" | MASK | cut -c1-170 | head -40
done
if [ -n "${FAIL:-}" ]; then
    echo "=== 40 lignes (tous canaux, sans bruit) juste avant la boite"
    sed -n "$((FAIL>1200?FAIL-1200:1)),${FAIL}p" "$LOG" | grep -vE "FHTRACE|fixme|opentype|$QUIET" | MASK | cut -c1-170 | tail -40
fi
} > "$OUT" 2>&1
wc -l "$OUT"
command -v open >/dev/null && open -e "$OUT"
exit 0
