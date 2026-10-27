#!/bin/bash
# Read-only. WineMonitor::Init calls gWin32Dispatch+0x28 (0x229f0). Who is supposed to fill
# gWin32Dispatch (Win32DispatchInit), is it the same d3d12.so as CrossOver.app's, and which
# d3d12 PE side (Apple's or the tsshim) the game loaded.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
ENGINE="$WORK/crossover-source/out-x64/engine"
SRC="$WORK/crossover-source/sources/wine"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
D="$ENGINE/lib64/apple_gptk/wine/x86_64-unix/d3d12.so"
T="$REPO/out/d3d12-disasm.txt"
otool -tvV "$D" > "$T"
echo "== exports of d3d12.so"; nm -gU "$D" | awk '{print $3}' | head -30
echo "== callers of Win32DispatchInit"; grep -n "call.*Win32DispatchInit" "$T" | head
for c in $(grep -n "call.*Win32DispatchInit" "$T" | cut -d: -f1 | head -3); do
    awk -v n="$c" 'NR<n && /^[_A-Za-z].*:$/ {f=$0} NR==n {print "  in " f}' "$T"; done
echo "== Win32DispatchInit"; otool -tvV -p __Z17Win32DispatchInitPv "$D" | sed -n '3,40p' | grep -v nop
echo "== same file as CrossOver.app?"
shasum -a 256 "$D" "$CX/lib64/apple_gptk/wine/x86_64-unix/d3d12.so" 2>&1 | cut -c1-16,65-
echo "== PE d3d12 files"
ls -la "$ENGINE/lib64/apple_gptk/wine/x86_64-windows/" "$ENGINE/renderers/d3dmetal-tsshim/wine/x86_64-windows/" 2>&1 | grep -iv "^total" | head -20
echo "== which d3d12 the game loaded"
grep -i "Loaded.*\(d3d12\|apd12\|dxgi\)" "$REPO/out/fh6-after.log" | cut -d: -f3- | cut -c1-170 | head -8
echo "== Wine source mentions"
grep -rln "Win32DispatchInit\|D3DM_WINE_UNIX_CALL\|D3DMetalWineThread\|libd3dshared" "$SRC/dlls" 2>/dev/null | head
rm -f "$T"
