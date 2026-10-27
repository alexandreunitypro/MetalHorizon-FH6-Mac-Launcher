#!/bin/bash
# Runs tools/vrsprobe (no game) in the game's exact graphics setup (FH6_CX_GPTK=1 FH6_D3DM4=1, Highball
# shim in front, GPU identity from FH6_GPU). It runs in its own scratch prefix (out/probe-prefix), so it
# neither needs nor disturbs a running game, and changes nothing installed.
#   features   (default) what the device answers about Variable Rate Shading (OPTIONS6) and other options
#   pipeline   a pipeline whose pixel shader reads SV_ShadingRate, built and drawn like the game does;
#              prints the pixel read back and D3DMetal's "no-op" lines
#   targets <ps> <n> [dual]  a pipeline with a dumped game pixel shader (path on the Mac), n render targets and,
#              with dual, a dual-source blend on render target 0;
#              prints D3DMetal's "Failed to compile fragment function" lines
#   inspect [seconds]  tools/inspectprobe: eight triangles that each lose their pixels at a known step, drawn for a
#              while with the shim's inspector on (HB_TSSHIM_INSPECT=1, always the new shim); prints what
#              tools/mac_fh6_inspect.sh makes of its log, which must match the expected answer
#   --new-shim (with any) use the shim built from the current tools/tsshim sources, laid out in
#              out/vrsprobe/shim, instead of the installed one
# Usage: [FH6_GPU=nvidia|intel|amd] [FH6_NO_SHIM=1] [HB_TSSHIM_SHADINGRATE=0] bash tools/mac_vrs_probe.sh [features|pipeline] [--new-shim]
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
GPTK="/Users/alexandre/.codex/visualizations/2026/10/19/01a1562c-64fc-74c0-9f71-acf814cbaad7/Blackwell FH6 Final.app/Contents/Resources/GPTK4/external"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
CXWINE="$CX/lib64/apple_gptk/wine"
HBSHIM="$ENGINE/renderers/d3dmetal-tsshim-hb/wine"
CC="$ROOT/work/toolchains/llvm-mingw-20260908-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang"
OUT="$REPO/out/vrsprobe"; mkdir -p "$OUT"
MODE=features; NEWSHIM=; ARGS=()
for a in "$@"; do case "$a" in pipeline|features|targets) MODE=$a ;; inspect) MODE=inspect; NEWSHIM=1 ;; --new-shim) NEWSHIM=1 ;; *) ARGS+=("$a") ;; esac; done
"$CC" -O2 -Wall -o "$OUT/vrsprobe.exe" "$REPO/tools/vrsprobe/vrsprobe.c" || { echo "STOP: probe build failed"; exit 1; }

if [ -n "$NEWSHIM" ]; then
    HBSHIM="$OUT/shim/wine"; rm -rf "$OUT/shim"; mkdir -p "$HBSHIM/x86_64-windows" "$HBSHIM/x86_64-unix"
    "$CC" -shared -O2 -Wall -static-libgcc -o "$HBSHIM/x86_64-windows/d3d12.dll" "$REPO/tools/tsshim/d3d12.c" \
        "$REPO/tools/tsshim/dxil_shadingrate.c" "$REPO/tools/tsshim/inspect.c" "$REPO/tools/tsshim/d3d12.def" || { echo "STOP: shim build failed"; exit 1; }
    python3 "$REPO/tools/pe_tools.py" mark-builtin "$HBSHIM/x86_64-windows/d3d12.dll" >/dev/null
    cp "$CXWINE/x86_64-windows/d3d12.dll" "$HBSHIM/x86_64-windows/apd12.dll"
    python3 "$REPO/tools/pe_tools.py" rename-export "$HBSHIM/x86_64-windows/apd12.dll" apd12.dll >/dev/null
    python3 "$REPO/tools/pe_tools.py" mark-builtin "$HBSHIM/x86_64-windows/apd12.dll" >/dev/null
    ln -sf "$CXWINE/x86_64-unix/d3d12.so" "$HBSHIM/x86_64-unix/apd12.so"
fi

if [ "$MODE" = pipeline ] || [ "$MODE" = targets ] || [ "$MODE" = inspect ]; then
    # the test shaders come from the DXC inside D3DMetal.framework, through tools/dxilbench (macOS, x86_64)
    clang -arch x86_64 -O1 -c "$REPO/tools/tsshim/dxil_shadingrate.c" -o "$OUT/dxil_shadingrate.o" \
        && clang++ -arch x86_64 -std=c++17 -fobjc-arc -O1 -Wno-non-virtual-dtor "$REPO/tools/dxilbench/dxilbench.mm" "$OUT/dxil_shadingrate.o" \
           -framework Metal -framework Foundation -o "$OUT/dxilbench" \
        && "$OUT/dxilbench" emit "$OUT" >/dev/null || { echo "STOP: dxilbench failed"; exit 1; }
