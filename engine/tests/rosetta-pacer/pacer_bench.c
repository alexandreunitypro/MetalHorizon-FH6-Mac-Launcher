/*
 * pacer_bench: Rosetta's translator stops, with and without Blackwell Engine's pacer (engine/src/pacer/bw_pacer.h).
 *
 * The load is what Forza Horizon 6's protection does: trapper threads execute an undefined instruction (ud2) in
 * memory mapped at run time, over and over, and a SIGILL handler steps over it; writer threads rewrite small
 * functions in writable, executable pages and call them, so the translator throws its work away and translates
 * again. Every call of each is timed. A stop is a call of 20 ms or more. No Wine, no game: built for x86_64 so it
 * runs under Rosetta, as the game does.
 *
 *   clang -O2 -arch x86_64 -I../../src/pacer -o pacer_bench pacer_bench.c -lpthread
 *   [BW_PACER=auto|<duty>[,<bytes>]] [BW_TRAP_BOOST=1] ./pacer_bench <seconds> [trappers=2] [writers=3] [pages=4096]
 *                                                               [spinners=0]
 * Spinners are threads that only keep a core busy, as the game's own threads do (the trap boost's case).
 *
 * Prints the stops (when, how long) and, per thread kind, the calls made a second.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#define _XOPEN_SOURCE 700
#define _DARWIN_C_SOURCE
#include "bw_pacer.h"
#include "bw_trapboost.h"
#include <signal.h>
#include <sys/ucontext.h>
#include <pthread/qos.h>

#define MAX_STOPS 512
struct stop { char kind; int index; double at_s, took_ms; };
static struct stop stops[MAX_STOPS];
static volatile int nstops;
static pthread_mutex_t stops_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int running = 1;
static uint64_t start_ns;
static volatile unsigned long long trap_calls, write_calls;

static void note_stop( char kind, int index, uint64_t at, uint64_t took )
{
    pthread_mutex_lock( &stops_lock );
    if (nstops < MAX_STOPS) stops[nstops++] = (struct stop){ kind, index, (at - start_ns) / 1e9, took / 1e6 };
    pthread_mutex_unlock( &stops_lock );
}

static void on_sigill( int sig, siginfo_t *info, void *context )
{
    ucontext_t *uc = context;
    (void)sig; (void)info;
    uc->uc_mcontext->__ss.__rip += 2;   /* step over ud2 */
}

static void *trapper( void *arg )
{
    int index = (int)(intptr_t)arg;
    unsigned char *stub = mmap( NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0 );
    /* BENCH_TRAPPER_QOS=utility: the trapping threads at a low priority, against high-priority spinners */
    if (getenv( "BENCH_TRAPPER_QOS" ) && !strcmp( getenv( "BENCH_TRAPPER_QOS" ), "utility" ))
        pthread_set_qos_class_self_np( QOS_CLASS_UTILITY, 0 );
    stub[0] = 0x0f; stub[1] = 0x0b; stub[2] = 0xc3;   /* ud2; ret */
    while (running)
    {
        uint64_t t0 = bw_pacer_now(), took;
        ((void (*)(void))stub)();
        took = bw_pacer_now() - t0;
        __atomic_add_fetch( &trap_calls, 1, __ATOMIC_RELAXED );
        if (took >= 20000000ull) note_stop( 'T', index, t0, took );
    }
    return NULL;
}

static unsigned pages = 4096;

static void *spinner( void *arg )
{
    volatile unsigned long long n = 0;
    (void)arg;
    /* BENCH_SPINNER_QOS=1: the spinners run as a game's high-priority threads do (Wine maps them to this QoS) */
    if (getenv( "BENCH_SPINNER_QOS" ) && !strcmp( getenv( "BENCH_SPINNER_QOS" ), "1" ))
        pthread_set_qos_class_self_np( QOS_CLASS_USER_INTERACTIVE, 0 );
    while (running) n++;
    return NULL;
}

