#!/usr/bin/env python3
"""replace_output: builds diagnostic replacements for game shaders that HB_TSSHIM_DUMP wrote.

For each shader file given, DXC's disassembly (tools/dxilbench ll) gets every store to the named output
signature element replaced by a constant, is assembled back (tools/dxilbench asm), keeps the original's
root signature (RTS0) and debug name (ILDN), and is written as <out_dir>/<original digest>.<vs|ps>, which the
shim (HB_TSSHIM_REPLACE=<out_dir name>) hands to D3DMetal in place of the original.
<element> is a signature name, or name#<register> (SV_Target#4 is render target 4).
<value> is a constant for every component; xyzw:<x>,<y>,<z>,<w> with keep for a component left as it is;
mask:<and>:<or> to store (original & and) | or for an integer output (mask:-16777216:16711935 keeps the top byte
and makes the low three bytes magenta); or drop, which removes the output (the last one only) and its stores.
Usage: replace_output.py <dxilbench> <out_dir> <element name> <value> <shader file>...
       replace_output.py --digest <container>       (checks the digest code against the stored digest)"""
import os
import re
import struct
import subprocess
import sys
import tempfile


def md5_transform(buf, block):
    import math
    K = [int(abs(math.sin(i + 1)) * 2**32) & 0xffffffff for i in range(64)]
    R = [7, 12, 17, 22] * 4 + [5, 9, 14, 20] * 4 + [4, 11, 16, 23] * 4 + [6, 10, 15, 21] * 4
    x = struct.unpack('<16I', block)
    a, b, c, d = buf
    for i in range(64):
        if i < 16: f, g = (b & c) | (~b & d), i
        elif i < 32: f, g = (d & b) | (~d & c), (5 * i + 1) % 16
        elif i < 48: f, g = b ^ c ^ d, (3 * i + 5) % 16
        else: f, g = c ^ (b | (~d & 0xffffffff)), (7 * i) % 16
        f = (f + a + K[i] + x[g]) & 0xffffffff
        a, d, c = d, c, b
        b = (b + ((f << R[i]) | (f >> (32 - R[i])))) & 0xffffffff
    return [(buf[0] + a) & 0xffffffff, (buf[1] + b) & 0xffffffff, (buf[2] + c) & 0xffffffff, (buf[3] + d) & 0xffffffff]


def dxbc_digest(c):
    """MD5 with the DXBC padding over c[20:] (vkd3d-shader's checksum.c, VKD3D_MD5_DXBC)."""
    p = c[20:]
    buf = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
    full = len(p) & ~63
    for i in range(0, full, 64):
        buf = md5_transform(buf, p[i:i + 64])
    left = p[full:]
    bits = (len(p) * 8) & 0xffffffff
    if len(left) + 1 > 56:
        buf = md5_transform(buf, (left + b'\x80').ljust(64, b'\0'))
        block = bytearray(64)
    else:
        block = bytearray((b'\0' * 4 + left + b'\x80').ljust(64, b'\0'))
    block[0:4] = struct.pack('<I', bits)
    block[60:64] = struct.pack('<I', (bits >> 2) | 1)
    buf = md5_transform(buf, bytes(block))
    return struct.pack('<4I', *buf)


def parts(c):
    n = struct.unpack_from('<I', c, 28)[0]
    out = []
    for i in range(n):
        off = struct.unpack_from('<I', c, 32 + 4 * i)[0]
        size = struct.unpack_from('<I', c, off + 4)[0]
        out.append((c[off:off + 4], c[off + 8:off + 8 + size]))
    return out


def build(plist):
    head = 32 + 4 * len(plist)
    offs, body = [], b''
    for cc, data in plist:
        offs.append(head + len(body))
        body += cc + struct.pack('<I', len(data)) + data
    c = bytearray(b'DXBC' + b'\0' * 16 + struct.pack('<HHII', 1, 0, head + len(body), len(plist)))
    c += b''.join(struct.pack('<I', o) for o in offs) + body
    c[4:20] = dxbc_digest(bytes(c))
    return bytes(c)