fi
if [ "$MODE" = inspect ]; then
    I="$OUT/inspect"; mkdir -p "$I"
    "$CC" -O2 -Wall -o "$I/inspectprobe.exe" "$REPO/tools/inspectprobe/inspectprobe.c" || { echo "STOP: inspectprobe build failed"; exit 1; }
    printf '%s\n' 'cbuffer C : register(b0) { float4 p; };' \
        'float4 main(uint id : SV_VertexID) : SV_Position' \
        '{ uint i = p.w > 0.5 ? 2 - id : id; float2 uv = float2((i << 1) & 2, i & 2); return float4(uv * 2 - 1 + p.xy, p.z, 1); }' > "$I/vs.hlsl"
    printf '%s\n' 'float4 main() : SV_Target { return float4(1, 0.5, 0, 1); }' > "$I/ps_color.hlsl"
    printf '%s\n' 'float4 main(float4 pos : SV_Position) : SV_Target { if (pos.x >= 0) discard; return float4(1, 1, 1, 1); }' > "$I/ps_discard.hlsl"
    "$OUT/dxilbench" hlsl "$I/vs.hlsl" vs_6_6 "$I/vs.dxil" >/dev/null && "$OUT/dxilbench" hlsl "$I/ps_color.hlsl" ps_6_6 "$I/ps_color.dxil" >/dev/null \
        && "$OUT/dxilbench" hlsl "$I/ps_discard.hlsl" ps_6_6 "$I/ps_discard.dxil" >/dev/null || { echo "STOP: test shaders did not compile"; exit 1; }
fi

export CX_ROOT="$ENGINE" CX_GRAPHICS_BACKEND=d3dmetal WINEPREFIX="$REPO/out/probe-prefix" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree,mshtml=" D3DM_MTL4=1 WINEMSYNC=1
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$GPTK/libd3dshared.dylib"
export DYLD_LIBRARY_PATH="$ENGINE/lib:$CX/lib64:$GPTK" DYLD_FRAMEWORK_PATH="$GPTK"
case "${FH6_GPU:-nvidia}" in
    intel) export D3DM_VENDOR_ID=32902 D3DM_DEVICE_ID=22177 D3DM_DEVICE_DESCRIPTION="Intel(R) Arc(TM) A750 Graphics" ;;
    amd)   export D3DM_VENDOR_ID=4098 D3DM_DEVICE_ID=29631 D3DM_DEVICE_DESCRIPTION="AMD Radeon RX 6800 XT" ;;
    *)     export D3DM_VENDOR_ID=4318 D3DM_DEVICE_ID=10118 D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 4070" ;;
esac
if [ -z "${FH6_NO_SHIM:-}" ]; then
    export WINEDLLPATH_PREPEND="$HBSHIM:$CXWINE" HB_D3D12_REAL="Z:$HBSHIM/x86_64-windows/apd12.dll"
    echo "setup: ${NEWSHIM:+NEW }shim + CrossOver d3d12 + D3DMetal 4.0b3, GPU $D3DM_DEVICE_DESCRIPTION${HB_TSSHIM_SHADINGRATE:+, HB_TSSHIM_SHADINGRATE=$HB_TSSHIM_SHADINGRATE}"
else
    export WINEDLLPATH_PREPEND="$CXWINE"
    echo "setup: NO shim, CrossOver d3d12 + D3DMetal 4.0b3, GPU $D3DM_DEVICE_DESCRIPTION"
fi
"$ENGINE/bin/wineserver" -k 2>/dev/null
if [ "$MODE" = inspect ]; then
    LOGS="$WINEPREFIX/drive_c/highball/logs"; mkdir -p "$LOGS"; rm -f "$LOGS"/inspect-*.log
    HB_TSSHIM_INSPECT=1 HB_TSSHIM_INSPECT_PERIOD=400 HB_TSSHIM_INSPECT_WINDOW=150 \
        "$ENGINE/bin/wine" "$I/inspectprobe.exe" "Z:$I/vs.dxil" "Z:$I/ps_color.dxil" "Z:$I/ps_discard.dxil" "${ARGS[0]:-12}" > "$I/run.log" 2>&1
    tr -d '\r' < "$I/run.log" | grep PROBE
    ILOG=$(ls -t "$LOGS"/inspect-*.log 2>/dev/null | head -1)
    [ -n "$ILOG" ] || { echo "STOP: no inspector log"; exit 1; }
    cp "$ILOG" "$I/inspect.log"
    echo "inspector log: $I/inspect.log ($(wc -l < "$I/inspect.log" | tr -d ' ') lines)"
    python3 "$REPO/tools/mac_fh6_inspect.py" --probe "$I/inspect.log"
elif [ "$MODE" = pipeline ]; then
    "$ENGINE/bin/wine" "$OUT/vrsprobe.exe" pipeline "Z:$OUT/vs.dxil" "Z:$OUT/ps.dxil" > "$OUT/pipeline.log" 2>&1
    tr -d '\r' < "$OUT/pipeline.log" | grep PROBE
    echo "D3DMetal pipelines marked no-op: $(grep -c 'marking PSO' "$OUT/pipeline.log")   sv_shadingrate refusals: $(grep -c 'sv_shadingrate0' "$OUT/pipeline.log")"
elif [ "$MODE" = targets ]; then
    "$ENGINE/bin/wine" "$OUT/vrsprobe.exe" targets "Z:$OUT/vs.dxil" "Z:${ARGS[0]}" "${ARGS[1]:-0}" ${ARGS[2]:-} > "$OUT/targets.log" 2>&1
    tr -d '\r' < "$OUT/targets.log" | grep PROBE
    echo "D3DMetal: fragment compile failures $(grep -c 'Failed to compile fragment function' "$OUT/targets.log"), no-op $(grep -c 'marking PSO' "$OUT/targets.log")"
    grep -i "error\|fail" "$OUT/targets.log" | grep -v "^PROBE\|appleneuralengine\|Bad argument" | cut -c1-300 | head -5
else
    "$ENGINE/bin/wine" "$OUT/vrsprobe.exe" 2>/dev/null | tr -d '\r' | grep PROBE
fi
"$ENGINE/bin/wineserver" -k 2>/dev/null
