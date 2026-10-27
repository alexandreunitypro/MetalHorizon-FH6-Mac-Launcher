#!/bin/bash
# Runs tools/d3d12probe (no game) with the exact Wine/D3DMetal environment the game uses, one D3D12
# entry point per process, plain and Agility-SDK flavoured, and reports which call hits the NULL call.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
GPTK="/Users/alexandre/.codex/visualizations/2026/10/19/01a1562c-64fc-74c0-9f71-acf814cbaad7/Blackwell FH6 Final.app/Contents/Resources/GPTK4/external"
export CX_ROOT="$ENGINE" CX_GRAPHICS_BACKEND=d3dmetal CX_APPLEGPTK_LIBD3DSHARED_PATH="$GPTK/libd3dshared.dylib"
export WINEPREFIX="$ROOT/work/audit/gamefarm-audit/.blackwell-wine"
export D3DM_MTL4=1 D3DM_VENDOR_ID=32902 D3DM_DEVICE_ID=22177 D3DM_DEVICE_DESCRIPTION="Intel(R) Arc(TM) A750 Graphics" WINEMSYNC=1
if [ -z "${FH6_NO_TSSHIM:-}" ]; then
    export WINEDLLPATH_PREPEND="$ENGINE/renderers/d3dmetal-tsshim/wine"
    export HB_D3D12_REAL="Z:$ENGINE/renderers/d3dmetal-tsshim/wine/x86_64-windows/apd12.dll"
fi
export WINEDEBUG="+timestamp,+loaddll,err+all"
export DYLD_LIBRARY_PATH="$ENGINE/lib:/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64:$GPTK"
export DYLD_FRAMEWORK_PATH="$GPTK"
W="$ENGINE/bin/wine"; mkdir -p "$REPO/out"
for exe in d3d12probe.exe d3d12probe-agility.exe; do
  for mode in factory create getinterface; do
    "$ENGINE/bin/wineserver" -k 2>/dev/null
    LOG="$REPO/out/probe-$mode-${exe%.exe}.log"
    "$W" "$REPO/tools/d3d12probe/$exe" "$mode" > "$LOG" 2>&1 &
    P=$!; for i in $(seq 40); do kill -0 $P 2>/dev/null || break; sleep 1; done; kill -9 $P 2>/dev/null
    echo "== $exe $mode (${i}s)"
    grep -E "^PROBE|Unhandled|FH6 null call" "$LOG" | sed -E 's#/Users/[^ ]*/##' | cut -c1-150 | head -8
    grep -i "Loaded.*\(d3d12\|apd12\|dxgi\)" "$LOG" | sed 's/.*Loaded L"//; s/" at .*//; s#.*\\\\##' | tr '\n' ' '; echo
  done
done
"$ENGINE/bin/wineserver" -k 2>/dev/null
