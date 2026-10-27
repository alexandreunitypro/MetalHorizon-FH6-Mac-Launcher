#!/bin/bash
# Read-only. Which variable sits at 0x229f0 in GPTK's d3d12.so, which code fills it and the
# fn_NtUser* pointers, and how this Wine dlopen()s its unix libraries (RTLD_LOCAL hides them
# from dlsym(RTLD_DEFAULT)).
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
ENGINE="$WORK/crossover-source/out-x64/engine"
SRC="$WORK/crossover-source/sources/wine"
D="$ENGINE/lib64/apple_gptk/wine/x86_64-unix/d3d12.so"
echo "== symbols around 0x229f0"
nm -n -m "$D" | awk '{print}' | python3 -c '
import sys
rows=[l for l in sys.stdin if l[:16].strip() and all(c in "0123456789abcdef" for c in l[:16])]
for i,l in enumerate(rows):
    if int(l[:16],16) > 0x229f0:
        print("".join(rows[max(0,i-3):i+1]), end=""); break'
otool -tvV "$D" > /tmp/d3d12-disasm.txt
echo "== code writing fn_NtUserEnumDisplayMonitors / the 0x229f0 slot"
grep -n "fn_NtUserEnumDisplayMonitors\|0x229f0" /tmp/d3d12-disasm.txt | head -6
n=$(grep -n "movq	%rax, __ZL28fn_NtUserEnumDisplayMonitors" /tmp/d3d12-disasm.txt | head -1 | cut -d: -f1)
[ -n "$n" ] && sed -n "$((n-12)),$((n+1))p" /tmp/d3d12-disasm.txt
f=$(awk -v n="$n" 'NR<n && /^[_A-Za-z].*:$/ {f=$0} NR==n {print f}' /tmp/d3d12-disasm.txt); echo "in function: $f"
echo "== who calls that function"
[ -n "$f" ] && grep -n "${f%:}" /tmp/d3d12-disasm.txt | grep call | head -5
rm -f /tmp/d3d12-disasm.txt
echo "== dlopen flags in this Wine's unix loader"
grep -n "dlopen(" "$SRC"/dlls/ntdll/unix/loader.c | head -12
