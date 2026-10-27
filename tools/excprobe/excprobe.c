/* excprobe: raises a caught access violation and a caught software exception, so the ntdll first-chance
 * trace (tools/mac_trace_exceptions.sh, channel fh6exc) can be checked without the game. */
#include <windows.h>
#include <stdio.h>

static void __attribute__((noinline)) recovered(void)
{
    printf("PROBE recovered from the access violation\n");
    fflush(stdout);
    RaiseException(0xe0000001, 0, 0, NULL);   /* continued by the handler */
    printf("PROBE software exception continued\n");
    ExitProcess(0);
}

static LONG CALLBACK handler(EXCEPTION_POINTERS *e)
{
    if (e->ExceptionRecord->ExceptionCode == EXCEPTION_ACCESS_VIOLATION)
    {
        e->ContextRecord->Rip = (DWORD64)recovered;
        e->ContextRecord->Rsp &= ~(DWORD64)15; e->ContextRecord->Rsp -= 8;
        return EXCEPTION_CONTINUE_EXECUTION;
    }
    if (e->ExceptionRecord->ExceptionCode == 0xe0000001) return EXCEPTION_CONTINUE_EXECUTION;
    return EXCEPTION_CONTINUE_SEARCH;
}

static int __attribute__((noinline)) fault(volatile int *p) { return *p; }
static int __attribute__((noinline)) caller(void) { return fault((volatile int *)8) + 1; }

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    AddVectoredExceptionHandler(1, handler);
    printf("PROBE faulting\n");
    return caller();
}
