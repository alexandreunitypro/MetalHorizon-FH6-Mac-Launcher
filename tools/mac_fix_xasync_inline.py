#!/usr/bin/env python3
"""Runtime calls in xgameruntime must not complete inside the call (dlls/xgameruntime/xthreading.c).

What the game showed (2026-10-25, unix fault report of tools/mac_trace_faults.sh): two threads on one freed object.
The main thread faulted in forzahorizon6.exe+3217541 copying a std::function out of an object at 0x4cd233a80 (its
manager pointer read as 1), and a thread-pool thread then called a completion routine at address 1 from
xgameruntime's invoke_async_completion (xthreading.c), its XAsyncBlock at 0x4cd233a90 -- inside that same object.
The other crashes the user collected over the days match: execution at 0x4CE7FEE00 (a heap address) on the thread of
an Xbox Live HTTP call, and reads of 0x8 at the same game function, all while the online session's coordinator ran.

xgameruntime answers a number of calls from inside the call itself (xgr_async_complete_ex: networking's
XNetworkingQuerySecurityInformationForUrlAsync, which libHttpClient asks before every WebSocket and HTTP request, and
most of XStore, XGameUI, XGameSave, XUser): it writes the result into the block and hands the completion to the thread
pool before returning, so the title's completion routine can run while the title is still inside the call, and
anything polling the block sees it finished before the call returned. On Windows those calls finish on the queue's
work port and complete on its completion port, after the call has returned. libHttpClient, which the coordinator's
WebSocket and HTTP traffic goes through, is written for that order.

The fix keeps the answer but delivers it the GDK's way: the block reads as pending when the call returns, and a
thread-pool item (counted against the block's queue, so terminating the queue waits for it) then publishes the result
and delivers the completion by the usual route. XGR_INLINE_COMPLETIONS=1 brings back the old behaviour.
It also refuses to call a completion routine that is not code (not in a mapped image nor in executable memory: address
1, a heap address), logging the block and who completed it, rather than jumping there. That is the crash itself, and
the title's object behind such a block is already gone.
Backup: xthreading.c.pre-fh6-xasyncdefer.bak (made by tools/mac_fix_xasync_inline.sh)."""
import sys

path = sys.argv[1]
src = open(path).read()
if "fh6: deferred runtime completions" in src:
    print("already applied")
    sys.exit(0)


def replace(old, new, what):
    global src
    if src.count(old) != 1:
        print(f"STOP: {what} not found exactly once; nothing changed")
        sys.exit(1)
    src = src.replace(old, new)


replace("""    XTaskQueueHandle origin;
    XTaskQueueDispatchMode mode;
};
""", """    XTaskQueueHandle origin;
    XTaskQueueDispatchMode mode;
    void *source;                       /* who began or completed it, for diagnostics */
};
""", "struct x_completion_route")

replace("""    struct x_task_queue *owner;     /* the queue the block named, which waits for this */
};
""", """    struct x_task_queue *owner;     /* the queue the block named, which waits for this */
    void *source;
};
""", "struct x_pending_completion")

replace("""static void invoke_async_completion( struct x_pending_completion *item )
{
    struct x_task_queue *owner = item->owner;
    struct x_running_frame frame;

    enter_frame( &frame, owner );
    item->callback( item->async );
    leave_frame( &frame );""", """/* fh6: deferred runtime completions, and no jump to a completion routine that is not code
 * (tools/mac_fix_xasync_inline.py). A routine lives in a mapped image, or in executable memory a title generated;
 * address 1, or a heap address, is the remains of a block its owner has freed and reused. */
static BOOL completion_routine_is_code( const void *routine )
{
    MEMORY_BASIC_INFORMATION mbi;

    if ((ULONG_PTR)routine < 0x10000 || !VirtualQuery( routine, &mbi, sizeof(mbi) ) || mbi.State != MEM_COMMIT) return FALSE;
    if (mbi.Type == MEM_IMAGE) return TRUE;
    return (mbi.Protect & (PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY)) != 0;
}

static void invoke_async_completion( struct x_pending_completion *item )
{
    struct x_task_queue *owner = item->owner;
    struct x_running_frame frame;

    if (!completion_routine_is_code( item->callback ))
    {
        ERR( "not calling completion routine %p for block %p: not code (block begun or completed from %p).\\n",
             item->callback, item->async, item->source );
        release_async_op( item->keep_alive );
        free( item );
        if (owner) queue_finish( owner );
        return;
    }
    enter_frame( &frame, owner );
    item->callback( item->async );
    leave_frame( &frame );""", "invoke_async_completion")

replace("""    item->port = route->port;
    item->origin = route->origin;
    if (keep_alive) InterlockedIncrement( &keep_alive->ref );""", """    item->port = route->port;
    item->origin = route->origin;
    item->source = route->source;
    if (keep_alive) InterlockedIncrement( &keep_alive->ref );""", "deliver_completion item setup")

