#!/bin/bash
# What is the game doing while it stutters? Uses macOS's built-in `sample` (no Xcode, small text output): every 1 ms it
# records what each thread of the game process is running, for N seconds, then lists where the time goes (top of stack).
# Start the game (tools/jouer.sh), drive where it hitches, and run this in ANOTHER Terminal window:
#   bash tools/mac_sample_hitch.sh [seconds, default 10]
# Result: out/sample-game.txt (full) and out/sample-summary.txt (about 6 KB, copied to the clipboard).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"; SECS="${1:-10}"; mkdir -p "$REPO/out"
LINE=$(ps -axo pid,%cpu,command | grep -i "[f]orzahorizon6" | grep -v "xodus-cli" | sort -k2 -nr | head -1)
PID=$(echo "$LINE" | awk '{print $1}')
[ -n "$PID" ] || { echo "STOP: le jeu ne tourne pas (lance tools/jouer.sh d'abord)"; exit 1; }
echo "processus: $(echo "$LINE" | cut -c1-120)"
echo "== echantillonnage de $SECS s (roule la ou ca saccade)"
sample "$PID" "$SECS" 1 -file "$REPO/out/sample-game.txt" > "$REPO/out/sample.log" 2>&1
[ -s "$REPO/out/sample-game.txt" ] || { echo "STOP: pas de resultat: $(head -c 300 "$REPO/out/sample.log")"; exit 1; }
S="$REPO/out/sample-summary.txt"
{
echo "echantillon: $SECS s a 1 ms, $(wc -c < "$REPO/out/sample-game.txt") octets"
grep -m1 "^Process:" "$REPO/out/sample-game.txt"; grep -m1 "^Physical footprint" "$REPO/out/sample-game.txt"
echo "== threads les plus occupes (lignes 'Thread_' du call graph, 12 premieres)"
grep -n "Thread_" "$REPO/out/sample-game.txt" | head -12 | cut -c1-170
echo "== ou va le temps (Sort by top of stack), 45 premieres lignes"
awk '/^Sort by top of stack/ {p=1} p' "$REPO/out/sample-game.txt" | head -46 | cut -c1-170
} > "$S"
wc -c "$S"; pbcopy < "$S"; echo "== RESUME COPIE (presse-papiers) ; sinon:  open -e $S"
