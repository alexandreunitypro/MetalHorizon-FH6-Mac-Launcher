#!/bin/bash
# Read-only. Shows what WineMonitor::Init()/WineOS::Init() in GPTK's d3d12.so call, and for each
# name d3d12.so looks up at run time, which Wine unix library exports it: in the self-built engine
# and in CrossOver.app (the Wine GPTK's d3d12.so was made for).
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${ENGINE:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine}"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
D="$ENGINE/lib64/apple_gptk/wine/x86_64-unix/d3d12.so"
echo "== WineOS::Init"
otool -tvV -p __ZN6WineOS4InitEv "$D" | sed -n '2,40p' | grep -E "call|lea.*rip|mov.*rip|cmp|j[a-z]+ " | head -30
echo "== WineMonitor::Init"
otool -tvV -p __ZN11WineMonitor4InitEv "$D" | sed -n '2,30p' | head -24
echo "== who exports each name (self-built | CrossOver.app)"
for s in macdrv_functions ntdll_get_dos_file_name ntdll_get_unix_file_name NtUserChangeDisplaySettings \
         NtUserEnumDisplayMonitors NtUserEnumDisplaySettings NtUserMoveWindow NtUserSetWindowLongPtr \
         NtUserSetWindowPos NtUserShowWindow D3DMetalWineThread D3DM_WINE_UNIX_CALL; do
    a=""; b=""
    for f in "$ENGINE"/lib/wine/x86_64-unix/*.so; do nm -gU "$f" 2>/dev/null | grep -qE " _$s$" && a="$a $(basename "$f")"; done
    for f in "$CX"/lib/wine/x86_64-unix/*.so "$CX"/lib64/wine/x86_64-unix/*.so; do [ -f "$f" ] && nm -gU "$f" 2>/dev/null | grep -qE " _$s$" && b="$b $(basename "$f")"; done
    printf "%-30s self:%-20s cx:%s\n" "$s" "${a:- MISSING}" "${b:- MISSING}"
done
