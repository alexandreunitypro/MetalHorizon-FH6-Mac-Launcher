/*
 * Blackwell Trap Boost: Rosetta's exception server, given the priority the game's traps need.
 *
 * Every hardware exception translated x86_64 code takes (ud2 and the other invalid instructions Forza Horizon 6's
 * protection executes in waves, int3, writes into translated pages) is serviced by one thread per process,
 * com.apple.rosetta.exceptionserver, at default priority. With the game keeping the cores busy, that thread waits for
 * a core on every trap. Found and measured by Mathias Kowoll for MacGameFix (NotProton's rosetta-trap-boost plugin:
 * on an M4 Max with 14 busy threads, a trap's round trip took 42-88 us against an 18.6 us floor), where it is a
 * library injected into the process. Here it is Blackwell Engine's own code, in Wine's ntdll: one thread looks for
 * the exception server by name and raises it to the latency and throughput tiers, and the precedence, of a highest-
 * priority thread, then checks every few seconds that it stays there. No Wine thread and no game code is touched.
 *
 *   BW_TRAP_BOOST=1   on (MetalHorizon's beta engine sets it); unset or 0: nothing starts.
 * Started by bw_trapboost_start() only in the program BW_PACER_EXE names (forzahorizon6.exe by default), and only
 * when Rosetta translates the process. One line on stderr when the server is raised.
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */
#ifndef BW_TRAPBOOST_H
#define BW_TRAPBOOST_H

#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/sysctl.h>
#include <unistd.h>

#define BW_TRAPBOOST_SERVER "com.apple.rosetta.exceptionserver"

static inline int bw_trapboost_translated(void)
{
    int value = 0;
    size_t size = sizeof(value);
    return !sysctlbyname( "sysctl.proc_translated", &value, &size, NULL, 0 ) && value == 1;
}

/* The tiers and precedence of a thread that must never wait for a core while the game's threads keep them busy. */
static inline int bw_trapboost_raise( thread_act_t thread )
{
    integer_t latency = LATENCY_QOS_TIER_0, throughput = THROUGHPUT_QOS_TIER_0;
    thread_extended_policy_data_t timeshare = { 1 };
    thread_precedence_policy_data_t precedence = { 5 };
    kern_return_t kr = thread_policy_set( thread, THREAD_LATENCY_QOS_POLICY, (thread_policy_t)&latency,
                                          THREAD_LATENCY_QOS_POLICY_COUNT );
    thread_policy_set( thread, THREAD_THROUGHPUT_QOS_POLICY, (thread_policy_t)&throughput, THREAD_THROUGHPUT_QOS_POLICY_COUNT );
    thread_policy_set( thread, THREAD_EXTENDED_POLICY, (thread_policy_t)&timeshare, THREAD_EXTENDED_POLICY_COUNT );
    thread_policy_set( thread, THREAD_PRECEDENCE_POLICY, (thread_policy_t)&precedence, THREAD_PRECEDENCE_POLICY_COUNT );
    return kr == KERN_SUCCESS;
}

/* Raises every thread of this task named like Rosetta's exception server. Returns how many were raised. */
static inline int bw_trapboost_once(void)
{
    thread_act_array_t threads;
    mach_msg_type_number_t count = 0, i;
    int raised = 0;

    if (task_threads( mach_task_self(), &threads, &count ) != KERN_SUCCESS) return 0;
    for (i = 0; i < count; i++)
    {
        thread_extended_info_data_t info;
        mach_msg_type_number_t size = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info( threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&info, &size ) == KERN_SUCCESS &&
            !strncmp( info.pth_name, BW_TRAPBOOST_SERVER, sizeof(info.pth_name) ) && bw_trapboost_raise( threads[i] ))
            raised++;
        mach_port_deallocate( mach_task_self(), threads[i] );
    }
    vm_deallocate( mach_task_self(), (vm_address_t)threads, count * sizeof(*threads) );
    return raised;
}

static void *bw_trapboost_thread( void *arg )
{
    sigset_t all;
    int said = 0;
    (void)arg;
    /* Not a Wine thread: no signal Wine handles may ever land here */
    sigfillset( &all );
    pthread_sigmask( SIG_BLOCK, &all, NULL );
    for (;;)
    {
        /* the server appears with the process's first exception: looked for every second until found, then kept
         * raised every five seconds */
        int raised = bw_trapboost_once();
        if (raised && !said) { fprintf( stderr, "bw-trapboost: Rosetta's exception server raised\n" ); said = 1; }
        sleep( said ? 5 : 1 );
    }
    return NULL;
}

/* Starts when BW_TRAP_BOOST=1, the process is translated by Rosetta and `exe` (the main program's file name, or NULL
 * to skip the check) is the one BW_PACER_EXE names. Returns 1 when a thread was started. */
static inline int bw_trapboost_start( const char *exe )
{
    const char *on = getenv( "BW_TRAP_BOOST" ), *want = getenv( "BW_PACER_EXE" );
    pthread_attr_t attr;
    pthread_t thread;

    if (!on || strcmp( on, "1" )) return 0;
    if (!want || !*want) want = "forzahorizon6.exe";
    if (exe && strcasecmp( exe, want )) return 0;
    if (!bw_trapboost_translated()) return 0;
    pthread_attr_init( &attr );
    pthread_attr_setdetachstate( &attr, PTHREAD_CREATE_DETACHED );
    if (pthread_create( &thread, &attr, bw_trapboost_thread, NULL )) { pthread_attr_destroy( &attr ); return 0; }
    pthread_attr_destroy( &attr );
    return 1;
}

#endif /* BW_TRAPBOOST_H */
