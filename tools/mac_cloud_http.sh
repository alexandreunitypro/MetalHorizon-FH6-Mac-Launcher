#!/bin/bash
# Read-only: summarize the network side of the cloud save failure from out/fh6-small.log (needs a run with +winhttp).
# Tokens, signatures and Authorization values are masked before anything is written.
# Writes out/cloud-http.txt and opens it in TextEdit.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$REPO/out/fh6-small.log"
OUT="$REPO/out/cloud-http.txt"
MASK() { sed -E 's/XBL3\.0 x=[^";]*;[A-Za-z0-9._+\/=-]*/XBL3.0 <masque>/g; s/eyJ[A-Za-z0-9._-]*/<jwt masque>/g; s/(L"Signature": L")[^"]*/\1<masque>/; s/(Signature:)[A-Za-z0-9+\/=]*/\1<masque>/g'; }
{
echo "journal: $(ls -l "$LOG" | awk '{print $6,$7,$8}')  lignes: $(wc -l < "$LOG")"
FAIL=$(grep -n "ui_failed cloud save sync failed" "$LOG" | head -1 | cut -d: -f1)
echo "premier echec de sync: ligne ${FAIL:-?}"
echo "=== serveurs contactes (WinHttpConnect), avec nombre"
grep -o 'WinHttpConnect [0-9]*, L"[^"]*", [0-9]*' "$LOG" | sed -E 's/^WinHttpConnect [0-9]*, //' | sort | uniq -c | sort -rn | head -25
echo "=== lignes contenant playfab (30 max)"
grep -in "playfab" "$LOG" | grep -v "open_mapped_image_file\|no mapped image\|FHTRACE\|loaddll" | MASK | cut -c1-260 | head -30
echo "=== lignes winhttp qui parlent d'erreur / echec / statut (40 max)"
grep ":winhttp:" "$LOG" | grep -v "addref_object\|grab_object\|release_object\|get_header_index\|process_header\|free_handle\|connect_destroy" | grep -i "err\|fail\|status\|12[0-9][0-9][0-9]\|0x8007\|ssl\|cert\|tls\|secure" | MASK | cut -c1-240 | head -40
echo "=== 25 lignes avant l'echec (sans bruit, masquees)"
if [ -n "${FAIL:-}" ]; then
    sed -n "$((FAIL>400?FAIL-400:1)),${FAIL}p" "$LOG" | grep -v "FHTRACE\|fixme\|opentype\|QueryInterface\|AddRef\|addref_object\|grab_object\|release_object\|get_header_index\|process_header\|Release iface\|QueryApiImpl\|XThread\|XTaskQueue\|XAsync\|deliver_one\|complete_without" | MASK | cut -c1-240 | tail -25
fi
} > "$OUT" 2>&1
wc -l "$OUT"
open -e "$OUT"