static void *writer( void *arg )
{
    int index = (int)(intptr_t)arg;
    unsigned char *region = mmap( NULL, (size_t)pages * 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                                  MAP_PRIVATE | MAP_ANON, -1, 0 );
    uint32_t value = (uint32_t)index;
    unsigned page = 0;
    while (running)
    {
        unsigned char *code = region + (size_t)page * 4096;
        uint64_t t0 = bw_pacer_now(), took;
        code[0] = 0xb8; memcpy( code + 1, &value, 4 ); code[5] = 0xc3;   /* mov eax, value; ret */
        ((uint32_t (*)(void))code)();
        took = bw_pacer_now() - t0;
        value += 7;
        page = (page + 1) % pages;
        __atomic_add_fetch( &write_calls, 1, __ATOMIC_RELAXED );
        if (took >= 20000000ull) note_stop( 'W', index, t0, took );
    }
    return NULL;
}

int main( int argc, char **argv )
{
    unsigned seconds = argc > 1 ? (unsigned)atoi( argv[1] ) : 60;
    unsigned trappers = argc > 2 ? (unsigned)atoi( argv[2] ) : 2;
    unsigned writers = argc > 3 ? (unsigned)atoi( argv[3] ) : 3;
    unsigned spinners = argc > 5 ? (unsigned)atoi( argv[5] ) : 0;
    struct sigaction sa;
    pthread_t threads[64];
    unsigned i, n = 0, worst_ms = 0;
    int pacer, boost;

    if (argc > 4) pages = (unsigned)atoi( argv[4] );
    memset( &sa, 0, sizeof(sa) );
    sa.sa_sigaction = on_sigill;
    sa.sa_flags = SA_SIGINFO;
    sigaction( SIGILL, &sa, NULL );
    printf( "pacer_bench: %u s, %u trappers, %u writers, %u pages, under Rosetta: %s, BW_PACER=%s\n", seconds,
            trappers, writers, pages, bw_pacer_translated() ? "yes" : "no", getenv( "BW_PACER" ) ? getenv( "BW_PACER" ) : "(unset)" );
    start_ns = bw_pacer_now();
    pacer = bw_pacer_start( NULL );
    boost = bw_trapboost_start( NULL );
    for (i = 0; i < spinners && n < 64; i++) pthread_create( &threads[n++], NULL, spinner, NULL );
    for (i = 0; i < trappers && n < 64; i++) pthread_create( &threads[n++], NULL, trapper, (void *)(intptr_t)i );
    for (i = 0; i < writers && n < 64; i++) pthread_create( &threads[n++], NULL, writer, (void *)(intptr_t)i );
    sleep( seconds );
    running = 0;
    for (i = 0; i < n; i++) pthread_join( threads[i], NULL );

    /* one stop shared by several threads is one event: grouped by start within 5 ms */
    printf( "pacer: %s, trap boost: %s, spinners: %u\n", pacer ? "on" : "off", boost ? "on" : "off", spinners );
    if (trappers) printf( "one trap's round trip: %.1f us on average\n", seconds * trappers * 1e6 / (double)(trap_calls ? trap_calls : 1) );
    printf( "calls a second: traps %.0f, rewrites %.0f\n", trap_calls / (double)seconds, write_calls / (double)seconds );
    printf( "stops of 20 ms or more (any thread):\n" );
    {
        double last = -1;
        int events = 0;
        for (i = 0; i < (unsigned)nstops; i++)
        {
            if (stops[i].took_ms > worst_ms) worst_ms = (unsigned)stops[i].took_ms;
            if (last < 0 || stops[i].at_s - last > 0.005) { printf( "  at %7.3f s: %6.1f ms\n", stops[i].at_s, stops[i].took_ms ); events++; }
            last = stops[i].at_s;
        }
        printf( "events: %d, longest %u ms\n", events, worst_ms );
    }
    return 0;
}
