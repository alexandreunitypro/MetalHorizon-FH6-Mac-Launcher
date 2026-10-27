#!/usr/bin/env python3
"""From out/fh6-after.log (+seh +unwind +loaddll) on thread 0024: the first access violation, and the
unwind steps that produced the bogus handler address, with the module each unwound rip belongs to."""
import re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
mods = []
for l in lines:
    m = re.search(r'Loaded L"([^"]+)" at ([0-9A-Fa-f]+)', l)
    if m: mods.append((int(m.group(2), 16), m.group(1).split("\\")[-1]))
def where(a):
    if 0x140000000 <= a < 0x160000000: return "forzahorizon6.exe+0x%x" % (a - 0x140000000)
    b = max((m for m in mods if m[0] <= a), default=None)
    return "%s+0x%x" % (b[1], a - b[0]) if b and a - b[0] < 0x8000000 else "?"
first = next((i for i, l in enumerate(lines) if ":0024:" in l and "code=c0000005" in l), None)
if first is not None:
    print("first AV on 0024:"); [print(" ", l[:170]) for l in lines[first:first+4]]
bad = next((i for i, l in enumerate(lines) if "calling handler 0020019008070C10" in l), None)
if bad is None:
    print("bogus handler not found"); sys.exit(0)
print("unwind steps before the bogus handler (thread 0024):")
for l in [l for l in lines[max(0, bad-3000):bad+1] if ":0024:" in l][-400:]:
    m = re.search(r'RtlVirtualUnwind2 type \d base ([0-9a-f]+) rip ([0-9a-f]+) rva ([0-9a-f]+) rsp ([0-9a-f]+)', l)
    if m: print("  rip %s rsp %s  %s" % (m.group(2), m.group(4), where(int(m.group(2), 16)))); continue
    if "handler" in l or "leaf" in l or "nested" in l or "dispatch_exception code" in l:
        print("  " + l.split(":", 3)[-1][:150])
