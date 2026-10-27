/* asyncprobe: the order in which xgameruntime finishes a runtime call answered at once.
 * Calls XNetworkingQuerySecurityInformationForUrlAsync (what libHttpClient asks before every Xbox Live HTTP and
 * WebSocket request) many times, from several threads at once, and counts:
 *   - completion routines that ran before the call had returned (never on Windows),
 *   - blocks that already read as finished when the call returned (on Windows they read as pending),
 *   - completions delivered more than once, or not at all, and results that do not read back.
 * Usage: asyncprobe.exe [calls per thread, default 3000] */
#define INITGUID
#include <windows.h>
#include <stdio.h>

/* Only what is called here, in the order of the vtables Wine's xgameruntime builds (its widl headers,
 * xasyncprovider.idl and xnetworking.idl); every other slot is a placeholder. */
typedef struct XAsyncBlock XAsyncBlock;
typedef void CALLBACK XAsyncCompletionRoutine( XAsyncBlock * );
struct XAsyncBlock { void *queue; void *context; XAsyncCompletionRoutine *callback; unsigned char internal[sizeof(void *) * 4]; };
typedef void *slot;
typedef struct IXThreadingImpl { const struct {
    slot qi, addref, release;
    HRESULT (STDMETHODCALLTYPE *XAsyncGetStatus)( struct IXThreadingImpl *, XAsyncBlock *, BOOLEAN );
} *lpVtbl; } IXThreadingImpl;
typedef struct IXNetworkingImpl2 { const struct {
    slot qi, addref, release, port, port_async, port_result, port_register, port_unregister;
    HRESULT (STDMETHODCALLTYPE *XNetworkingQuerySecurityInformationForUrlAsync)( struct IXNetworkingImpl2 *, const char *, XAsyncBlock * );
    HRESULT (STDMETHODCALLTYPE *XNetworkingQuerySecurityInformationForUrlAsyncResultSize)( struct IXNetworkingImpl2 *, XAsyncBlock *, SIZE_T * );
} *lpVtbl; } IXNetworkingImpl2;
DEFINE_GUID(CLSID_XThreadingImpl, 0x073b7dcb, 0x1fcf, 0x4030, 0x94,0xbe, 0xe3,0xc9,0xeb,0x62,0x34,0x28);
DEFINE_GUID(IID_IXThreadingImpl, 0x073b7dcb, 0x1fcf, 0x4030, 0x94,0xbe, 0xe3,0xc9,0xeb,0x62,0x34,0x28);
DEFINE_GUID(CLSID_XNetworkingImpl, 0x37e56907, 0x2f10, 0x41e8, 0xb7,0x2f, 0x36,0xed,0xb1,0x85,0x33,0x1a);
DEFINE_GUID(IID_IXNetworkingImpl2, 0xbf2346b2, 0x39af, 0x4658, 0xb5,0xea, 0x44,0x71,0x3c,0x7e,0x83,0xb3);
#define IXThreadingImpl_XAsyncGetStatus(t, b, w) (t)->lpVtbl->XAsyncGetStatus( t, b, w )
#define IXNetworkingImpl2_XNetworkingQuerySecurityInformationForUrlAsync(n, u, b) (n)->lpVtbl->XNetworkingQuerySecurityInformationForUrlAsync( n, u, b )
#define IXNetworkingImpl2_XNetworkingQuerySecurityInformationForUrlAsyncResultSize(n, b, s) (n)->lpVtbl->XNetworkingQuerySecurityInformationForUrlAsyncResultSize( n, b, s )

#define THREADS 4
typedef HRESULT (WINAPI *PFN_QueryApiImpl)( REFCLSID, REFIID, void ** );
struct call { XAsyncBlock block; volatile LONG returned; volatile LONG completions; volatile LONG early; HANDLE done; };
static IXThreadingImpl *thr;
static IXNetworkingImpl2 *net;
static LONG calls, early, finished_at_return, double_done, missing, bad_result;
static int per_thread = 3000;

static void CALLBACK on_done( XAsyncBlock *block )
{
    struct call *c = block->context;
    if (!InterlockedCompareExchange( &c->returned, 0, 0 )) InterlockedExchange( &c->early, 1 );
    InterlockedIncrement( &c->completions );
    SetEvent( c->done );
}

static DWORD WINAPI worker( void *arg )
{
    int i;
    for (i = 0; i < per_thread; i++)
    {
        struct call *c = calloc( 1, sizeof(*c) );
        SIZE_T size = 0;
        HRESULT hr;

        c->done = CreateEventW( NULL, TRUE, FALSE, NULL );
        c->block.context = c;
        c->block.callback = on_done;
        hr = IXNetworkingImpl2_XNetworkingQuerySecurityInformationForUrlAsync( net, "https://sessiondirectory.xboxlive.com/", &c->block );
        InterlockedExchange( &c->returned, 1 );
        if (FAILED(hr)) { printf("PROBE call failed %08lx\n", hr); continue; }
        InterlockedIncrement( &calls );
        if (IXThreadingImpl_XAsyncGetStatus( thr, &c->block, FALSE ) != E_PENDING) InterlockedIncrement( &finished_at_return );
        if (WaitForSingleObject( c->done, 5000 )) { InterlockedIncrement( &missing ); continue; }   /* leaked on purpose */
        Sleep( 0 );
        if (c->early) InterlockedIncrement( &early );
        if (IXNetworkingImpl2_XNetworkingQuerySecurityInformationForUrlAsyncResultSize( net, &c->block, &size ) != S_OK || !size)
            InterlockedIncrement( &bad_result );
        if (c->completions != 1) InterlockedIncrement( &double_done );
        CloseHandle( c->done );
        free( c );
    }
    return 0;
}

int main( int argc, char **argv )
{
    HMODULE dll = LoadLibraryA( "xgameruntime.dll" );
    PFN_QueryApiImpl query = dll ? (PFN_QueryApiImpl)GetProcAddress( dll, "QueryApiImpl" ) : NULL;
    HANDLE threads[THREADS];
    int i;

    setvbuf( stdout, NULL, _IONBF, 0 );
    if (argc > 1) per_thread = atoi( argv[1] );
    if (!query || FAILED(query( &CLSID_XThreadingImpl, &IID_IXThreadingImpl, (void **)&thr ))
        || FAILED(query( &CLSID_XNetworkingImpl, &IID_IXNetworkingImpl2, (void **)&net )))
    {
        printf( "PROBE cannot reach xgameruntime (%p)\n", dll );
        return 1;
    }
    for (i = 0; i < THREADS; i++) threads[i] = CreateThread( NULL, 0, worker, NULL, 0, NULL );
    WaitForMultipleObjects( THREADS, threads, TRUE, INFINITE );
    printf( "PROBE calls %ld: completion before the call returned %ld, finished when the call returned %ld, "
            "delivered twice %ld, never delivered %ld, result unreadable %ld\n",
            calls, early, finished_at_return, double_done, missing, bad_result );
    return 0;
}