def main():
    if sys.argv[1] == '--digest':
        c = open(sys.argv[2], 'rb').read()
        print('digest', 'matches' if dxbc_digest(c) == c[4:20] else 'DIFFERS')
        return
    bench, out_dir, element, value = sys.argv[1:5]
    os.makedirs(out_dir, exist_ok=True)
    name, _, reg = element.partition('#')
    for path in sys.argv[5:]:
        orig = open(path, 'rb').read()
        with tempfile.TemporaryDirectory() as t:
            ll, ll2, dx = os.path.join(t, 'a.ll'), os.path.join(t, 'b.ll'), os.path.join(t, 'b.dxil')
            subprocess.run([bench, 'll', path, ll], check=True, capture_output=True)
            text = open(ll).read()
            try:
                out_list, outs = output_elements(text)
            except ValueError as e:
                print(f'{os.path.basename(path)}: {e}')
                continue
            hit = [o for o in outs if o['name'] == name and (not reg or o['row'] == reg)]
            if len(hit) != 1:
                print(f'{os.path.basename(path)}: {len(hit)} outputs match {element}')
                continue
            el = hit[0]; sig = el['id']
            pat = re.compile(r'(call void @dx\.op\.storeOutput\.(i32|f32)\(i32 5, i32 ' + sig + r', i32 [^,]+, i8 ([0-9]+), (?:i32|float) )([^)]+)\)')
            n = [0]
            lines = []
            for line in text.split('\n'):
                m = pat.search(line)
                if m and value == 'drop':
                    n[0] += 1
                    continue
                if m and value.startswith('mask:') and m.group(2) == 'i32' and m.group(4).startswith('%'):
                    _, a, o = value.split(':')
                    n[0] += 1
                    ind = line[:len(line) - len(line.lstrip())]
                    lines.append(f'{ind}%ro.a{n[0]} = and i32 {m.group(4)}, {a}')
                    lines.append(f'{ind}%ro.o{n[0]} = or i32 %ro.a{n[0]}, {o}')
                    line = line[:m.start(4)] + f'%ro.o{n[0]}' + line[m.end(4):]
                elif m and not value.startswith('mask:'):
                    if value.startswith('xyzw:'):
                        v = value[5:].split(',')[int(m.group(3))]
                    else:
                        v = value
                    if v != 'keep':
                        n[0] += 1
                        if m.group(2) == 'f32':
                            v = f'{float(v):e}'
                        line = line[:m.start(4)] + v + line[m.end(4):]
                lines.append(line)
            text = '\n'.join(lines)
            if value == 'drop':
                # only the last output can go: DXIL wants the element ids to stay 0..n-1
                if int(sig) != max(int(o['id']) for o in outs):
                    print(f'{os.path.basename(path)}: {element} is not the last output, not dropped')
                    continue
                kept = ', '.join(o['node'] for o in outs if o is not el)
                text = re.sub(r'^(' + re.escape(out_list) + r' = !\{)[^}]*(\})', lambda m: m.group(1) + kept + m.group(2), text, flags=re.M)
                text = re.sub(r'^!dx\.viewIdState = .*$', '', text, flags=re.M)   # its output counts would be stale
            open(ll2, 'w').write(text)
            r = subprocess.run([bench, 'asm', ll2, dx], capture_output=True, text=True)
            if r.returncode:
                print(f'{os.path.basename(path)}: assembly failed: {r.stdout[-300:]}')
                continue
            new = open(dx, 'rb').read()
        keep = {cc: d for cc, d in parts(orig) if cc in (b'RTS0', b'ILDN')}
        plist = [(cc, d) for cc, d in parts(new) if cc not in keep] + list(keep.items())
        dst = os.path.join(out_dir, os.path.basename(path))
        open(dst, 'wb').write(build(plist))
        print(f'{os.path.basename(path)}: {n[0]} store(s) of {element} -> {value}')


def output_elements(text):
    """The entry point's output signature: (its list node, [{node, id, name, row}]), from !dx.entryPoints."""
    md = dict(re.findall(r'^(![0-9]+) = (.*)$', text, flags=re.M))
    m = re.search(r'^!dx\.entryPoints = !\{(![0-9]+)', text, flags=re.M)
    if not m:
        raise ValueError('no entry point')
    entry = re.findall(r'(![0-9]+|null)', md[m.group(1)])
    sigs = entry[0] if entry else 'null'                    # !{fn, !"name", !signatures, ...}: first node operand
    if sigs == 'null':
        raise ValueError('no signatures')
    lists = re.findall(r'(![0-9]+|null)', md[sigs])
    if len(lists) < 2 or lists[1] == 'null':
        raise ValueError('no outputs')
    outs = []
    for node in re.findall(r'![0-9]+', md[lists[1]]):
        e = re.match(r'!\{i32 ([0-9]+), !"([^"]+)", i8 -?[0-9]+, i8 -?[0-9]+, (?:![0-9]+|null), i8 -?[0-9]+, i32 -?[0-9]+, i8 -?[0-9]+, i32 (-?[0-9]+)', md[node])
        if e:
            outs.append({'node': node, 'id': e.group(1), 'name': e.group(2), 'row': e.group(3)})
    return lists[1], outs


if __name__ == '__main__':
    main()
