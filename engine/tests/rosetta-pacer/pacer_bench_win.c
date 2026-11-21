/*
 * pacer_bench_win: the load of pacer_bench.c as a Windows program, so it runs inside Wine under Rosetta as Forza
 * Horizon 6 does: trapper threads execute ud2 in memory allocated at run time and a vectored exception handler steps
 * over it (Wine's own exception dispatch, the path the game's protection takes), writer threads rewrite small
 * functions in executable pages and call them. Every call is timed; a stop is a call of 20 ms or more.
 *
 *   x86_64-w64-mingw32-clang -O2 -o pacerbench.exe pacer_bench_win.c
 *   [BW_PACER=auto BW_PACER_EXE=pacerbench.exe] wine pacerbench.exe <seconds> [trappers=2] [writers=3] [pages=4096]
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

#define MAX_STOPS 512
static struct { char kind; double at_s, took_ms; } stops[MAX_STOPS];
static volatile LONG nstops, running = 1;
static volatile LONG64 trap_calls, write_calls;
static LARGE_INTEGER freq, start;
static unsigned pages = 4096;

static double since( LARGE_INTEGER t ) { return (double)(t.QuadPart - start.QuadPart) / freq.QuadPart; }

static void note( char kind, LARGE_INTEGER t0, LARGE_INTEGER t1 )
{
    double took = (double)(t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart;
    LONG i;
    if (took < 20.0) return;
    i = InterlockedIncrement( &nstops ) - 1;
    if (i < MAX_STOPS) { stops[i].kind = kind; stops[i].at_s = since( t0 ); stops[i].took_ms = took; }
}

static LONG CALLBACK on_exception( EXCEPTION_POINTERS *info )
{
    if (info->ExceptionRecord->ExceptionCode != EXCEPTION_ILLEGAL_INSTRUCTION) return EXCEPTION_CONTINUE_SEARCH;
    info->ContextRecord->Rip += 2;   /* step over ud2 */
    return EXCEPTION_CONTINUE_EXECUTION;
}

static DWORD WINAPI trapper( void *arg )
{
    unsigned char *stub = VirtualAlloc( NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    (void)arg;
    stub[0] = 0x0f; stub[1] = 0x0b; stub[2] = 0xc3;   /* ud2; ret */
    while (running)
    {
        LARGE_INTEGER t0, t1;
        QueryPerformanceCounter( &t0 );
        ((void (*)(void))stub)();
        QueryPerformanceCounter( &t1 );
        InterlockedIncrement64( &trap_calls );
        note( 'T', t0, t1 );
    }
    return 0;
}

static DWORD WINAPI writer( void *arg )
{
    unsigned char *region = VirtualAlloc( NULL, (SIZE_T)pages * 4096, MEM_RESERVE | MEM_COMMIT, PAGE_EXECUTE_READWRITE );
    UINT32 value = (UINT32)(ULONG_PTR)arg;
    unsigned page = 0;
    while (running)
    {
        unsigned char *code = region + (SIZE_T)page * 4096;
        LARGE_INTEGER t0, t1;
        QueryPerformanceCounter( &t0 );
        code[0] = 0xb8; memcpy( code + 1, &value, 4 ); code[5] = 0xc3;   /* mov eax, value; ret */
        ((UINT32 (*)(void))code)();
        QueryPerformanceCounter( &t1 );
        value += 7; page = (page + 1) % pages;
        InterlockedIncrement64( &write_calls );
        note( 'W', t0, t1 );
    }
    return 0;
}

int main( int argc, char **argv )
{
    unsigned seconds = argc > 1 ? atoi( argv[1] ) : 60, trappers = argc > 2 ? atoi( argv[2] ) : 2;
    unsigned writers = argc > 3 ? atoi( argv[3] ) : 3, i, n = 0, events = 0;
    HANDLE threads[64];
    double last = -1, worst = 0;

    if (argc > 4) pages = atoi( argv[4] );
    QueryPerformanceFrequency( &freq );
    QueryPerformanceCounter( &start );
    AddVectoredExceptionHandler( 1, on_exception );
    for (i = 0; i < trappers && n < 64; i++) threads[n++] = CreateThread( NULL, 0, trapper, (void *)(ULONG_PTR)i, 0, NULL );
    for (i = 0; i < writers && n < 64; i++) threads[n++] = CreateThread( NULL, 0, writer, (void *)(ULONG_PTR)i, 0, NULL );
    Sleep( seconds * 1000 );
    running = 0;
    WaitForMultipleObjects( n, threads, TRUE, 10000 );
    printf( "pacerbench (Windows, in Wine): %u s, %u trappers, %u writers, %u pages\n", seconds, trappers, writers, pages );
    printf( "calls a second: traps %.0f, rewrites %.0f\n", trap_calls / (double)seconds, write_calls / (double)seconds );
    for (i = 0; i < (unsigned)nstops && i < MAX_STOPS; i++)
    {
        if (stops[i].took_ms > worst) worst = stops[i].took_ms;
        if (last < 0 || stops[i].at_s - last > 0.005) { printf( "  stop at %7.3f s: %6.1f ms\n", stops[i].at_s, stops[i].took_ms ); events++; }
        last = stops[i].at_s;
    }
    printf( "events: %u, longest %.0f ms\n", events, worst );
    return 0;
}
