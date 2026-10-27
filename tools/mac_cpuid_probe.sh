#!/bin/bash
# No game. Asks the CPU seen by a Wine process what it announces (AVX / AVX2), without and with ROSETTA_ADVERTISE_AVX=1.
# Result is copied to the clipboard (Cmd+V in the chat). Changes nothing.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
export CX_ROOT="$ENGINE" WINEPREFIX="$HOME/FH6/.blackwell-wine" WINEDEBUG=-all
export DYLD_LIBRARY_PATH="$ENGINE/lib:/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64"
mkdir -p "$REPO/out"; R="$REPO/out/cpuid-report.txt"
{
echo "macOS: $(sw_vers -productVersion)   puce: $(sysctl -n machdep.cpu.brand_string)"
echo "env ROSETTA_ADVERTISE_AVX dans ce Terminal: '${ROSETTA_ADVERTISE_AVX:-<vide>}'"
"$ENGINE/bin/wineserver" -k 2>/dev/null
echo "== 1. sans le reglage"
( unset ROSETTA_ADVERTISE_AVX; "$ENGINE/bin/wine" "$REPO/tools/cpuidprobe/cpuidprobe.exe" 2>&1 | grep -v "^[0-9a-f]*:" )   # not via env(1): SIP strips DYLD_* through it
"$ENGINE/bin/wineserver" -k 2>/dev/null
echo "== 2. avec ROSETTA_ADVERTISE_AVX=1"
ROSETTA_ADVERTISE_AVX=1 "$ENGINE/bin/wine" "$REPO/tools/cpuidprobe/cpuidprobe.exe" 2>&1 | grep -v "^[0-9a-f]*:"
"$ENGINE/bin/wineserver" -k 2>/dev/null
} 2>&1 | tee "$R"
pbcopy < "$R"; echo "== RAPPORT COPIE : colle-le dans le chat (Cmd+V)"
