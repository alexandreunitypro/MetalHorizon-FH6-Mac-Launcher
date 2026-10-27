#!/bin/bash
# Apple's Metal System Trace (Instruments' timeline: CPU/GPU work, command buffers, shader compilation, frame pacing),
# recorded from the command line on the RUNNING game. Needs FULL Xcode (xctrace); the HUD works without it.
#   1. start the game as usual (tools/jouer.sh) in one Terminal window
#   2. in ANOTHER window, while it stutters:  bash tools/mac_metal_trace.sh [seconds, default 30]
# If nothing happens: a macOS permission window may be hidden BEHIND the full-screen game (Cmd+Tab to find it).
# WINDOW MODE (for a stutter that comes now and then):  bash tools/mac_metal_trace.sh fenetre [seconds, default 10]
#   records for as long as you like but keeps only the LAST N seconds (xctrace --window); press Ctrl+C right AFTER a stutter.
# Result: out/metal-HHMMSS.trace (double-click it: Instruments opens it). Changes nothing.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MODE=fixed; if [ "${1:-}" = "fenetre" ]; then MODE=window; SECS="${2:-10}"; else SECS="${1:-15}"; fi
XCT="$(xcrun -f xctrace 2>/dev/null)"
if [ -z "$XCT" ]; then
    echo "STOP: xctrace est absent. Il faut Xcode complet (App Store, gratuit, plusieurs Go), puis:  sudo xcode-select -s /Applications/Xcode.app"
    echo "      (xcode-select -p donne actuellement: $(xcode-select -p 2>&1))"
    exit 1
fi
# the game process, not xodus-cli (whose command line also names the exe): most CPU among the matches
LINE=$(ps -axo pid,%cpu,command | grep -i "[f]orzahorizon6" | grep -v "xodus-cli" | sort -k2 -nr | head -1)
PID=$(echo "$LINE" | awk '{print $1}')
[ -n "$PID" ] || { echo "STOP: le jeu ne tourne pas (lance tools/jouer.sh d'abord)"; exit 1; }
echo "processus choisi: $(echo "$LINE" | cut -c1-150)"
mkdir -p "$REPO/out"; OUT="$REPO/out/metal-$(date +%H%M%S).trace"
[ "$MODE" = fixed ] && echo "== enregistrement de $SECS s (joue / roule pendant ce temps)"
if [ "$MODE" = window ]; then
    echo "== mode fenetre: je garde seulement les ${SECS} DERNIERES secondes. Joue normalement ; juste APRES une saccade, fais Ctrl+C UNE fois (et attends la fin)."
    "$XCT" record --template "Metal System Trace" --attach "$PID" --window "${SECS}s" --no-prompt --output "$OUT" 2>&1
else
    "$XCT" record --template "Metal System Trace" --attach "$PID" --time-limit "${SECS}s" --output "$OUT" 2>&1
fi   # live output, no filter: a silent hang or a permission prompt must be visible
if [ -d "$OUT" ] || [ -f "$OUT" ]; then
    "$XCT" export --input "$OUT" --toc > "$OUT.toc.xml" 2>&1
    echo "== contenu de la trace (tables):"; grep -o 'schema name="[^"]*"' "$OUT.toc.xml" | sort -u | head -30
    open -R "$OUT"; echo "== trace: $OUT (double-clic: Instruments)"
else
    echo "STOP: pas de fichier de trace (voir les messages ci-dessus; il faut parfois autoriser Terminal dans Reglages > Confidentialite > Outils de developpement)"
fi
