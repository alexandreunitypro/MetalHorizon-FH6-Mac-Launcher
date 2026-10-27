#!/usr/bin/env python3
"""Diagnostic only: in the unix segv_handler (dlls/ntdll/unix/signal_x86_64.c), when the fault is a
jump to a NULL/low address, name with dladdr() the host libraries found in the first stack slots
(the caller's return address is slot 0)."""
import re, sys
path = sys.argv[1]
src = open(path).read()
if "FH6 null call" in src:
    print("already applied"); sys.exit(0)
m = re.search(r'static void segv_handler\( int signal, siginfo_t \*siginfo, void \*sigcontext \)\n\{\n(?:[^\n]*\n)*?[ \t]*ucontext_t \*ucontext = init_handler\( sigcontext \);\n', src)
if not m:
    print("STOP: segv_handler start not found"); sys.exit(1)
code = r'''
    /* FH6 diagnostic: a jump to a NULL/low address; name the host library that made the call */
    if ((ULONG_PTR)RIP_sig(ucontext) < 0x10000)
    {
        void **sp = (void **)RSP_sig(ucontext);
        int i;
        for (i = 0; i < 12; i++)
        {
            Dl_info info;
            if (!sp[i] || !dladdr( sp[i], &info ) || !info.dli_fname) continue;
            ERR( "FH6 null call: stack[%d]=%p %s+%#lx %s\n", i, sp[i], info.dli_fname,
                 (unsigned long)((char *)sp[i] - (char *)info.dli_fbase),
                 info.dli_sname ? info.dli_sname : "" );
        }
    }
'''
src = src[:m.end()] + code + src[m.end():]
if "#include <dlfcn.h>" not in src:
    src = src.replace("#include <stdlib.h>\n", "#include <stdlib.h>\n#include <dlfcn.h>\n", 1)
open(path, "w").write(src)
print("signal_x86_64.c updated")
