#!/usr/bin/env python3
"""PE helpers ported from Highball (GPL-3.0): Scripts/mark-builtin.py and PEExportName.swift.
  pe_tools.py mark-builtin  <dll>...         stamp Wine's builtin marker at offset 0x40
  pe_tools.py rename-export <dll> <newname>  change the PE export-directory name in place
A Wine builtin PE in a WINEDLLPATH dir needs the marker; a copy of a builtin DLL kept under another
file name needs its internal export name changed too, or Wine hands back the first copy."""
import sys, struct

def u16(b, o): return b[o] | b[o+1] << 8
def u32(b, o): return b[o] | b[o+1] << 8 | b[o+2] << 16 | b[o+3] << 24

def export_name_offset(b):
    if len(b) <= 0x40 or b[0] != 0x4D or b[1] != 0x5A: return None
    pe = u32(b, 0x3c)
    if pe + 4 > len(b) or b[pe:pe+4] != b'PE\0\0': return None
    sections = u16(b, pe + 6); opt_size = u16(b, pe + 20); opt = pe + 24
    if opt_size < 96 or opt + opt_size > len(b): return None
    magic = u16(b, opt)
    dd = opt + (112 if magic == 0x20b else 96)
    if dd + 8 > len(b): return None
    export_rva = u32(b, dd); export_size = u32(b, dd + 4)
    if export_rva == 0 or export_size == 0: return None
    secs = []
    for i in range(sections):
        s = opt + opt_size + 40 * i
        if s + 40 > len(b): return None
        secs.append((u32(b, s+12), max(u32(b, s+8), u32(b, s+16)), u32(b, s+20)))
    def off(rva):
        for va, size, raw in secs:
            if va <= rva < va + max(size, 1): return rva - va + raw
        return None
    d = off(export_rva)
    if d is None or d + 40 > len(b): return None
    n = off(u32(b, d + 12))
    if n is None or n >= len(b): return None
    return n

def mark_builtin(path):
    b = bytearray(open(path, 'rb').read())
    assert b[:2] == b'MZ', path
    e = u32(b, 0x3c)
    assert e >= 0x40 + 17, (path, e)
    b[0x40:0x40+17] = b'Wine builtin DLL\0'
    open(path, 'wb').write(b); print('  marked builtin:', path.split('/')[-1])

def rename_export(path, newname):
    b = bytearray(open(path, 'rb').read())
    o = export_name_offset(b)
    assert o is not None, ("no PE export directory in", path)
    end = o
    while end < len(b) and b[end] != 0: end += 1
    room = end - o
    nb = newname.encode()
    assert len(nb) <= room, ("new name too long (max %d): %s" % (room, newname))
    b[o:end] = nb + b'\0' * (room - len(nb))
    open(path, 'wb').write(b); print('  export name ->', newname, 'in', path.split('/')[-1])

if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'mark-builtin':
        for p in sys.argv[2:]: mark_builtin(p)
    elif cmd == 'rename-export':
        rename_export(sys.argv[2], sys.argv[3])
    else:
        print('usage: pe_tools.py mark-builtin <dll>... | rename-export <dll> <name>'); sys.exit(2)
