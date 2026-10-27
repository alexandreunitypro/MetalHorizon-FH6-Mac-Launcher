#!/usr/bin/env python3
"""Adds a first-chance exception trace to dlls/ntdll/exception.c (dispatch_exception).

Forza Horizon 6 catches its own faults: its handler writes CrashReport.xml and then stops the game with a second,
deliberate fault (a write to address 0, or a read in its crash reporter), and only that second fault reaches Wine's
"Unhandled page fault" box. The first one, the cause, leaves no trace. This logs every first-chance exception on the
channel fh6exc at ERR level (so WINEDEBUG=err+all shows it, and -all or err-fh6exc hides it): thread, code, where
(module+offset), the two first parameters, and a 16-frame unwind of the faulting context. Left out: the copy
protection's traps (illegal/privileged instruction, breakpoint, single step) and Wine's thread-naming and debug-print
exceptions. An access violation also gets the registers, the 16 stack slots at rsp and the code bytes around the
instruction as they are in memory then (the copy protection keeps the code encrypted on disk). At most 3 reports per
(code, first 4 frames) and 3000 in all, so a hot path cannot flood the log.
Backup: exception.c.pre-fh6-exctrace.bak (made by tools/mac_trace_exceptions.sh)."""
import sys

path = sys.argv[1]
src = open(path).read()
if "fh6: first-chance exception trace" in src:
    print("already applied")
    sys.exit(0)

anchor = """/*******************************************************************
 *		dispatch_exception
 */
NTSTATUS WINAPI dispatch_exception( EXCEPTION_RECORD *rec, CONTEXT *context )
{
    NTSTATUS status;
    DWORD i;
"""
if anchor not in src:
    print("dispatch_exception not found; nothing changed")
    sys.exit(1)

