#!/bin/bash
# While the game runs: list its windows and the text inside them (e.g. a message box macOS draws too
# small to read). Uses the same Wine and prefix as the game, changes nothing.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
export CX_ROOT="$ENGINE" WINEPREFIX="$ROOT/work/audit/gamefarm-audit/.blackwell-wine" WINEDEBUG=-all
export DYLD_LIBRARY_PATH="$ENGINE/lib:/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64"
"$ENGINE/bin/wine" "$REPO/tools/winlist/winlist.exe" 2>&1 | grep -v "fixme\|^[0-9a-f]*:err" | grep -v '^window .* visible 0 .*title ""$'
