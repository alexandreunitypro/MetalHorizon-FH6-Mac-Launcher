#!/usr/bin/env python3
"""Adds a fault report to the unix segv_handler (dlls/ntdll/unix/signal_x86_64.c), on channel fh6fault (ERR level).

Forza Horizon 6 catches its own faults and then stops itself with a second, deliberate one, so Wine's "Unhandled page
fault" box never shows the cause. A first-chance trace in the PE ntdll (dispatch_exception) made the game's copy
protection stop the game at start-up within three minutes, three times out of three, and run normally once removed
(2026-10-25): the PE side's exception path must stay as it is. This report sits on the unix side instead, where the
earlier "FH6 null call" diagnostic never bothered the game, and runs only for a real access violation that is about to
be raised to the Windows side (after virtual_handle_fault and handle_syscall_fault let it through): the copy
protection's illegal-instruction traps never reach it. It prints the faulting address, the registers, the code bytes
around the instruction and 32 stack slots, all read with vm_read_overwrite, which reports an unreadable address instead
of faulting inside the signal handler. At most 60 reports a run. Backup: signal_x86_64.c.pre-fh6-faulttrace.bak.

Second part (2026-10-25): the game stops itself on an HRESULT (0x800705AA twice, ERROR_NO_SYSTEM_RESOURCES) through a fatal
handler that takes the code and a message, and its executable is encrypted on disk, so neither the message nor the call
that returned the code can be read afterwards. The report now also prints what each register points to (64 bytes, with
a text view), and for each stack slot that points into the game's image (0x140000000-0x150000000) the 48 bytes of code
before it, with the target of each call found there: E8 rel32 directly, FF 15 rel32 through the pointer it reads."""
import sys

path = sys.argv[1]
src = open(path).read()
V2 = r'''    /* fh6: fault report v2: what the registers point to, and the calls before the return addresses into the game */
    {
        static const char *const reg_names[11] = { "rbx", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r12", "r13", "r14", "r15" };
        ULONG_PTR regs[11] = { (ULONG_PTR)RBX_sig(ucontext), (ULONG_PTR)RCX_sig(ucontext), (ULONG_PTR)RDX_sig(ucontext),
                               (ULONG_PTR)RSI_sig(ucontext), (ULONG_PTR)RDI_sig(ucontext), (ULONG_PTR)R8_sig(ucontext),
                               (ULONG_PTR)R9_sig(ucontext), (ULONG_PTR)R12_sig(ucontext), (ULONG_PTR)R13_sig(ucontext),
                               (ULONG_PTR)R14_sig(ucontext), (ULONG_PTR)R15_sig(ucontext) };
        unsigned char text[64], before[48];
        unsigned int k;
        if (!fh6_read( (ULONG_PTR)RSP_sig(ucontext), stack, sizeof(stack) )) memset( stack, 0, sizeof(stack) );
        for (i = 0; i < 11; i++)
        {
            if (regs[i] < 0x10000 || !fh6_read( regs[i], text, sizeof(text) )) continue;
            pos = 0;
            FH6_ADD( "%s -> %p:", reg_names[i], (void *)regs[i] );
            for (k = 0; k < sizeof(text); k++) FH6_ADD( " %02x", text[k] );
            FH6_ADD( "  \"" );
            for (k = 0; k < sizeof(text); k++) FH6_ADD( "%c", text[k] >= 32 && text[k] < 127 && text[k] != '"' ? text[k] : text[k] ? '?' : '.' );
            FH6_ADD( "\"" );
            ERR_(fh6fault)( "%s\n", line );
        }
        for (i = 0; i < 32; i++)
        {
            ULONG_PTR ret = stack[i];
            if (ret < 0x140000000 || ret >= 0x150000000 || !fh6_read( ret - sizeof(before), before, sizeof(before) )) continue;
            pos = 0;
            FH6_ADD( "slot %u before %p:", i, (void *)ret );
            for (k = 0; k < sizeof(before); k++) FH6_ADD( " %02x", before[k] );
            for (k = 0; k + 5 <= sizeof(before); k++)
            {
                ULONG_PTR next, target, ptr;
                INT32 rel;
                if (before[k] == 0xe8)
                {
                    memcpy( &rel, before + k + 1, 4 ); next = ret - sizeof(before) + k + 5;
                    if (next == ret) FH6_ADD( " | call %p", (void *)(next + rel) );
                }
                else if (k + 6 <= sizeof(before) && before[k] == 0xff && before[k + 1] == 0x15)
                {
                    memcpy( &rel, before + k + 2, 4 ); next = ret - sizeof(before) + k + 6; target = next + rel;
                    if (next == ret && fh6_read( target, &ptr, sizeof(ptr) )) FH6_ADD( " | call [%p] = %p", (void *)target, (void *)ptr );
                }
            }
            ERR_(fh6fault)( "%s\n", line );
        }
    }
'''
if "fh6: fault report v2" in src:
    print("already applied")
    sys.exit(0)