replace("""void xgr_async_complete_ex( XAsyncBlock *async, HRESULT hr, void *payload, SIZE_T result_size )
{
    struct x_completion_route route;

    if (!async) return;
    capture_completion_route( async, &route );
    store_async_result( async, hr, payload, result_size );
    deliver_completion( &route, NULL );
}""", """/* A runtime call that has its answer at once still finishes the GDK's way: the block reads as pending when the call
 * returns, and the answer is published and the completion delivered from the thread pool afterwards, as it would come
 * from the queue's work port on Windows. Completing inside the call let the title's completion routine run while the
 * title was still inside the call, and libHttpClient -- every Xbox Live HTTP and WebSocket request asks
 * XNetworkingQuerySecurityInformationForUrlAsync first -- is written for the Windows order: Forza Horizon 6's online
 * session ended with two threads on one freed object, one of them calling a completion routine at address 1. */
struct x_deferred_completion
{
    struct x_completion_route route;
    HRESULT hr;
    void *payload;
    SIZE_T result_size;
};

static BOOL WINAPI init_inline_completions( INIT_ONCE *once, void *param, void **context )
{
    char value[8];
    *(BOOL *)param = GetEnvironmentVariableA( "XGR_INLINE_COMPLETIONS", value, sizeof(value) ) && value[0] == '1';
    return TRUE;
}

static BOOL inline_completions( void )
{
    static INIT_ONCE once = INIT_ONCE_STATIC_INIT;
    static BOOL inline_wanted;
    InitOnceExecuteOnce( &once, init_inline_completions, &inline_wanted, NULL );
    return inline_wanted;
}

static void CALLBACK deferred_completion_work( TP_CALLBACK_INSTANCE *instance, void *context )
{
    struct x_deferred_completion *d = context;
    struct x_task_queue *owner = (struct x_task_queue *)d->route.queue;

    TRACE( "publishing the answer for block %p (from %p).\\n", d->route.async, d->route.source );
    store_async_result( d->route.async, d->hr, d->payload, d->result_size );
    deliver_completion( &d->route, NULL );
    if (owner) queue_finish( owner );
    free( d );
}

void xgr_async_complete_ex( XAsyncBlock *async, HRESULT hr, void *payload, SIZE_T result_size )
{
    struct x_deferred_completion *d;
    struct x_completion_route route;

    if (!async) return;
    capture_completion_route( async, &route );
    route.source = __builtin_return_address( 0 );
    if (!inline_completions() && (d = calloc( 1, sizeof(*d) )))
    {
        d->route = route;
        d->hr = hr;
        d->payload = payload;
        d->result_size = result_size;
        /* Pending until the work runs. A reused block may still carry its previous answer. */
        memset( async->internal, 0, sizeof(async->internal) );
        if (route.queue) queue_hold( (struct x_task_queue *)route.queue );
        if (TrySubmitThreadpoolCallback( deferred_completion_work, d, NULL )) return;
        if (SUCCEEDED(run_off_pool( deferred_completion_work, d ))) return;
        if (route.queue) queue_finish( (struct x_task_queue *)route.queue );
        free( d );
        WARN( "no thread to defer the answer for block %p; completing it in the call.\\n", async );
    }
    store_async_result( async, hr, payload, result_size );
    deliver_completion( &route, NULL );
}""", "xgr_async_complete_ex")

# who began provider and run operations
replace("""    op->ref = 2;
    capture_completion_route( asyncBlock, &op->route );
    memset( asyncBlock->internal, 0, sizeof(asyncBlock->internal) );

    EnterCriticalSection( &async_ops_cs );
    list_add_tail( &async_ops, &op->entry );
    LeaveCriticalSection( &async_ops_cs );
    TRACE( "operation %p registered for block %p (run).\\n", op, asyncBlock );""", """    op->ref = 2;
    capture_completion_route( asyncBlock, &op->route );
    op->route.source = __builtin_return_address( 0 );
    memset( asyncBlock->internal, 0, sizeof(asyncBlock->internal) );

    EnterCriticalSection( &async_ops_cs );
    list_add_tail( &async_ops, &op->entry );
    LeaveCriticalSection( &async_ops_cs );
    TRACE( "operation %p registered for block %p (run).\\n", op, asyncBlock );""", "XAsyncRun route")

replace("""    op->begin_running = TRUE;
    capture_completion_route( asyncBlock, &op->route );
    memset( asyncBlock->internal, 0, sizeof(asyncBlock->internal) );""", """    op->begin_running = TRUE;
    capture_completion_route( asyncBlock, &op->route );
    op->route.source = __builtin_return_address( 0 );
    memset( asyncBlock->internal, 0, sizeof(asyncBlock->internal) );""", "XAsyncBegin route")

# run_off_pool is defined after xgr_async_complete_ex? it is defined earlier (struct x_offpool_work); check order
if src.index("static HRESULT run_off_pool(") > src.index("void xgr_async_complete_ex("):
    src = src.replace("struct x_deferred_completion\n{", "static HRESULT run_off_pool( PTP_SIMPLE_CALLBACK callback, void *context );\n\nstruct x_deferred_completion\n{", 1)
if src.index("static void queue_hold(") > src.index("void xgr_async_complete_ex("):
    print("STOP: queue_hold comes after xgr_async_complete_ex"); sys.exit(1)

open(path, "w").write(src)
print("xthreading.c updated")