helper = r'''/* fh6: first-chance exception trace (channel fh6exc, ERR level), see tools/mac_trace_exceptions.py */
WINE_DECLARE_DEBUG_CHANNEL(fh6exc);

static void fh6_where( ULONG_PTR pc, char *buf, size_t size )
{
    LDR_DATA_TABLE_ENTRY *mod;
    char name[32];
    unsigned int i;

    if (pc >= 0x10000 && !LdrFindEntryForAddress( (void *)pc, &mod ) && mod->BaseDllName.Buffer)
    {
        for (i = 0; i < mod->BaseDllName.Length / sizeof(WCHAR) && i < sizeof(name) - 1; i++)
            name[i] = (char)mod->BaseDllName.Buffer[i];
        name[i] = 0;
        snprintf( buf, size, "%s+%x", name, (unsigned int)(pc - (ULONG_PTR)mod->DllBase) );
    }
    else snprintf( buf, size, "%p", (void *)pc );
}

static void fh6_trace_exception( const EXCEPTION_RECORD *rec, const CONTEXT *context )
{
    static LONG total;
    static struct { ULONG_PTR key; LONG n; } seen[512];
    ULONG_PTR frames[16], base, frame, lo, hi, key;
    char line[1600], where[64];
    unsigned int i, n = 0;
    size_t pos = 0;
    RUNTIME_FUNCTION *fn;
    CONTEXT ctx;
    void *data;
    int len;

    switch (rec->ExceptionCode)
    {
    case EXCEPTION_ILLEGAL_INSTRUCTION:
    case EXCEPTION_PRIV_INSTRUCTION:
    case EXCEPTION_BREAKPOINT:
    case EXCEPTION_SINGLE_STEP:
    case EXCEPTION_WINE_NAME_THREAD:
    case DBG_PRINTEXCEPTION_C:
    case DBG_PRINTEXCEPTION_WIDE_C:
        return;
    }
    if (!ERR_ON(fh6exc) || total >= 3000) return;

    /* unwind a copy of the faulting context, never reading outside this thread's stack */
    ctx = *context;
    lo = (ULONG_PTR)NtCurrentTeb()->Tib.StackLimit;
    hi = (ULONG_PTR)NtCurrentTeb()->Tib.StackBase;
    while (n < ARRAY_SIZE(frames))
    {
        frames[n++] = ctx.Rip;
        if (ctx.Rsp < lo || ctx.Rsp + 8 > hi) break;
        if ((fn = RtlLookupFunctionEntry( ctx.Rip, &base, NULL )))
            RtlVirtualUnwind( UNW_FLAG_NHANDLER, base, ctx.Rip, fn, &ctx, &data, &frame, NULL );
        else
        {
            ctx.Rip = *(ULONG64 *)ctx.Rsp;   /* a leaf, or code without unwind data */
            ctx.Rsp += 8;
        }
        if (ctx.Rip < 0x10000 || ctx.Rsp < lo || ctx.Rsp > hi) break;
    }

    key = rec->ExceptionCode;
    for (i = 0; i < n && i < 4; i++) key = key * 1000003 ^ frames[i];
    i = key % ARRAY_SIZE(seen);
    if (seen[i].key == key) { if (InterlockedIncrement( &seen[i].n ) > 3) return; }
    else { seen[i].key = key; seen[i].n = 1; }
    if (InterlockedIncrement( &total ) > 3000) return;

#define FH6_ADD(...) do { len = snprintf( line + pos, sizeof(line) - pos, __VA_ARGS__ ); \
        if (len > 0) pos = min( pos + len, sizeof(line) - 1 ); } while (0)
    fh6_where( (ULONG_PTR)rec->ExceptionAddress, where, sizeof(where) );
    FH6_ADD( "code %08lx flags %lx at %s", rec->ExceptionCode, rec->ExceptionFlags, where );
    if (rec->NumberParameters >= 2)
        FH6_ADD( " info %p %p", (void *)rec->ExceptionInformation[0], (void *)rec->ExceptionInformation[1] );
    FH6_ADD( " stack:" );
    for (i = 0; i < n; i++)
    {
        fh6_where( frames[i], where, sizeof(where) );
        FH6_ADD( " %s", where );
    }
    ERR_(fh6exc)( "%s\n", line );

    /* an access violation: the registers, the stack top, and the code around the instruction (as it is in memory
     * now, after the copy protection decrypted it), when those pages are readable */
    if (rec->ExceptionCode == EXCEPTION_ACCESS_VIOLATION)
    {
        MEMORY_BASIC_INFORMATION mbi;
        ULONG_PTR from = context->Rip - 64, to = context->Rip + 32, p;
        BOOL readable = TRUE;

        pos = 0;
        FH6_ADD( "regs rax %p rbx %p rcx %p rdx %p rsi %p rdi %p rbp %p rsp %p r8 %p r9 %p r10 %p r11 %p r12 %p r13 %p r14 %p r15 %p",
                 (void *)context->Rax, (void *)context->Rbx, (void *)context->Rcx, (void *)context->Rdx, (void *)context->Rsi,
                 (void *)context->Rdi, (void *)context->Rbp, (void *)context->Rsp, (void *)context->R8, (void *)context->R9,
                 (void *)context->R10, (void *)context->R11, (void *)context->R12, (void *)context->R13, (void *)context->R14,
                 (void *)context->R15 );
        ERR_(fh6exc)( "%s\n", line );
        pos = 0;
        FH6_ADD( "stack top:" );
        for (i = 0; i < 16 && context->Rsp + (i + 1) * 8 <= hi && context->Rsp >= lo; i++)
            FH6_ADD( " %p", ((void **)context->Rsp)[i] );
        ERR_(fh6exc)( "%s\n", line );
        for (p = from & ~(ULONG_PTR)0xfff; p < to && readable; p += 0x1000)
            readable = context->Rip >= 0x10000 &&
                       !NtQueryVirtualMemory( GetCurrentProcess(), (void *)p, MemoryBasicInformation, &mbi, sizeof(mbi), NULL ) &&
                       mbi.State == MEM_COMMIT && !(mbi.Protect & (PAGE_GUARD | PAGE_NOACCESS)) && mbi.Protect;
        if (readable)
        {
            pos = 0;
            FH6_ADD( "code from %p:", (void *)from );
            for (p = from; p < to; p++) FH6_ADD( "%s%02x", p == context->Rip ? " >" : " ", *(const unsigned char *)p );
            ERR_(fh6exc)( "%s\n", line );
        }
    }
#undef FH6_ADD
}


'''

src = src.replace(anchor, helper + anchor, 1)
call_anchor = """    TRACE( "code=%lx (%s) flags=%lx addr=%p\\n",
           rec->ExceptionCode, debugstr_exception_code(rec->ExceptionCode),
           rec->ExceptionFlags, rec->ExceptionAddress );"""
if call_anchor not in src:
    print("trace anchor not found; nothing changed")
    sys.exit(1)
src = src.replace(call_anchor, "    fh6_trace_exception( rec, context );\n\n" + call_anchor, 1)
open(path, "w").write(src)
print("exception.c updated")
