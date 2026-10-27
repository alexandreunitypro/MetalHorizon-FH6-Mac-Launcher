#!/bin/bash
# Read-only. WineMonitor::Init() in GPTK's d3d12.so calls through the pointer stored at 0x229f0
# (movq 0x175dc(%rip) at 0xb40d). Show what fills that slot: section, dyld binding, and
# GetMacDRVFunctions(); plus macdrv_functions in both winemac.so builds.
ENGINE="${ENGINE:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine}"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
D="$ENGINE/lib64/apple_gptk/wine/x86_64-unix/d3d12.so"
echo "== section holding 0x229f0"
otool -l "$D" | python3 -c '
import sys
s=g=None; a=None
for l in sys.stdin:
    w=l.split()
    if not w: continue
    if w[0]=="sectname": s=w[1]
    elif w[0]=="segname": g=w[1]
    elif w[0]=="addr": a=int(w[1],16)
    elif w[0]=="size" and a is not None:
        z=int(w[1],16)
        if a<=0x229f0<a+z: print(g,s,hex(a),hex(z))
'
echo "== binding of 0x229f0"
(dyld_info -fixups "$D" 2>/dev/null || xcrun dyldinfo -bind -lazy_bind -weak_bind "$D" 2>/dev/null) | grep -i "229f0" | head -3
echo "== imports (weak = may be NULL)"
nm -m "$D" | grep -E "NtUser|macdrv|ntdll_" | head -20
echo "== GetMacDRVFunctions"
otool -tvV -p __Z18GetMacDRVFunctionsv "$D" | sed -n '3,45p' | grep -vE "nop" | head -40
echo "== references to 0x229f0"
otool -tvV "$D" | grep -B2 -A1 "0x229f0\|## 0x229f0" | head -20
for w in "$ENGINE/lib/wine/x86_64-unix/winemac.so" "$CX/lib/wine/x86_64-unix/winemac.so"; do
    echo "== $w"; ls -la "$w" 2>/dev/null | awk '{print $5}'
    nm -m "$w" 2>/dev/null | grep -E "_macdrv_functions$"
done
