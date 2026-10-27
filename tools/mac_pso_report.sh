#!/bin/bash
# Pipelines D3DMetal refused in the last run (out/fh6-after.log), by reason, against the run kept as
# out/fh6-after.avant-shadingrate.log; what the shim did (its HB_TSSHIM_DEBUG log); and, when the run had
# HB_TSSHIM_DUMP=1, the dumped pixel shaders run through tools/dxilbench scan. Reads only.
# Usage: [NO_SCAN=1] bash tools/mac_pso_report.sh [log, default out/fh6-after.log]
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOG="${1:-$REPO/out/fh6-after.log}"
BEFORE="$REPO/out/fh6-after.avant-shadingrate.log"
HB="$HOME/FH6/.blackwell-wine/drive_c/highball"
count() { LC_ALL=C grep -c "$1" "$2" 2>/dev/null || true; }

for f in "$BEFORE" "$LOG"; do
    [ -f "$f" ] || continue
    echo "== $(basename "$f")  ($(wc -l < "$f" | tr -d ' ') lines, $(stat -f '%Sm' "$f"))"
    echo "   pipelines marked no-op:              $(count 'marking PSO' "$f")"
    echo "   refused: sv_shadingrate0 input       $(count 'sv_shadingrate0' "$f")"
    echo "   refused: fragment function compile   $(count 'Failed to compile fragment function' "$f")"
    echo "   other 'Failed to create pipeline state' reasons:"
    LC_ALL=C grep -o 'Failed to create pipeline state: Error Domain=[A-Za-z0-9]* Code=[0-9]* "[^"]*"' "$f" | grep -v sv_shadingrate0 \
        | sed 's/^Failed to create pipeline state: //' | sort | uniq -c | sort -rn | head -10 | sed 's/^/     /'
    echo "   D3DMetal 'Unsupported:' calls:"
    LC_ALL=C grep -o 'Unsupported: [A-Za-z0-9_:]*' "$f" | sort | uniq -c | sort -rn | head -10 | sed 's/^/     /'
done

SHIMLOG=$(ls -t "$HB"/logs/tsshim-*.log 2>/dev/null | head -1)
if [ -n "$SHIMLOG" ]; then
    echo "== shim log $(basename "$SHIMLOG") ($(stat -f '%Sm' "$SHIMLOG"))"
    grep -m1 "loaded in front" "$SHIMLOG" | sed 's/^/   /'
    echo "   pixel shaders fixed (SV_ShadingRate read as 0): $(grep 'handed over with it read as 0' "$SHIMLOG" | tail -1 | grep -o '([0-9]* so far)' || echo none)"
    echo "   pipelines carrying a fixed pixel shader:       $(grep -c "pixel shader's SV_ShadingRate read as 0" "$SHIMLOG")"
    echo "   pixel shaders left as they were:               $(grep -c 'left as it is' "$SHIMLOG")"
    grep 'left as it is' "$SHIMLOG" | sed 's/^.*: pixel/   pixel/' | sort | uniq -c | head -5
    # D3DMetal's PSO numbers -> the shim's pipeline lines (same counter while HB_TSSHIM_DEBUG serialises creation)
    echo "   fragment-compile failures tied to the shim's pipeline lines (D3DMetal PSO number -> pixel shader):"
    LC_ALL=C grep -B1 'Failed to compile a pipeline' "$LOG" | grep -o 'PSO([0-9]*)' | tr -d 'PSO()' | head -80 | while read -r n; do
        grep -m1 "pipeline $n: " "$SHIMLOG" | sed -E "s/^.*pipeline ($n): (.*)/     PSO \1: \2/" | cut -c1-140
    done | sort | uniq | head -40
fi

if [ -d "$HB/shaders" ] && [ -z "${NO_SCAN:-}" ]; then
    NPS=$(ls "$HB/shaders" | grep -c '\.ps$'); NVS=$(ls "$HB/shaders" | grep -c '\.vs$')
    echo "== dumped shaders: $NPS pixel, $NVS vertex ($(du -sh "$HB/shaders" | cut -f1))"
    OUT="$REPO/out/vrsprobe"; mkdir -p "$OUT"
    clang -arch x86_64 -O1 -c "$REPO/tools/tsshim/dxil_shadingrate.c" -o "$OUT/dxil_shadingrate.o" \
        && clang++ -arch x86_64 -std=c++17 -fobjc-arc -O1 -Wno-non-virtual-dtor "$REPO/tools/dxilbench/dxilbench.mm" "$OUT/dxil_shadingrate.o" \
           -framework Metal -framework Foundation -o "$OUT/dxilbench" || { echo "STOP: dxilbench build failed"; exit 1; }
    "$OUT/dxilbench" scan "$HB/shaders" > "$REPO/out/dxilbench-scan.txt" 2>&1
    echo "   $(grep '^SCAN [0-9]' "$REPO/out/dxilbench-scan.txt")   (details: out/dxilbench-scan.txt)"
    grep -o 'converter refused it.*\|Metal refused the library.*' "$REPO/out/dxilbench-scan.txt" | cut -c1-160 | sort | uniq -c | sort -rn | head -10 | sed 's/^/     /'
fi
