/* httpprobe v2: replays, against real servers and with no credentials, the WinHTTP call sequence that the game's
 * PlayFab/libHttpClient stack uses (async request; on HEADERS_AVAILABLE: status query, RAW_HEADERS_CRLF size query,
 * second query, QueryDataAvailable, ReadData) and a small battery of header queries whose Windows results are known,
 * both inside the callback and in sync mode, plus which winhttp.dll file is loaded. Sends nothing secret.
 * Build: x86_64-w64-mingw32-gcc -O1 -static -o httpprobe.exe httpprobe.c -lwinhttp */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HANDLE done;
static volatile LONG body_bytes, ok_headers, got_headers, had_error;
static char buffer[65536];

static const char *cbname(DWORD s)
{
    switch (s)
    {
    case 0x1: return "RESOLVING_NAME";       case 0x2: return "NAME_RESOLVED";
    case 0x4: return "CONNECTING";           case 0x8: return "CONNECTED";
    case 0x10: return "SENDING_REQUEST";     case 0x20: return "REQUEST_SENT";
    case 0x40: return "RECEIVING_RESPONSE";  case 0x80: return "RESPONSE_RECEIVED";
    case 0x100: return "CLOSING_CONNECTION"; case 0x200: return "CONNECTION_CLOSED";
    case 0x400: return "HANDLE_CREATED";     case 0x800: return "HANDLE_CLOSING";
    case 0x10000: return "SECURE_FAILURE";   case 0x20000: return "HEADERS_AVAILABLE";
    case 0x40000: return "DATA_AVAILABLE";   case 0x80000: return "READ_COMPLETE";
    case 0x100000: return "WRITE_COMPLETE";  case 0x200000: return "REQUEST_ERROR";
    case 0x400000: return "SENDREQUEST_COMPLETE";
    default: return "?";
    }
}

/* What Windows returns for each line is in the last column of the printout. */
static void battery(HINTERNET h, const char *tag)
{
    DWORD len, err, idx;
    BOOL ok;
    WCHAR small[2];

    SetLastError(1234);
    printf("  [%s] sanity: SetLastError(1234) then GetLastError() = %lu   (want 1234)\n", tag, GetLastError());

    len = 0; SetLastError(0);
    ok = WinHttpQueryHeaders(h, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, NULL, &len,
                             WINHTTP_NO_HEADER_INDEX);
    err = GetLastError();
    printf("  [%s] RAW_HEADERS_CRLF null-buffer: ok=%d err=%lu needed=%lu   (Windows: ok=0 err=122)\n", tag, ok, err, len);

    len = 0; SetLastError(0);
    ok = WinHttpQueryHeaders(h, WINHTTP_QUERY_RAW_HEADERS, WINHTTP_HEADER_NAME_BY_INDEX, NULL, &len,
                             WINHTTP_NO_HEADER_INDEX);
    err = GetLastError();
    printf("  [%s] RAW_HEADERS      null-buffer: ok=%d err=%lu needed=%lu   (Windows: ok=0 err=122)\n", tag, ok, err, len);

    len = sizeof(small); SetLastError(0);
    ok = WinHttpQueryHeaders(h, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, small, &len,
                             WINHTTP_NO_HEADER_INDEX);
    err = GetLastError();
    printf("  [%s] RAW_HEADERS_CRLF 4-byte buf : ok=%d err=%lu needed=%lu   (Windows: ok=0 err=122)\n", tag, ok, err, len);

    len = 0; SetLastError(0);
    ok = WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_TEXT, WINHTTP_HEADER_NAME_BY_INDEX, NULL, &len,
                             WINHTTP_NO_HEADER_INDEX);
    err = GetLastError();
    printf("  [%s] STATUS_TEXT      null-buffer: ok=%d err=%lu needed=%lu   (Windows: ok=0 err=122)\n", tag, ok, err, len);

    len = sizeof(small); idx = 0; SetLastError(0);
    ok = WinHttpQueryHeaders(h, WINHTTP_QUERY_CUSTOM, L"X-Header-That-Is-Not-There", small, &len, &idx);
    err = GetLastError();
    printf("  [%s] custom missing header       : ok=%d err=%lu                 (Windows: ok=0 err=12150)\n", tag, ok, err);
}

