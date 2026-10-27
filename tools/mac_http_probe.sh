#!/bin/bash
# No game. Two quick, read-only checks (about 1 minute):
#  1. which DLLs in the Wine prefix (drive_c/windows/system32) are full builtin copies that DIFFER from the rebuilt
#     engine's (the game loads the prefix copy, so a stale one silently ignores every fix built into the engine;
#     this is how the old xgameruntime.dll was found)
#  2. tools/httpprobe: replays the game's WinHTTP call sequence against real servers (no credentials) and prints
#     what each call returns, to compare Wine with Windows.
# The report is copied to the clipboard: paste it into the chat (Cmd+V). Changes nothing.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
PFX="$HOME/FH6/.blackwell-wine"
EW="$ENGINE/lib/wine/x86_64-windows"
PS="$PFX/drive_c/windows/system32"
CXLIB="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64"
mkdir -p "$REPO/out"
REPORT="$REPO/out/http-probe-report.txt"
export CX_ROOT="$ENGINE" WINEPREFIX="$PFX" WINEDEBUG="err+all"
export DYLD_LIBRARY_PATH="$ENGINE/lib:$CXLIB"

{
echo "== 1. DLL du prefix comparees au moteur"
same=0; fake=0; missing=0; diff=0
DIFFS=""
for e in "$EW"/*.dll "$EW"/*.exe "$EW"/*.drv "$EW"/*.sys "$EW"/*.ax "$EW"/*.acm "$EW"/*.cpl "$EW"/*.ocx; do
    [ -f "$e" ] || continue
    f=$(basename "$e"); p="$PS/$f"
    [ -f "$p" ] || { missing=$((missing+1)); continue; }
    if head -c 160 "$p" | grep -aq "placeholder"; then fake=$((fake+1)); continue; fi
    if cmp -s "$e" "$p"; then same=$((same+1)); continue; fi
    diff=$((diff+1))
    newer="moteur plus recent"; [ "$p" -nt "$e" ] && newer="prefix plus recent"
    DIFFS="$DIFFS$f  prefix=$(stat -f %z "$p") moteur=$(stat -f %z "$e")  ($newer)
"
done
echo "identiques: $same   fausses (placeholder, chargent le moteur): $fake   absentes du prefix: $missing   DIFFERENTES: $diff"
printf "%s" "$DIFFS" | head -70
echo
echo "== 2. httpprobe (reseau winhttp, sans jeton)"
"$ENGINE/bin/wineserver" -k 2>/dev/null
"$ENGINE/bin/wine" "$REPO/tools/httpprobe/httpprobe.exe" > "$REPO/out/httpprobe.log" 2> "$REPO/out/httpprobe-wine.log" &
PID=$!
for i in $(seq 160); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill "$PID" 2>/dev/null
cut -c1-200 "$REPO/out/httpprobe.log" | head -80
echo "-- messages d'erreur de Wine (hors traces du dev):"
grep -v "FHTRACE\|:fixme:" "$REPO/out/httpprobe-wine.log" | cut -c1-200 | awk '!s[$0]++' | head -12
"$ENGINE/bin/wineserver" -k 2>/dev/null
} 2>&1 | tee "$REPORT"
pbcopy < "$REPORT"
echo "== RAPPORT COPIE : colle-le dans le chat (Cmd+V)"
