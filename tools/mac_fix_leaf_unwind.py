#!/usr/bin/env python3
"""ntdll virtual_unwind (x86_64): for a frame outside any module (code generated at run time) Wine asks
the host unwinder; on macOS it returns an invented frame with a personality routine, Wine prints
"calling personality routine in system library not supported yet" and keeps the bogus context, so the
dispatcher later jumps to garbage. Windows unwinds such a frame as a leaf function: rip = [rsp],
rsp += 8. Do that in exactly that branch."""
import re, sys
path = sys.argv[1]
src = open(path).read()
if "fh6: leaf unwind" in src:
    print("already applied"); sys.exit(0)
fix = re.search(r'\n(?P<i>[ \t]*)if \((?P<cond>[^\n]*dispatch->LanguageHandler[^\n]*!module[^\n]*)\)\n(?P=i)\{\n'
                r'[ \t]*FIXME\( "calling personality routine in system library not supported yet\\n" \);\n'
                r'[ \t]*dispatch->LanguageHandler = NULL;\n(?P=i)\}\n', src)
if not fix:
    print("STOP: branch not found in", path); sys.exit(1)
# the host-unwinder call just before it: save the context first
call = None
for c in re.finditer(r'\n([ \t]*)(status = [^\n]*unwind_builtin_dll[^\n]*)(?=\n)', src[:fix.start()+1]):
    call = c
if not call or fix.start() - call.end() > 400:
    print("STOP: host unwinder call not found before the branch"); sys.exit(1)
i = fix.group("i")
new_branch = f'''
{i}if ({fix.group("cond")})
{i}{{
{i}    /* fh6: leaf unwind. No module owns this code, so the host unwinder knows nothing real about
{i}       it; unwind it as a leaf function like Windows does. */
{i}    WARN( "no module for rip %p, unwinding as leaf function\\n", (void *)fh6_saved.Rip );
{i}    *context = fh6_saved;
{i}    dispatch->EstablisherFrame = context->Rsp;
{i}    context->Rip = *(ULONG64 *)context->Rsp;
{i}    context->Rsp += sizeof(ULONG64);
{i}    dispatch->LanguageHandler = NULL;
{i}}}
'''
ci = call.group(1)
new_call = f'\n{ci}fh6_saved = *context;\n{ci}{call.group(2)}'
src = src[:call.start()] + new_call + src[call.end():fix.start()] + new_branch + src[fix.end():]
# declare the saved copy at the top of virtual_unwind
d = re.search(r'(?m)^(static [^\n]*virtual_unwind\([^)]*\)\n\{\n)', src)
if not d:
    print("STOP: virtual_unwind start not found"); sys.exit(1)
src = src[:d.end()] + "    CONTEXT fh6_saved;\n" + src[d.end():]
open(path, "w").write(src)
print("updated", path)
