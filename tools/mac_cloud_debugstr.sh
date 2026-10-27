#!/bin/bash
# Read-only: the game's own diagnostic messages (OutputDebugString, Wine channel "debugstr") around the cloud save
# failure. Needs a run with +debugstr. Tokens are masked. Writes out/cloud-debugstr.txt and opens it in TextEdit.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$REPO/out/fh6-small.log"
OUT="$REPO/out/cloud-debugstr.txt"
MASK() { sed -E 's/XBL3\.0 x=[^";]*;[A-Za-z0-9._+\/=-]*/XBL3.0 <masque>/g; s/eyJ[A-Za-z0-9._-]*/<jwt masque>/g; s/("?(SessionTicket|EntityToken|Ticket|Authorization|Signature)"? *[:=] *)"?[A-Za-z0-9._|+\/=-]{20,}"?/\1<masque>/g'; }
{
echo "journal: $(ls -l "$LOG" | awk '{print $6,$7,$8}')  lignes: $(wc -l < "$LOG")"
FAIL=$(grep -n "ui_failed cloud save sync failed" "$LOG" | head -1 | cut -d: -f1)
echo "premier echec: ligne ${FAIL:-?}   lignes debugstr: $(grep -c ':debugstr:' "$LOG")   lignes OutputDebug: $(grep -ci 'OutputDebugString' "$LOG")"
echo "=== 40 premieres lignes debugstr (masquees)"
grep -n ':debugstr:' "$LOG" | MASK | cut -c1-260 | head -40
if [ -n "${FAIL:-}" ]; then
    echo "=== 60 dernieres lignes debugstr avant l'echec"
    sed -n "1,${FAIL}p" "$LOG" | grep ':debugstr:' | MASK | cut -c1-260 | tail -60
fi
echo "=== lignes err: / warn: (hors FHTRACE, fixme) dans les 1500 dernieres lignes avant l'echec"
[ -n "${FAIL:-}" ] && sed -n "$((FAIL>1500?FAIL-1500:1)),${FAIL}p" "$LOG" | grep ':err:\|:warn:' | grep -v 'FHTRACE\|fixme' | MASK | cut -c1-260 | tail -30
} > "$OUT" 2>&1
wc -l "$OUT"
open -e "$OUT"
