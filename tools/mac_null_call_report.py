#!/usr/bin/env python3
"""From out/fh6-after.log (+seh +loaddll): the first call through a NULL pointer, its return
address, and which loaded module that address belongs to."""
import re, sys
log = sys.argv[1]
mods, hit = [], None
for line in open(log, errors="replace"):
    m = re.search(r'Loaded L"([^"]+)" at ([0-9A-Fa-f]+)', line)
    if m: mods.append((int(m.group(2), 16), m.group(1)))
    if hit is None and "generated code for fault 0000000000000000" in line:
        hit = line
if not hit:
    print("no NULL call traced"); sys.exit(0)
print(hit[:120])
st = hit.split("stack:")[1].split()
ret = int(st[0], 16) if st else 0
print("return address:", hex(ret), "| stack:", " ".join(st[:6]))
best = max((b for b in mods if b[0] <= ret), default=None)
main = 0x140000000
if best and ret - best[0] < 0x10000000:
    print("module: %s +0x%x" % (best[1], ret - best[0]))
elif main <= ret < main + 0x20000000:
    print("module: forzahorizon6.exe +0x%x" % (ret - main))
else:
    print("module: none known")