if "fh6: fault report" in src:
    end = "#undef FH6_ADD\n}\n"
    if src.count(end) != 1:
        print("fault report found but its end is not; nothing changed")
        sys.exit(1)
    src = src.replace(end, V2 + end, 1)
    open(path, "w").write(src)
    print("signal_x86_64.c: fault report v2 added")
    sys.exit(0)

anchor = """    if (handle_syscall_fault( ucontext, &rec, &context.c )) return;
    setup_raise_exception( ucontext, &rec, &context );
}


/**********************************************************************
 *		trap_handler"""
if anchor not in src:
    print("segv_handler end not found; nothing changed")
    sys.exit(1)

helper = r'''/* fh6: fault report (channel fh6fault, ERR level), see tools/mac_trace_faults.py */
WINE_DECLARE_DEBUG_CHANNEL(fh6fault);

static BOOL fh6_read( ULONG_PTR addr, void *buf, size_t size )
{
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite( mach_task_self(), addr, size, (mach_vm_address_t)buf, &got ) == KERN_SUCCESS && got == size;
}

static void fh6_fault_report( ucontext_t *ucontext, const EXCEPTION_RECORD *rec )
{
    static LONG reports;
    unsigned char code[96];
    ULONG_PTR stack[32], rip = (ULONG_PTR)RIP_sig(ucontext);
    char line[1200];
    size_t pos = 0;
    unsigned int i;
    int len;

    if (!ERR_ON(fh6fault) || InterlockedIncrement( &reports ) > 60) return;
#define FH6_ADD(...) do { len = snprintf( line + pos, sizeof(line) - pos, __VA_ARGS__ ); \
        if (len > 0) pos = pos + len < sizeof(line) ? pos + len : sizeof(line) - 1; } while (0)
    ERR_(fh6fault)( "code %08x at %p, %s %p\n", (int)rec->ExceptionCode, (void *)rip,
                    rec->ExceptionInformation[0] == 8 ? "executing" : rec->ExceptionInformation[0] == 1 ? "writing" : "reading",
                    (void *)rec->ExceptionInformation[1] );
    ERR_(fh6fault)( "regs rax %lx rbx %lx rcx %lx rdx %lx rsi %lx rdi %lx rbp %lx rsp %lx r8 %lx r9 %lx r10 %lx r11 %lx r12 %lx r13 %lx r14 %lx r15 %lx\n",
                    (unsigned long)RAX_sig(ucontext), (unsigned long)RBX_sig(ucontext), (unsigned long)RCX_sig(ucontext),
                    (unsigned long)RDX_sig(ucontext), (unsigned long)RSI_sig(ucontext), (unsigned long)RDI_sig(ucontext),
                    (unsigned long)RBP_sig(ucontext), (unsigned long)RSP_sig(ucontext), (unsigned long)R8_sig(ucontext),
                    (unsigned long)R9_sig(ucontext), (unsigned long)R10_sig(ucontext), (unsigned long)R11_sig(ucontext),
                    (unsigned long)R12_sig(ucontext), (unsigned long)R13_sig(ucontext), (unsigned long)R14_sig(ucontext),
                    (unsigned long)R15_sig(ucontext) );
    if (fh6_read( rip - 64, code, sizeof(code) ))
    {
        FH6_ADD( "code from %p:", (void *)(rip - 64) );
        for (i = 0; i < sizeof(code); i++) FH6_ADD( "%s%02x", i == 64 ? " >" : " ", code[i] );
        ERR_(fh6fault)( "%s\n", line );
    }
    else if (fh6_read( rip, code, 32 ))
    {
        FH6_ADD( "code from %p: >", (void *)rip );
        for (i = 0; i < 32; i++) FH6_ADD( " %02x", code[i] );
        ERR_(fh6fault)( "%s\n", line );
    }
    else ERR_(fh6fault)( "code at %p not readable\n", (void *)rip );
    pos = 0;
    if (fh6_read( (ULONG_PTR)RSP_sig(ucontext), stack, sizeof(stack) ))
    {
        FH6_ADD( "stack:" );
        for (i = 0; i < 32; i++) FH6_ADD( " %lx", (unsigned long)stack[i] );
        ERR_(fh6fault)( "%s\n", line );
    }
#undef FH6_ADD
}


'''

marker = """/**********************************************************************
 *		segv_handler
"""
if marker not in src:
    print("segv_handler header not found; nothing changed")
    sys.exit(1)
src = src.replace(marker, helper.replace("#undef FH6_ADD\n}\n", V2 + "#undef FH6_ADD\n}\n", 1) + marker, 1)
src = src.replace(anchor, anchor.replace(
    "    if (handle_syscall_fault( ucontext, &rec, &context.c )) return;\n",
    "    if (handle_syscall_fault( ucontext, &rec, &context.c )) return;\n"
    "    if (rec.ExceptionCode == EXCEPTION_ACCESS_VIOLATION) fh6_fault_report( ucontext, &rec );\n"), 1)
if "#include <mach/mach_vm.h>" not in src:
    src = src.replace("#include <stdlib.h>\n", "#include <stdlib.h>\n#ifdef __APPLE__\n#include <mach/mach.h>\n#include <mach/mach_vm.h>\n#endif\n", 1)
open(path, "w").write(src)
print("signal_x86_64.c updated")
