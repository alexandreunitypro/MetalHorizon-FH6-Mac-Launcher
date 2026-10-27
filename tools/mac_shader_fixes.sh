#!/bin/bash
# Builds the shader fixes the shim hands D3DMetal (HB_TSSHIM_REPLACE=fix, set by tools/mac_launch_fh6.sh) into
# ~/FH6/.blackwell-wine/drive_c/highball/replace/fix/dualsrc, from the shaders HB_TSSHIM_DUMP=1 wrote.
#
# The case it handles: a pipeline that blends render target 0 with a SRC1 factor (dual-source blending) and a pixel
# shader that writes more than SV_Target0 and SV_Target1. D3D12 ignores the extra outputs there; the Metal shader
# converter refuses the shader ("Unable to force-enable dual-source blending") and D3DMetal draws nothing with the
# pipeline (Forza Horizon 6: the skid-mark decals, 8 pipelines). The fixed shader is the same shader with its outputs
# above SV_Target1 removed, and it lands in dualsrc\, which the shim uses only in dual-source pipelines, so a pipeline
# that uses the same shader with three render targets keeps the original.
#
# Which shaders: the pixel shaders of the pipelines D3DMetal logged as "Failed to compile fragment function" in
# out/fh6-after.log, tied to the dumped files through the shim's log (needs a run with HB_TSSHIM_DEBUG=1
# HB_TSSHIM_DUMP=1), plus any dumped shader given on the command line. Each fix is kept only when tools/dxilbench
# shows the converter accepts it with dual-source blending forced on. Nothing else is touched.
# Usage: bash tools/mac_shader_fixes.sh [<dumped .ps file>...]
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HB="$HOME/FH6/.blackwell-wine/drive_c/highball"
DUMP="$HB/shaders"; DEST="$HB/replace/fix/dualsrc"
LOG="$REPO/out/fh6-after.log"
OUT="$REPO/out/vrsprobe"; B="$OUT/dxilbench"
mkdir -p "$OUT" "$DEST"
clang -arch x86_64 -O1 -c "$REPO/tools/tsshim/dxil_shadingrate.c" -o "$OUT/dxil_shadingrate.o" \
    && clang++ -arch x86_64 -std=c++17 -fobjc-arc -O1 -Wno-non-virtual-dtor "$REPO/tools/dxilbench/dxilbench.mm" "$OUT/dxil_shadingrate.o" \
       -framework Metal -framework Foundation -o "$B" || { echo "STOP: dxilbench build failed"; exit 1; }

CANDIDATES=("$@")
SHIMLOG=$(ls -t "$HB"/logs/tsshim-[0-9]*.log 2>/dev/null | head -1)
# the shim's log must come from the same run as the game's log, or the PSO numbers lie: the launcher's stamp says
# when the run began and whether HB_TSSHIM_DEBUG was on (it then moved older shim logs aside)
STAMP="$REPO/out/fh6-run.stamp"; START=$(grep -o 'start=[0-9]*' "$STAMP" 2>/dev/null | cut -d= -f2)
if [ -f "$LOG" ] && [ -n "$SHIMLOG" ] && [ -n "$START" ] && grep -q 'HB_TSSHIM_DEBUG=[^ ]' "$STAMP" \
   && [ "$(stat -f %m "$SHIMLOG")" -ge "$START" ] && grep -q "pipeline [0-9]*: vs" "$SHIMLOG"; then
    # D3DMetal's PSO numbers -> the shim's "pipeline N: ... ps <first 8 digest bytes, little-endian>" -> the dump file
    while read -r h; do
        rev=$(echo "$h" | sed 's/../& /g' | awk '{for (i = NF; i > 0; i--) printf $i}')
        f=$(ls "$DUMP/$rev"*.ps 2>/dev/null | head -1)
        [ -n "$f" ] && CANDIDATES+=("$f")
    done < <(LC_ALL=C grep -a -B1 'Failed to compile a pipeline' "$LOG" | grep -o 'PSO([0-9]*)' | tr -d 'PSO()' | sort -u | while read -r n; do
                 LC_ALL=C grep -a -m1 "pipeline $n: vs" "$SHIMLOG" | grep -o 'ps [0-9a-f]*' | cut -c4-; done | sort -u)
fi
[ ${#CANDIDATES[@]} -gt 0 ] || { echo "nothing to do: no refused pipeline tied to a dumped shader (run once with HB_TSSHIM_DEBUG=1 HB_TSSHIM_DUMP=1)"; exit 0; }

made=0
for f in $(printf '%s\n' "${CANDIDATES[@]}" | sort -u); do
    base=$(basename "$f")
    T=$(mktemp -d)
    cp "$f" "$T/$base"
    # drop outputs from the top down until only SV_Target0 and SV_Target1 are left
    for r in 7 6 5 4 3 2; do
        python3 -I "$REPO/tools/dxilbench/replace_output.py" "$B" "$T/next" "SV_Target#$r" drop "$T/$base" 2>&1 | grep -qF -- '-> drop' \
            && mv "$T/next/$base" "$T/$base"
    done
    if "$B" settings "$T/$base" 2>&1 | grep -q "dual-source blending on .*-> compiles"; then
        if cmp -s "$f" "$T/$base"; then echo "$base: already takes dual-source blending, left alone"
        else cp "$T/$base" "$DEST/$base"; echo "$base: fixed (outputs above SV_Target1 removed), converter accepts it with dual-source blending"; made=$((made + 1)); fi
    else
        echo "$base: not fixed (the converter still refuses it with dual-source blending)"
    fi
    rm -rf "$T"
done
echo "== $made fix(es) in $DEST ($(ls "$DEST" | wc -l | tr -d ' ') in all)"
