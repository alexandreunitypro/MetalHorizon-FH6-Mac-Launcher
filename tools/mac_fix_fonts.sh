#!/bin/bash
# The self-built engine ships no Wine fonts (share/wine/fonts is empty), so message boxes measure their
# text as 0 px wide and macOS draws them as a thin pill. Copy Wine's own fonts from CrossOver.app
# (same project, same files). Undo: tools/mac_fix_fonts.sh --undo (removes only the copied files).
ENGINE="${ENGINE:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine}"
SRC="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/share/wine/fonts"
DST="$ENGINE/share/wine/fonts"
LIST="$DST/.copied-by-fh6-fix"
if [ "${1:-}" = "--undo" ]; then
    [ -f "$LIST" ] && (cd "$DST" && xargs rm -f < "$LIST") && rm -f "$LIST" && echo "copied fonts removed"; exit 0
fi
[ -d "$SRC" ] || { echo "STOP: $SRC not found"; exit 1; }
mkdir -p "$DST"
n=0
for f in "$SRC"/*; do
    b=$(basename "$f"); [ -e "$DST/$b" ] && continue
    cp "$f" "$DST/" && echo "$b" >> "$LIST" && n=$((n+1))
done
echo "fonts copied: $n (now $(ls "$DST" | wc -l | tr -d ' ') files in engine)"
