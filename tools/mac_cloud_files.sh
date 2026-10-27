#!/bin/bash
# Read-only: what the PlayFab save SDK does to files between the PlayFab login and the "cloud save sync failed"
# warning. Needs a run with +file (see PASSATION). Writes out/cloud-files2.txt and opens it in TextEdit.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$REPO/out/fh6-small.log"
OUT="$REPO/out/cloud-files2.txt"
MASK() { sed -E 's/XBL3\.0 x=[^";]*;[A-Za-z0-9._+\/=-]*/XBL3.0 <masque>/g; s/eyJ[A-Za-z0-9._-]*/<jwt masque>/g'; }
{
echo "journal: $(ls -l "$LOG" | awk '{print $6,$7,$8}')  lignes: $(wc -l < "$LOG")"
FAIL=$(grep -n "ui_failed cloud save sync failed" "$LOG" | head -1 | cut -d: -f1)
echo "premier echec: ligne ${FAIL:-?}   lignes file: $(grep -c ':file:' "$LOG")"
echo "=== operations sur PFXGameSave (hors backend), 60 max, avec 2 lignes de suite"
grep -n -A2 'PFXGameSave' "$LOG" | grep -v 'backend\|pgs-\|get_memory_section_name\|FHTRACE\|loaddll' | MASK | cut -c1-250 | head -60
echo "=== operations sur wgs ou SystemAppData (hors PFXGameSave), 30 max"
grep -n 'wgs\|SystemAppData' "$LOG" | grep -v 'PFXGameSave\|FHTRACE\|loaddll' | MASK | cut -c1-250 | head -30
echo "=== codes d'erreur (c000...) dans les 3000 lignes avant l'echec, par nombre"
if [ -n "${FAIL:-}" ]; then
    sed -n "$((FAIL>3000?FAIL-3000:1)),${FAIL}p" "$LOG" | grep ':file:\|:ntdll:\|:kernelbase:\|:sync:' | grep -o 'c000[0-9a-f]\{4\}\|0xc000[0-9a-f]\{4\}' | sort | uniq -c | sort -rn | head -12
    echo "=== 25 dernieres lignes file/ntdll/kernelbase avant l'echec"
    sed -n "$((FAIL>3000?FAIL-3000:1)),${FAIL}p" "$LOG" | grep ':file:\|:ntdll:\|:kernelbase:' | grep -v 'FHTRACE' | MASK | cut -c1-250 | tail -25
fi
} > "$OUT" 2>&1
wc -l "$OUT"
open -e "$OUT"
