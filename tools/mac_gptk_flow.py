#!/usr/bin/env python3
"""Read-only. Reads `otool -tvV d3d12.so` on stdin and prints how gWin32Dispatch is supposed to be
filled before WineMonitor::Init uses it: Win32DispatchInit's block, PatchWin32DispatchFunctions'
caller, who calls WineOS::Init, every use of enableUnixCall, and the env switches read with getEnv*."""
import re, sys
lines = sys.stdin.read().splitlines()
label_at, cur = [], None
for i, l in enumerate(lines):
    if re.match(r'^[_A-Za-z$"].*:$', l): cur = l[:-1]
    label_at.append(cur)
def body(name, n=45):
    for i, l in enumerate(lines):
        if l == name + ":":
            out = []
            for m in lines[i + 1:i + 1 + n]:
                if re.match(r'^[_A-Za-z$"].*:$', m): break
                if "nop" not in m: out.append("   " + m.split("\t", 1)[-1][:150])
            return out
    return ["   (not found)"]
def short(s): return (s or "?")[:90]
print("== Win32DispatchInit block"); print("\n".join(body("____Z17Win32DispatchInitPv_block_invoke", 60)))
for want in ["call.*__Z27PatchWin32DispatchFunctions", "call.*__ZN6WineOS4InitEv", "call.*__Z17Win32DispatchInitPv",
             "call.*__Z14D3DMThreadInitPv", "enableUnixCall", "call.*ResolveWin32Symbols"]:
    hits = [(i, label_at[i]) for i, l in enumerate(lines) if re.search(want, l)]
    print("== %s : %d" % (want, len(hits)))
    for i, f in hits[:8]: print("   in %s : %s" % (short(f), lines[i].split("\t", 1)[-1][:110]))
print("== env switches (string before getEnvBool/getEnvInt)")
for i, l in enumerate(lines):
    if re.search(r'call.*(getEnvBool|getEnvInt)', l):
        s = next((re.search(r'literal pool for: "([^"]+)"', lines[j]).group(1) for j in range(i - 1, i - 8, -1)
                  if 'literal pool for: "' in lines[j]), "?")
        print("   %s in %s" % (s, short(label_at[i])))
f = next((label_at[i] for i, l in enumerate(lines) if re.search("call.*ResolveWin32Symbols", l)), None)
if f: print("== %s" % short(f)); print("\n".join(body(f, 70)))