static void query_headers_like_the_game(HINTERNET h)
{
    DWORD code = 0, sz = sizeof(code), len = 0, err;
    BOOL ok;
    WCHAR *raw;
    ok = WinHttpQueryHeaders(h, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX,
                             &code, &sz, WINHTTP_NO_HEADER_INDEX);
    printf("  [headers] status-code query: ok=%d code=%lu\n", ok, code);
    SetLastError(0);
    ok = WinHttpQueryHeaders(h, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, NULL, &len,
                             WINHTTP_NO_HEADER_INDEX);
    err = GetLastError();
    printf("  [headers] RAW_HEADERS_CRLF size query: ok=%d err=%lu needed=%lu bytes   (Windows: ok=0 err=122 needed>0)\n",
           ok, err, len);
    if (!ok && err == ERROR_INSUFFICIENT_BUFFER && len)
    {
        raw = calloc(1, len + 4);
        ok = WinHttpQueryHeaders(h, WINHTTP_QUERY_RAW_HEADERS_CRLF, WINHTTP_HEADER_NAME_BY_INDEX, raw, &len,
                                 WINHTTP_NO_HEADER_INDEX);
        printf("  [headers] RAW_HEADERS_CRLF 2nd query: ok=%d len=%lu first line: %.40ls\n", ok, len, raw);
        free(raw);
        if (ok) InterlockedExchange(&ok_headers, 1);
    }
    battery(h, "callback");
    InterlockedExchange(&got_headers, 1);
}

static void CALLBACK cb(HINTERNET h, DWORD_PTR ctx, DWORD status, void *info, DWORD infolen)
{
    printf("  callback %-20s (0x%lx) len=%lu\n", cbname(status), status, infolen);
    switch (status)
    {
    case WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE:
        if (!WinHttpReceiveResponse(h, NULL))
        { printf("  ReceiveResponse FAILED err=%lu\n", GetLastError()); InterlockedExchange(&had_error, 1); SetEvent(done); }
        break;
    case WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE:
        query_headers_like_the_game(h);
        if (!WinHttpQueryDataAvailable(h, NULL))
        { printf("  QueryDataAvailable FAILED err=%lu\n", GetLastError()); InterlockedExchange(&had_error, 1); SetEvent(done); }
        break;
    case WINHTTP_CALLBACK_STATUS_DATA_AVAILABLE:
    {
        DWORD n = info ? *(DWORD *)info : 0;
        if (!n) { SetEvent(done); break; }
        if (n > sizeof(buffer)) n = sizeof(buffer);
        if (!WinHttpReadData(h, buffer, n, NULL))
        { printf("  ReadData FAILED err=%lu\n", GetLastError()); InterlockedExchange(&had_error, 1); SetEvent(done); }
        break;
    }
    case WINHTTP_CALLBACK_STATUS_READ_COMPLETE:
        InterlockedAdd(&body_bytes, (LONG)infolen);
        if (!WinHttpQueryDataAvailable(h, NULL))
        { printf("  QueryDataAvailable FAILED err=%lu\n", GetLastError()); InterlockedExchange(&had_error, 1); SetEvent(done); }
        break;
    case WINHTTP_CALLBACK_STATUS_REQUEST_ERROR:
    {
        WINHTTP_ASYNC_RESULT *r = info;
        printf("  REQUEST_ERROR api=%lu error=%lu\n", (unsigned long)r->dwResult, r->dwError);
        InterlockedExchange(&had_error, 1);
        SetEvent(done);
        break;
    }
    case WINHTTP_CALLBACK_STATUS_SECURE_FAILURE:
        printf("  SECURE_FAILURE flags=%#lx\n", info ? *(DWORD *)info : 0);
        break;
    }
}

