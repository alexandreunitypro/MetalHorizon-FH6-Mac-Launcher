#!/bin/bash
# Read-only. Win32DispatchInit (fills d3d12.so's gWin32Dispatch) is exported but never called inside
# d3d12.so: show who is meant to call it (CrossOver's ntdll D3DMetal hook) and what the tsshim does.
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
ENGINE="$WORK/crossover-source/out-x64/engine"
L="$SRC/dlls/ntdll/unix/loader.c"
echo "== loader.c: D3DMetal hook"
grep -n "Win32Dispatch\|D3DM\|d3dshared\|non_native_support\|apple_gptk\|DispatchInit\|ThreadInit" "$L" "$SRC/dlls/ntdll/unix/unix_private.h" | cut -c1-220 | sed "s#$SRC/##" | head -40
n=$(grep -n "Win32DispatchInit\|DispatchInit" "$L" | head -1 | cut -d: -f1)
[ -n "$n" ] && { echo "== loader.c around line $n"; sed -n "$((n-40)),$((n+25))p" "$L"; }
echo "== tsshim d3d12.dll strings"
strings -a "$ENGINE/renderers/d3dmetal-tsshim/wine/x86_64-windows/d3d12.dll" | grep -iE "apd12|d3d12|unix|dispatch|HB_|wine_" | sort -u | head -25
echo "== apd12.dll vs Apple d3d12.dll"
shasum -a 256 "$ENGINE/renderers/d3dmetal-tsshim/wine/x86_64-windows/apd12.dll" "$ENGINE/lib64/apple_gptk/wine/x86_64-windows/d3d12.dll" | cut -c1-16,65-
