#!/bin/bash
# d3d12probe "create" (D3D12CreateDevice, no game) under several graphics setups, to find one where
# D3DMetal starts: 1 as the game runs, 2 without the tsshim, 3 CrossOver.app's GPTK files on the
# self-built Wine, 4 CrossOver.app's own Wine + GPTK (fresh prefix in out/cx-prefix).
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
GPTK="/Users/alexandre/.codex/visualizations/2026/10/19/01a1562c-64fc-74c0-9f71-acf814cbaad7/Blackwell FH6 Final.app/Contents/Resources/GPTK4/external"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
CXEXT=$(dirname "$(find "$CX" -maxdepth 5 -name libd3dshared.dylib 2>/dev/null | head -1)" 2>/dev/null)
CXGPTK=$(dirname "$(find "$CX" -maxdepth 6 -path "*apple_gptk/wine/x86_64-unix/d3d12.so" 2>/dev/null | head -1)" 2>/dev/null)
CXGPTK="${CXGPTK%/x86_64-unix}"
echo "CrossOver GPTK: ${CXGPTK:-none}  external: ${CXEXT:-none}"
base_env() {
    export CX_GRAPHICS_BACKEND=d3dmetal D3DM_MTL4=1 D3DM_VENDOR_ID=32902 D3DM_DEVICE_ID=22177 WINEMSYNC=1
    export D3DM_DEVICE_DESCRIPTION="Intel(R) Arc(TM) A750 Graphics" WINEDEBUG="+loaddll,err+all"
    unset WINEDLLPATH_PREPEND HB_D3D12_REAL
}
run() {  # name wine wineserver
    "$3" -k 2>/dev/null
    LOG="$REPO/out/matrix-$1.log"
    "$2" "$REPO/tools/d3d12probe/d3d12probe.exe" create > "$LOG" 2>&1 &
    P=$!; for i in $(seq "${4:-40}"); do kill -0 $P 2>/dev/null || break; sleep 1; done; kill -9 $P 2>/dev/null; wait $P 2>/dev/null
    echo "== $1 (${i}s)"
    grep -E "^PROBE D3D12CreateDevice|FH6 null call: stack\[0\]|Unhandled" "$LOG" | sed -E 's#/Users/[^ ]*/##' | cut -c1-140 | head -3
    grep -o 'Loaded L"[^"]*\(d3d12\|apd12\|dxgi\)[^"]*"' "$LOG" | sed 's#.*\\\\##; s/"//' | tr '\n' ' '; echo
    "$3" -k 2>/dev/null
}
# 1 and 2: self-built Wine
export CX_ROOT="$ENGINE" WINEPREFIX="$ROOT/work/audit/gamefarm-audit/.blackwell-wine"
export DYLD_LIBRARY_PATH="$ENGINE/lib:$CX/lib64:$GPTK" DYLD_FRAMEWORK_PATH="$GPTK" CX_APPLEGPTK_LIBD3DSHARED_PATH="$GPTK/libd3dshared.dylib"
base_env
export WINEDLLPATH_PREPEND="$ENGINE/renderers/d3dmetal-tsshim/wine" HB_D3D12_REAL="Z:$ENGINE/renderers/d3dmetal-tsshim/wine/x86_64-windows/apd12.dll"
run 1-as-game "$ENGINE/bin/wine" "$ENGINE/bin/wineserver"
base_env
run 2-no-tsshim "$ENGINE/bin/wine" "$ENGINE/bin/wineserver"
# 3: CrossOver.app's GPTK on the self-built Wine
if [ -n "$CXGPTK" ] && [ -n "$CXEXT" ]; then
    base_env
    export WINEDLLPATH_PREPEND="$CXGPTK" CX_APPLEGPTK_LIBD3DSHARED_PATH="$CXEXT/libd3dshared.dylib"
    export DYLD_LIBRARY_PATH="$ENGINE/lib:$CX/lib64:$CXEXT" DYLD_FRAMEWORK_PATH="$CXEXT"
    run 3-cx-gptk "$ENGINE/bin/wine" "$ENGINE/bin/wineserver"
else echo "== 3-cx-gptk skipped (CrossOver GPTK not found)"; fi
# 4: CrossOver.app's own Wine
L=""; for c in "$CX/bin/wineloader" "$CX/bin/wine64" "$CX/lib/wine/x86_64-unix/wine"; do [ -x "$c" ] && file "$c" | grep -q Mach-O && L="$c" && break; done
if [ -n "$L" ] && [ -n "$CXEXT" ]; then
    base_env
    export CX_ROOT="$CX" WINEPREFIX="$REPO/out/cx-prefix" WINEDLLOVERRIDES="mscoree,mshtml="
    export CX_APPLEGPTK_LIBD3DSHARED_PATH="$CXEXT/libd3dshared.dylib" DYLD_LIBRARY_PATH="$CX/lib64:$CX/lib:$CXEXT" DYLD_FRAMEWORK_PATH="$CXEXT"
    echo "(CrossOver loader: ${L#$CX/}; first run creates out/cx-prefix, up to 2 min)"
    run 4-crossover "$L" "$CX/bin/wineserver" 150
else echo "== 4-crossover skipped (no CrossOver Wine loader found)"; ls "$CX/bin" | tr '\n' ' '; echo; fi