static int run_async(const WCHAR *host, const WCHAR *path, const WCHAR *method)
{
    HINTERNET s, c, r;
    DWORD w;
    int pass, post = !wcscmp(method, L"POST");
    body_bytes = ok_headers = got_headers = had_error = 0;
    ResetEvent(done);
    printf("[async] %ls %ls%ls\n", method, host, path);
    if (!(s = WinHttpOpen(L"httpprobe", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, NULL, NULL, WINHTTP_FLAG_ASYNC)))
    { printf("  WinHttpOpen FAILED err=%lu\n", GetLastError()); return 0; }
    if (!(c = WinHttpConnect(s, host, 443, 0))) { printf("  Connect FAILED err=%lu\n", GetLastError()); return 0; }
    if (!(r = WinHttpOpenRequest(c, method, path, NULL, NULL, NULL, WINHTTP_FLAG_SECURE | WINHTTP_FLAG_ESCAPE_DISABLE)))
    { printf("  OpenRequest FAILED err=%lu\n", GetLastError()); return 0; }
    WinHttpSetStatusCallback(r, cb, WINHTTP_CALLBACK_FLAG_ALL_NOTIFICATIONS, 0);
    if (!WinHttpSendRequest(r, L"Accept: application/json\r\nContent-Type: application/json; charset=utf-8\r\n", (DWORD)-1,
                            (LPVOID)(post ? "{}" : NULL), post ? 2 : 0, post ? 2 : 0, 1))
    { printf("  SendRequest FAILED err=%lu\n", GetLastError()); return 0; }
    w = WaitForSingleObject(done, 30000);
    if (w != WAIT_OBJECT_0) printf("  TIMEOUT after 30 s\n");
    WinHttpCloseHandle(r); WinHttpCloseHandle(c); WinHttpCloseHandle(s);
    pass = !had_error && got_headers && ok_headers && w == WAIT_OBJECT_0;
    printf("  => body bytes read: %ld   RESULT: %s\n", body_bytes, pass ? "OK" : "FAIL");
    return pass;
}

static int run_sync(const WCHAR *host, const WCHAR *path)
{
    HINTERNET s, c, r;
    DWORD code = 0, sz = sizeof(code), avail, rd, total = 0;
    printf("[sync ] GET %ls%ls\n", host, path);
    if (!(s = WinHttpOpen(L"httpprobe", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, NULL, NULL, 0)) ||
        !(c = WinHttpConnect(s, host, 443, 0)) ||
        !(r = WinHttpOpenRequest(c, L"GET", path, NULL, NULL, NULL, WINHTTP_FLAG_SECURE)) ||
        !WinHttpSendRequest(r, NULL, 0, NULL, 0, 0, 0) || !WinHttpReceiveResponse(r, NULL))
    { printf("  FAILED err=%lu   RESULT: FAIL\n", GetLastError()); return 0; }
    WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &code, &sz,
                        WINHTTP_NO_HEADER_INDEX);
    battery(r, "sync");
    while (WinHttpQueryDataAvailable(r, &avail) && avail)
    {
        if (avail > sizeof(buffer)) avail = sizeof(buffer);
        if (!WinHttpReadData(r, buffer, avail, &rd)) break;
        total += rd;
    }
    printf("  status %lu, body bytes read: %lu   RESULT: OK\n", code, total);
    WinHttpCloseHandle(r); WinHttpCloseHandle(c); WinHttpCloseHandle(s);
    return 1;
}

int main(void)
{
    int a, b, c, d;
    typedef const char *(CDECL *ver_t)(void);
    ver_t ver = (ver_t)GetProcAddress(GetModuleHandleA("ntdll.dll"), "wine_get_version");
    HMODULE m = GetModuleHandleW(L"winhttp.dll");
    WCHAR path[MAX_PATH] = L"?";
    setvbuf(stdout, NULL, _IONBF, 0);
    done = CreateEventW(NULL, TRUE, FALSE, NULL);
    printf("httpprobe v2, Wine %s\n", ver ? ver() : "(not Wine)");
    if (m)
    {
        IMAGE_NT_HEADERS *nt = (IMAGE_NT_HEADERS *)((BYTE *)m + ((IMAGE_DOS_HEADER *)m)->e_lfanew);
        GetModuleFileNameW(m, path, MAX_PATH);
        printf("winhttp.dll loaded: %ls   size-of-image=%lu  timestamp=%08lx  checksum=%08lx\n", path,
               (unsigned long)nt->OptionalHeader.SizeOfImage, (unsigned long)nt->FileHeader.TimeDateStamp,
               (unsigned long)nt->OptionalHeader.CheckSum);
    }
    a = run_sync(L"example.com", L"/");
    b = run_async(L"example.com", L"/", L"GET");
    c = run_async(L"16d460.playfabapi.com", L"/", L"GET");
    d = run_async(L"16d460.playfabapi.com", L"/Client/LoginWithXbox?sdk=probe", L"POST");
    printf("SUMMARY: sync-example=%s async-example=%s async-playfab-GET=%s async-playfab-POST=%s\n",
           a ? "OK" : "FAIL", b ? "OK" : "FAIL", c ? "OK" : "FAIL", d ? "OK" : "FAIL");
    return 0;
}
