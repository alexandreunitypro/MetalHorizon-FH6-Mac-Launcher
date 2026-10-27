#!/usr/bin/env python3
"""The local FHTRACE block in dlls/ntdll/exception.c (call_vectored_handlers) dumps 24 stack slots
after each trap. On a thread whose rsp is near the stack top this reads past Tib.StackBase and raises
an access violation inside the exception dispatcher. Keep the trace, but only when +seh is on and
only inside the stack. Backup: exception.c.pre-fh6-trace.bak (made by the shell script)."""
import re, sys
path = sys.argv[1]
src = open(path).read()
if "fh6: bounded stack dump v2" in src:
    print("already applied"); sys.exit(0)
V1 = """        if (TRACE_ON(seh) &&
            rec->ExceptionAddress >= (void *)0x145390000 &&
            rec->ExceptionAddress < (void *)0x1453c0000 &&
            generated_trace_count++ < 2000)"""
V2 = """        if (TRACE_ON(seh) &&
            ((rec->ExceptionAddress >= (void *)0x145390000 &&
              rec->ExceptionAddress < (void *)0x1453c0000) ||
             (ULONG_PTR)rec->ExceptionAddress < 0x10000) &&
            generated_trace_count++ < 2000)"""
if "fh6: bounded stack dump" in src:
    src = src.replace(V1, V2).replace("fh6: bounded stack dump,", "fh6: bounded stack dump v2,")
    src = src.replace("            memcpy( generated_code, (void *)context->Rip, sizeof(generated_code) );",
                      "            memset( generated_code, 0, sizeof(generated_code) );\n"
                      "            if (context->Rip >= 0x10000)\n"
                      "                memcpy( generated_code, (void *)context->Rip, sizeof(generated_code) );")
    open(path, "w").write(src); print("exception.c updated (v2)"); sys.exit(0)
m = re.search(r"\n        if \(rec->ExceptionAddress >= \(void \*\)0x145390000 &&.*?\n            TRACE\( \"\\n\" \);\n        \}\n", src, re.S)
if not m:
    print("FHTRACE block not found; nothing changed"); sys.exit(1)
new = r'''
        /* fh6: bounded stack dump v2, only with +seh, never past the stack top */
        if (TRACE_ON(seh) &&
            ((rec->ExceptionAddress >= (void *)0x145390000 &&
              rec->ExceptionAddress < (void *)0x1453c0000) ||
             (ULONG_PTR)rec->ExceptionAddress < 0x10000) &&
            generated_trace_count++ < 2000)
        {
            void **sp = (void **)context->Rsp;
            void **top = (void **)NtCurrentTeb()->Tib.StackBase;

            memset( generated_code, 0, sizeof(generated_code) );
            if (context->Rip >= 0x10000)
                memcpy( generated_code, (void *)context->Rip, sizeof(generated_code) );
            TRACE( "generated code for fault %p at %p:", (void *)rec->ExceptionAddress,
                   (void *)context->Rip );
            for (i = 0; i < sizeof(generated_code); i++) TRACE( " %02x", generated_code[i] );
            TRACE( " stack:" );
            for (j = 0; j < 24 && sp + j < top; j++) TRACE( " %p", sp[j] );
            TRACE( "\n" );
        }
'''
src = src[:m.start()] + new + src[m.end():]
open(path, "w").write(src)
print("exception.c updated")
