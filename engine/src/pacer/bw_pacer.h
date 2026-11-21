/*
 * Blackwell Pacer: keeps Rosetta's translator stops short in a program that rewrites its own code all the time.
 *
 * The problem (found by Mathias Kowoll for MacGameFix, after Gauthier Piarrette first reported Forza Horizon 6's
 * protection under Rosetta): the protection keeps rewriting code, Rosetta translates every rewritten piece again,
 * its store of translations fills, and Rosetta empties it in one go. While it does, every thread that needs the
 * translator waits, about 0.4 us per translation the store holds: Forza Horizon 6 freezes 100-170 ms every ~10 s
 * (and engine/tests/rosetta-pacer measures 297-302 ms every 12.9 s on an M5 Pro, with no game and no Wine).
 * MacGameFix's countermeasure is a thread that runs large functions never seen before, at a duty the player picks:
 * they fill the store with few translations, Rosetta empties it more often, and each stop is short.
 *
 * What this one does differently (Blackwell Engine's own code, written for it):
 *   - It lives in Wine's ntdll (the Unix side, which under Rosetta is translated x86 code like the game), not in a
 *     DLL the game loads, and starts only in the program it is meant for (BW_PACER_EXE, forzahorizon6.exe by
 *     default), only when the process really runs under Rosetta.
 *   - BW_PACER=auto (what MetalHorizon's beta engine sets) tunes its own duty: it sees the translator's stops
 *     itself (one of its calls that waits far longer than a call takes), raises its duty while stops last long,
 *     and lowers it while they stay short, so it takes as little translator time from the game as the machine
 *     needs. MacGameFix found the right duty differs from one chip to the next; this one looks for it.
 *   - BW_PACER=<duty>[,<bytes>] keeps a fixed duty (1-100 per cent of each 10 ms) and function size; BW_PACER=off,
 *     0 or no variable: no thread.
 *   - Every 10 s one line on stderr (the game's log): duty, functions made, the stops it saw and the longest.
 *
 * Plain POSIX: the same file builds into ntdll.so and into the macOS bench (engine/tests/rosetta-pacer).
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef BW_PACER_H
#define BW_PACER_H

#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define BW_PACER_REGION   ((size_t)64 << 20)   /* the functions go through this region, then start over */
#define BW_PACER_SLICE_NS 10000000ull          /* a duty is a share of each 10 ms */
#define BW_PACER_WINDOW   3000000000ull        /* auto: one decision every 3 s */
#define BW_PACER_STOP_NS  15000000ull          /* a call that took 15 ms or more waited for the translator */

struct bw_pacer
{
    unsigned duty;          /* per cent of each slice spent making and running functions */
    unsigned bytes;         /* size of each function */
    int      automatic;     /* duty tuned from the stops seen */
    unsigned min_duty, max_duty;
    /* what was seen */
    unsigned long long made, stops;
    unsigned long long longest_ns, window_longest_ns;
    unsigned quiet_windows;
};

static inline uint64_t bw_pacer_now(void)
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static inline void bw_pacer_sleep_ns( uint64_t ns )
{
    struct timespec ts = { (time_t)(ns / 1000000000ull), (long)(ns % 1000000000ull) };
    nanosleep( &ts, NULL );
}

/* Running as translated x86 code (Rosetta)? 0 natively, and on an Intel Mac. */
static inline int bw_pacer_translated(void)
{
    int value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname( "sysctl.proc_translated", &value, &size, NULL, 0 )) return 0;
    return value == 1;
}

static inline unsigned bw_pacer_clamp_bytes( unsigned bytes )
{
    if (!bytes) return 16384;
    if (bytes < 2048) return 2048;
    if (bytes > 65536) return 65536;
    return bytes;
}

/* BW_PACER: "auto", "off"/"0", or "<duty>[,<bytes>]". Returns 0 when no thread is wanted. */
static inline int bw_pacer_parse( const char *value, struct bw_pacer *p )
{
    unsigned duty = 0, bytes = 0;
    memset( p, 0, sizeof(*p) );
    if (!value || !*value) return 0;
    if (!strcasecmp( value, "off" )) return 0;
    if (!strncasecmp( value, "auto", 4 ))
    {
        p->automatic = 1;
        p->duty = 40;                   /* where MacGameFix's player found the best compromise on an M4 Max */
        p->min_duty = 10;
        p->max_duty = 70;
        if (value[4] == ',') bytes = (unsigned)strtoul( value + 5, NULL, 10 );
        p->bytes = bw_pacer_clamp_bytes( bytes );
        return 1;
    }
    if (sscanf( value, "%u,%u", &duty, &bytes ) < 1 || !duty) return 0;
    p->duty = duty > 100 ? 100 : duty;
    p->min_duty = p->max_duty = p->duty;
    p->bytes = bw_pacer_clamp_bytes( bytes );
    return 1;
}

/* One function never seen before: mov eax, <unique>; popcnt eax, ecx ... ; ret. The unique constant makes every
 * function new to the translator; popcnt is short, register-only and translates to one instruction. */
