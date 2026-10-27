/* wsprobe: opens an async WinHTTP WebSocket the way libHttpClient (PlayFab lobby, Xbox RTA) does, sends one message,
 * then stays idle with a receive pending. On Windows the idle receive blocks; the caller counts how many
 * "recv error 10035" Wine logs meanwhile (a busy loop shows thousands). Sends nothing secret.
 * Usage: wsprobe.exe [host] [path] [idle-seconds] [tls13]   default ws.postman-echo.com /raw 20 0
 * Build: x86_64-w64-mingw32-gcc -O1 -o wsprobe.exe wsprobe.c -lwinhttp */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

static HINTERNET ws;
static HANDLE upgraded, echoed;
static char rbuf[4096];
static volatile LONG reads, errors;

static void CALLBACK cb( HINTERNET h, DWORD_PTR ctx, DWORD status, void *info, DWORD len )
{
    switch (status)
    {
    case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
        WinHttpReceiveResponse( h, NULL );
        break;
    case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
        SetEvent( upgraded );
        break;
    case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
    {
        WINHTTP_WEB_SOCKET_STATUS *st = info;
        InterlockedIncrement( &reads );
        printf( "read %lu bytes type %u\n", st->dwBytesTransferred, st->eBufferType );
        fflush( stdout );
        SetEvent( echoed );
        WinHttpWebSocketReceive( ws, rbuf, sizeof(rbuf), NULL, NULL );
        break;
    }
    case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
    {
        WINHTTP_ASYNC_RESULT *r = info;
        InterlockedIncrement( &errors );
        printf( "request error: api %Iu error %lu\n", r->dwResult, r->dwError );
        fflush( stdout );
        SetEvent( upgraded ); SetEvent( echoed );
        break;
    }
    }
}

int main( int argc, char **argv )
{
    WCHAR host[256], path[256];
    int idle = argc > 3 ? atoi( argv[3] ) : 20;
    HINTERNET ses, con, req;
    DWORD ka = 0, err;
    static char msg[] = "wsprobe hello";

    MultiByteToWideChar( CP_ACP, 0, argc > 1 ? argv[1] : "ws.postman-echo.com", -1, host, 256 );
    MultiByteToWideChar( CP_ACP, 0, argc > 2 ? argv[2] : "/raw", -1, path, 256 );
    upgraded = CreateEventW( NULL, FALSE, FALSE, NULL );
    echoed = CreateEventW( NULL, FALSE, FALSE, NULL );

    ses = WinHttpOpen( L"wsprobe", WINHTTP_ACCESS_TYPE_NO_PROXY, NULL, NULL, WINHTTP_FLAG_ASYNC );
    WinHttpSetStatusCallback( ses, cb, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0 );
    if (argc > 4 && atoi( argv[4] ))
    {
        /* what libHttpClient applies from XNetworkingQuerySecurityInformationForUrl (xgameruntime: TLS 1.2 | 1.3) */
        DWORD protos = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | 0x2000 /* TLS1_3 */;
        printf( "secure protocols tls1.2|1.3: %d\n", WinHttpSetOption( ses, WINHTTP_OPTION_SECURE_PROTOCOLS, &protos, sizeof(protos) ) );
    }
    con = WinHttpConnect( ses, host, 443, 0 );
    req = WinHttpOpenRequest( con, L"GET", path, NULL, NULL, NULL, WINHTTP_FLAG_SECURE );
    WinHttpSetOption( req, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0 );
    if (!WinHttpSendRequest( req, NULL, 0, NULL, 0, 0, 0 )) { printf( "send failed %lu\n", GetLastError() ); return 1; }
    if (WaitForSingleObject( upgraded, 20000 )) { printf( "no upgrade response\n" ); return 1; }
    if (errors) return 1;
    if (!(ws = WinHttpWebSocketCompleteUpgrade( req, 0 ))) { printf( "upgrade failed %lu\n", GetLastError() ); return 1; }
    printf( "websocket open\n" );
    /* libHttpClient-style options; Wine logs whether it accepts them */
    if (!WinHttpSetOption( ws, WINHTTP_OPTION_WEB_SOCKET_KEEPALIVE_INTERVAL, &ka, sizeof(ka) ))
        printf( "keepalive 0 refused: %lu\n", GetLastError() );
    err = WinHttpWebSocketReceive( ws, rbuf, sizeof(rbuf), NULL, NULL );
    printf( "receive queued: %lu\n", err );
    err = WinHttpWebSocketSend( ws, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, msg, sizeof(msg) - 1 );
    printf( "send: %lu\n", err );
    printf( "echo %s\n", WaitForSingleObject( echoed, 15000 ) ? "NOT received" : "received" );
    fflush( stdout );
    printf( "idle %d s with a receive pending...\n", idle );
    fflush( stdout );
    Sleep( idle * 1000 );
    printf( "done: reads %ld errors %ld\n", reads, errors );
    fflush( stdout );
    ExitProcess( 0 );
}
