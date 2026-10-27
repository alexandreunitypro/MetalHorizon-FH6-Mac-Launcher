#!/bin/bash
# d3d12probe "features" (no game) with two D3DMetal combinations on the self-built Wine:
#  A: CrossOver.app d3d12 halves + D3DMetal 3.0 (works, shader model 6.6)
#  B: CrossOver.app d3d12 halves + D3DMetal 4.0b3 from the GPTK4 folder
#  C: the engine's own d3d12 halves + D3DMetal 4.0b3 (known to crash in WineMonitor::Init)
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
G4="/Users/alexandre/.codex/visualizations/2026/10/19/01a1562c-64fc-74c0-9f71-acf814cbaad7/Blackwell FH6 Final.app/Contents/Resources/GPTK4/external"
export CX_ROOT="$ENGINE" WINEPREFIX="$HOME/FH6/.blackwell-wine" WINEDEBUG="err+all" CX_GRAPHICS_BACKEND=d3dmetal D3DM_MTL4=1
export D3DM_VENDOR_ID=32902 D3DM_DEVICE_ID=22177 D3DM_DEVICE_DESCRIPTION="Intel(R) Arc(TM) A750 Graphics"
run() {  # name halves external
    export WINEDLLPATH_PREPEND="$2" CX_APPLEGPTK_LIBD3DSHARED_PATH="$3/libd3dshared.dylib"
    export DYLD_LIBRARY_PATH="$ENGINE/lib:$CX/lib64:$3" DYLD_FRAMEWORK_PATH="$3"
    "$ENGINE/bin/wineserver" -k 2>/dev/null
    "$ENGINE/bin/wine" "$REPO/tools/d3d12probe/d3d12probe.exe" features > "$REPO/out/mix-$1.log" 2>&1 &
    P=$!; for i in $(seq 40); do kill -0 $P 2>/dev/null || break; sleep 1; done; kill -9 $P 2>/dev/null; wait $P 2>/dev/null
    echo "== $1 (${i}s)"
    tr -d '\r' < "$REPO/out/mix-$1.log" | grep -E "PROBE (D3D12CreateDevice|shader model asked 6\.(9|7|6)|feature levels)|FH6 null call: stack\[0\]|Unhandled" | sed -E 's#/Users/[^ ]*/##' | cut -c1-140
}
run A-cx-halves-d3dm3 "$CX/lib64/apple_gptk/wine" "$CX/lib64/apple_gptk/external"
run B-cx-halves-d3dm4 "$CX/lib64/apple_gptk/wine" "$G4"
run C-engine-halves-d3dm4 "$ENGINE/lib64/apple_gptk/wine" "$G4"
"$ENGINE/bin/wineserver" -k 2>/dev/null