static inline void bw_pacer_make( unsigned char *code, unsigned bytes, uint32_t unique )
{
    static const unsigned char body[4] = { 0xf3, 0x0f, 0xb8, 0xc1 };   /* popcnt eax, ecx */
    unsigned n = 0;
    code[n++] = 0xb8; memcpy( code + n, &unique, 4 ); n += 4;          /* mov eax, imm32 */
    while (n + sizeof(body) + 1 <= bytes) { memcpy( code + n, body, sizeof(body) ); n += sizeof(body); }
    code[n] = 0xc3;                                                      /* ret */
}

/* The auto rule, once per window: stops of 60 ms or more raise the duty by 10 (the translator needs more help);
 * two windows in a row whose longest stop stayed under 35 ms lower it by 5 (give the translator back to the game). */
static inline void bw_pacer_decide( struct bw_pacer *p )
{
    if (!p->automatic) return;
    if (p->window_longest_ns >= 60000000ull)
    {
        p->duty = p->duty + 10 > p->max_duty ? p->max_duty : p->duty + 10;
        p->quiet_windows = 0;
    }
    else if (p->window_longest_ns < 35000000ull)
    {
        if (++p->quiet_windows >= 2)
        {
            p->duty = p->duty < p->min_duty + 5 ? p->min_duty : p->duty - 5;
            p->quiet_windows = 0;
        }
    }
    else p->quiet_windows = 0;
    p->window_longest_ns = 0;
}

static void *bw_pacer_thread( void *arg )
{
    struct bw_pacer *p = arg;
    unsigned char *region = mmap( NULL, BW_PACER_REGION, PROT_READ | PROT_WRITE | PROT_EXEC,
                                  MAP_PRIVATE | MAP_ANON, -1, 0 );
    uint64_t window_start = bw_pacer_now(), log_start = window_start;
    unsigned long long made_logged = 0, stops_logged = 0;
    size_t offset = 0;
    uint32_t unique = 1;

    sigset_t all;

    /* Not a Wine thread: no signal Wine handles may ever land here (its handlers expect a thread it made) */
    sigfillset( &all );
    pthread_sigmask( SIG_BLOCK, &all, NULL );
    if (region == MAP_FAILED)
    {
        fprintf( stderr, "bw-pacer: no executable memory for the pacer; off\n" );
        return NULL;
    }
    fprintf( stderr, "bw-pacer: on (%s, duty %u%%, functions of %u bytes)\n",
             p->automatic ? "auto" : "fixed", p->duty, p->bytes );
    for (;;)
    {
        uint64_t slice = bw_pacer_now(), now;
        do
        {
            uint64_t t0, took;
            unsigned char *code;
            if (offset + p->bytes > BW_PACER_REGION) offset = 0;
            code = region + offset;
            offset += p->bytes;
            t0 = bw_pacer_now();
            bw_pacer_make( code, p->bytes, unique );
            unique += 3;
            ((uint32_t (*)(void))code)();
            took = bw_pacer_now() - t0;
            p->made++;
            if (took >= BW_PACER_STOP_NS) p->stops++;
            if (took > p->longest_ns) p->longest_ns = took;
            if (took > p->window_longest_ns) p->window_longest_ns = took;
            now = bw_pacer_now();
        } while ((now - slice) * 100 < (uint64_t)p->duty * BW_PACER_SLICE_NS);
        if (p->duty < 100) bw_pacer_sleep_ns( BW_PACER_SLICE_NS * (100 - p->duty) / 100 );

        now = bw_pacer_now();
        if (now - window_start >= BW_PACER_WINDOW) { bw_pacer_decide( p ); window_start = now; }
        if (now - log_start >= 10000000000ull)
        {
            fprintf( stderr, "bw-pacer: duty %u%%, %llu functions, %llu translator stops seen (longest %llu ms)\n",
                     p->duty, p->made - made_logged, p->stops - stops_logged, p->longest_ns / 1000000 );
            made_logged = p->made; stops_logged = p->stops; p->longest_ns = 0; log_start = now;
        }
    }
    return NULL;
}

/* Starts the pacer when BW_PACER asks for it, the process is translated by Rosetta, and `exe` (the main program's
 * file name, or NULL to skip the check) is the one BW_PACER_EXE names. Returns 1 when a thread was started. */
static inline int bw_pacer_start( const char *exe )
{
    static struct bw_pacer pacer;
    const char *want = getenv( "BW_PACER_EXE" );
    pthread_attr_t attr;
    pthread_t thread;

    if (!bw_pacer_parse( getenv( "BW_PACER" ), &pacer )) return 0;
    if (!want || !*want) want = "forzahorizon6.exe";
    if (exe && strcasecmp( exe, want )) return 0;
    if (!bw_pacer_translated()) return 0;
    pthread_attr_init( &attr );
    pthread_attr_setdetachstate( &attr, PTHREAD_CREATE_DETACHED );
    if (pthread_create( &thread, &attr, bw_pacer_thread, &pacer )) { pthread_attr_destroy( &attr ); return 0; }
    pthread_attr_destroy( &attr );
    return 1;
}

#endif /* BW_PACER_H */
