#!/usr/bin/env python3
"""Read-only. From `otool -tvV d3d12.so` on stdin: the control flow (calls, tests, jumps, globals) of
the functions that decide how gWin32Dispatch is filled before WineOS::Init runs."""
import re, sys
lines = sys.stdin.read().splitlines()
WANT = ["__Z18D3DRMDispatch_InitPv", "____Z18D3DRMDispatch_InitPv_block_invoke",
        "__ZZZ18D3DRMDispatch_InitPvEUb_ENK3$_0clES_", "__ZL15InitSharedStatev",
        "____ZL15InitSharedStatev_block_invoke", "__Z14D3DMThreadInitPv", "__Z10getEnvBoolPKcb"]
keep = re.compile(r'call|test|cmp|\tj[a-z]+\t|\(%rip\)|ret')
for name in WANT:
    for i, l in enumerate(lines):
        if l == name + ":":
            print("== " + name)
            for m in lines[i + 1:i + 400]:
                if re.match(r'^[_A-Za-z$"].*:$', m): break
                if keep.search(m):
                    addr, _, ins = m.partition("\t")
                    print("  %s %s" % (addr[-5:], re.sub(r'\s+', ' ', ins)[:140]))
            break
    else:
        print("== %s (not found)" % name)
