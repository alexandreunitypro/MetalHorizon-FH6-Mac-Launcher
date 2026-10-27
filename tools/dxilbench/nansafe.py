#!/usr/bin/env python3
"""nansafe: rewrites DXC's disassembly of a DXIL shader so that saturate() gives D3D's answer for NaN.

D3D defines saturate(NaN) = 0. The Metal shader converter in D3DMetal 4.0b3 translates saturate to
air.fast_saturate and compiles with fast math, and on Apple GPUs it gives 1 for NaN (tools/dxilbench nantest
measures it). Each `call float @dx.op.unary.f32(i32 7, float %x) ; Saturate` becomes: the same saturate, then
a select that gives 0 when %x's bits are a NaN (an integer test, which fast math does not touch). The fast-math
flags are taken off every instruction so that nothing upstream is allowed to assume the NaN away.
Usage: nansafe.py in.ll out.ll   (prints how many saturates were guarded)"""
import re
import sys

SAT = re.compile(r'^(\s*)(%[0-9]+) = call float @dx\.op\.unary\.f32\(i32 7, float ([^)]+)\)(.*)$')


def rewrite(text):
    out, n = [], 0
    for line in text.split('\n'):
        if line.lstrip().startswith(';'):
            out.append(line)
            continue
        m = SAT.match(line)
        if m:
            ind, dst, arg, rest = m.groups()
            k = dst[1:]
            n += 1
            out.append(f'{ind}%nansafe.s{k} = call float @dx.op.unary.f32(i32 7, float {arg}){rest}')
            out.append(f'{ind}%nansafe.b{k} = bitcast float {arg} to i32')
            out.append(f'{ind}%nansafe.a{k} = and i32 %nansafe.b{k}, 2147483647')
            out.append(f'{ind}%nansafe.n{k} = icmp ugt i32 %nansafe.a{k}, 2139095040')
            out.append(f'{ind}{dst} = select i1 %nansafe.n{k}, float 0.000000e+00, float %nansafe.s{k}')
            continue
        # fast-math flags: "fadd fast", "fcmp fast olt", "call fast float", also nnan/ninf/nsz/arcp alone
        line = re.sub(r'\b(fadd|fsub|fmul|fdiv|frem|fcmp|call)((?: (?:fast|nnan|ninf|nsz|arcp|contract|afn|reassoc))+)\b', r'\1', line)
        out.append(line)
    return '\n'.join(out), n


if __name__ == '__main__':
    src = open(sys.argv[1]).read()
    # DXC's disassembly starts with a commented header; the IR itself is untouched apart from the rewrite
    text, n = rewrite(src)
    open(sys.argv[2], 'w').write(text)
    print(n)
