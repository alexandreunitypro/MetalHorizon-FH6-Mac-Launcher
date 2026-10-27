#!/bin/bash
# What the D3D12 device reports to a game through CheckFeatureSupport (shader model, feature level,
# tiers), with the game's Wine and CrossOver.app's D3DMetal. No game, changes nothing.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"; CXEXT="$CX/lib64/apple_gptk/external"
export CX_ROOT="$ENGINE" WINEPREFIX="$HOME/FH6/.blackwell-wine" WINEDEBUG=-all CX_GRAPHICS_BACKEND=d3dmetal D3DM_MTL4=1
export D3DM_VENDOR_ID=32902 D3DM_DEVICE_ID=22177 D3DM_DEVICE_DESCRIPTION="Intel(R) Arc(TM) A750 Graphics"
export WINEDLLPATH_PREPEND="$CX/lib64/apple_gptk/wine" CX_APPLEGPTK_LIBD3DSHARED_PATH="$CXEXT/libd3dshared.dylib"
export DYLD_LIBRARY_PATH="$ENGINE/lib:$CX/lib64:$CXEXT" DYLD_FRAMEWORK_PATH="$CXEXT"
echo "macOS $(sw_vers -productVersion); D3DMetal: $(defaults read "$CXEXT/D3DMetal.framework/Resources/Info.plist" CFBundleShortVersionString 2>/dev/null || echo ?)"
"$ENGINE/bin/wineserver" -k 2>/dev/null
"$ENGINE/bin/wine" "$REPO/tools/d3d12probe/d3d12probe.exe" features 2>/dev/null | tr -d '\r' | grep PROBE
"$ENGINE/bin/wineserver" -k 2>/dev/null
