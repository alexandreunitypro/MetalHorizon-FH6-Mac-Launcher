#!/bin/bash
# What the game can read about the GPU and driver (display devices, DXGI, registry, WMI), with the
# same Wine, D3DMetal and spoofed GPU as the game. No game, changes nothing.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"; CXEXT="$CX/lib64/apple_gptk/external"
export CX_ROOT="$ENGINE" WINEPREFIX="$HOME/FH6/.blackwell-wine" WINEDEBUG=-all CX_GRAPHICS_BACKEND=d3dmetal D3DM_MTL4=1
export WINEDLLPATH_PREPEND="$CX/lib64/apple_gptk/wine" CX_APPLEGPTK_LIBD3DSHARED_PATH="$CXEXT/libd3dshared.dylib"
export DYLD_LIBRARY_PATH="$ENGINE/lib:$CX/lib64:$CXEXT" DYLD_FRAMEWORK_PATH="$CXEXT"
export D3DM_VENDOR_ID=32902 D3DM_DEVICE_ID=22177 D3DM_DEVICE_DESCRIPTION="Intel(R) Arc(TM) A750 Graphics"
"$ENGINE/bin/wineserver" -k 2>/dev/null
"$ENGINE/bin/wine" "$REPO/tools/gpuprobe/gpuprobe.exe" 2>/dev/null | tr -d '\r'
echo "== WMI Win32_VideoController"
"$ENGINE/bin/wine" wmic path Win32_VideoController get Name,DriverVersion,AdapterRAM,PNPDeviceID,VideoProcessor 2>/dev/null | tr -d '\r' | grep -v "^ *$"
"$ENGINE/bin/wineserver" -k 2>/dev/null
