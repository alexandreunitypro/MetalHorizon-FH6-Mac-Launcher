/*
 * selfread.exe -- probe for the way a protected Microsoft Store (MSIXVC) title
 * re-reads its own executable, without needing the game.
 *
 * Ferestre (patches/wine/0009, 0010, 0013) documents that Forza Horizon 5 asks
 * NtQueryVirtualMemory(MemoryMappedFilenameInformation) which file its image
 * base came from, opens that file three times through the
 * \\?\GLOBALROOT\??\Z:\... form, hashes what it reads and stops the process
 * when the hash is wrong.  Under Xodus the executable on disk is still
 * encrypted; the decrypted copy only exists behind the descriptor named in
 * WINE_DLL_FILE_MAP, so every one of those steps has to land on that
 * descriptor, and every handle has to start reading at offset 0.
 *
 * This program does the same thing to itself and prints one line per check.
 * Run it through tools/mapfd_run.py so that the copy on disk is garbage and the
 * real one is only reachable through the mapped descriptor -- the same
 * situation the game is in.
 *
 * It also checks how exceptions reach a vectored handler (ud2, hlt, int3),
 * which is what the earlier SIGILL observations were about.
 *
 * Exit code: number of failed checks (0 = everything behaved like Windows).
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o selfread.exe selfread.c -lntdll
 */
#include <windows.h>
#include <winternl.h>
#include <stdio.h>
#include <string.h>

#ifndef STATUS_PRIVILEGED_INSTRUCTION
#define STATUS_PRIVILEGED_INSTRUCTION ((DWORD)0xC0000096)
#endif

typedef NTSTATUS (NTAPI *NtQueryVirtualMemory_t)(HANDLE, PVOID, int, PVOID, SIZE_T, SIZE_T *);

static int failures;

static void check( int ok, const char *name, const char *fmt, ... )
{
    va_list args;
    printf( "%s %-28s ", ok ? "PASS" : "FAIL", name );
    va_start( args, fmt );
    vprintf( fmt, args );
    va_end( args );
    printf( "\n" );
    fflush( stdout );
    if (!ok) failures++;
}

static unsigned long long fnv1a( unsigned long long h, const BYTE *p, DWORD n )
{
    while (n--) { h ^= *p++; h *= 0x100000001b3ULL; }
    return h;
}

struct read_result
{
    DWORD err;              /* GetLastError() of CreateFileW, 0 if opened */
    unsigned long long total;
    unsigned long long hash;
    BYTE head[2];
};

/* Read a handle to its end with plain ReadFile calls (no offset, no seek),
 * the way a CRT fread loop or a hashing routine does. */
static void read_all( HANDLE h, struct read_result *r )
{
    static BYTE buf[1 << 16];
    DWORD got;

    r->total = 0;
    r->hash = 0xcbf29ce484222325ULL;
    r->head[0] = r->head[1] = 0;
    while (ReadFile( h, buf, sizeof(buf), &got, NULL ) && got)
    {
        if (!r->total && got >= 2) memcpy( r->head, buf, 2 );
        r->hash = fnv1a( r->hash, buf, got );
        r->total += got;
    }
}

static HANDLE open_ro( const WCHAR *name )
{
    return CreateFileW( name, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL );
}

static void file_tests( void )
{
    NtQueryVirtualMemory_t pNtQueryVirtualMemory =
        (NtQueryVirtualMemory_t)GetProcAddress( GetModuleHandleA( "ntdll.dll" ), "NtQueryVirtualMemory" );
    BYTE info[4096];
    UNICODE_STRING *section = (UNICODE_STRING *)info;
    WCHAR modname[MAX_PATH], globalroot[MAX_PATH + 32], nt_name[MAX_PATH + 8];
    struct read_result res[3];
    HANDLE h[3];
    SIZE_T ret_len = 0;
    NTSTATUS status;
    LARGE_INTEGER size;
    int i, len;

    GetModuleFileNameW( NULL, modname, MAX_PATH );
    printf( "INFO module file name: %ls\n", modname );

    /* 1. which file the image base was mapped from */
    status = pNtQueryVirtualMemory( GetCurrentProcess(), GetModuleHandleW( NULL ), 2 /* MemoryMappedFilenameInformation */,
                                    info, sizeof(info), &ret_len );
    len = status ? 0 : section->Length / sizeof(WCHAR);
    if (len) { memcpy( nt_name, section->Buffer, len * sizeof(WCHAR) ); nt_name[len] = 0; }
    else nt_name[0] = 0;
    check( !status && len, "mapped-filename", "status %08lx name \"%ls\"", status, nt_name );
    if (!len) return;

    /* 2. the game's spelling: \\?\GLOBALROOT + NT name (\??\Z:\...) */
    swprintf( globalroot, ARRAYSIZE(globalroot), L"\\\\?\\GLOBALROOT%ls", nt_name );
    printf( "INFO globalroot path: %ls\n", globalroot );

    /* three sequential open/read/close rounds */
    for (i = 0; i < 3; i++)
    {
        memset( &res[i], 0, sizeof(res[i]) );
        h[i] = open_ro( globalroot );
        if (h[i] == INVALID_HANDLE_VALUE) { res[i].err = GetLastError(); continue; }
        if (i == 0 && GetFileSizeEx( h[i], &size ))
            printf( "INFO size through globalroot handle: %lld\n", size.QuadPart );
        read_all( h[i], &res[i] );
        CloseHandle( h[i] );
    }
    for (i = 0; i < 3; i++)
    {
        char name[32];
        sprintf( name, "globalroot-read-%d", i + 1 );
        check( !res[i].err && res[i].total && res[i].head[0] == 'M' && res[i].head[1] == 'Z' &&
               res[i].total == res[0].total && res[i].hash == res[0].hash,
               name, "err %lu bytes %llu head %02x%02x fnv %016llx",
               res[i].err, res[i].total, res[i].head[0], res[i].head[1], res[i].hash );
    }

    /* 3. two handles open at the same time: reading one must not move the other */
    h[0] = open_ro( globalroot );
    h[1] = open_ro( globalroot );
    if (h[0] != INVALID_HANDLE_VALUE && h[1] != INVALID_HANDLE_VALUE)
    {
        BYTE b0[4096], b1[2];
        DWORD got0 = 0, got1 = 0;
        ReadFile( h[0], b0, sizeof(b0), &got0, NULL );
        ReadFile( h[1], b1, sizeof(b1), &got1, NULL );
        check( got1 == 2 && b1[0] == 'M' && b1[1] == 'Z', "independent-offsets",
               "second handle read %lu bytes starting %02x%02x after the first read %lu",
               got1, got1 > 0 ? b1[0] : 0, got1 > 1 ? b1[1] : 0, got0 );
    }
    else check( 0, "independent-offsets", "open failed: %lu", GetLastError() );
    if (h[0] != INVALID_HANDLE_VALUE) CloseHandle( h[0] );
    if (h[1] != INVALID_HANDLE_VALUE) CloseHandle( h[1] );

    /* 4. the plain path, as GetModuleFileName gives it */
    h[0] = open_ro( modname );
    memset( &res[1], 0, sizeof(res[1]) );
    if (h[0] != INVALID_HANDLE_VALUE) { read_all( h[0], &res[1] ); CloseHandle( h[0] ); }
    else res[1].err = GetLastError();
    check( !res[1].err && res[1].hash == res[0].hash && res[1].head[0] == 'M', "plain-path-read",
           "err %lu bytes %llu head %02x%02x fnv %016llx", res[1].err, res[1].total,
           res[1].head[0], res[1].head[1], res[1].hash );

    /* 5. GLOBALROOT prefix on a file that is NOT mapped (needs the generic
     *    \??\GlobalRoot strip in ntdll's get_dos_prefix_len, a Proton change) */
    {
        WCHAR dir[MAX_PATH + 32], *slash;
        swprintf( dir, ARRAYSIZE(dir), L"\\\\?\\GLOBALROOT%ls", nt_name );
        if ((slash = wcsrchr( dir, '\\' ))) wcscpy( slash + 1, L"selfread-plain.txt" );
        h[0] = open_ro( dir );
        check( h[0] != INVALID_HANDLE_VALUE, "globalroot-unmapped-file", "%ls -> err %lu",
               dir, h[0] == INVALID_HANDLE_VALUE ? GetLastError() : 0 );
        if (h[0] != INVALID_HANDLE_VALUE) CloseHandle( h[0] );
    }
}

/* ---- exception delivery ---- */

static volatile DWORD seen_code;
static volatile ULONG_PTR seen_addr, seen_rip;

static LONG CALLBACK veh( EXCEPTION_POINTERS *ep )
{
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code != EXCEPTION_ILLEGAL_INSTRUCTION && code != STATUS_PRIVILEGED_INSTRUCTION &&
        code != EXCEPTION_BREAKPOINT)
        return EXCEPTION_CONTINUE_SEARCH;
    seen_code = code;
    seen_addr = (ULONG_PTR)ep->ExceptionRecord->ExceptionAddress;
    seen_rip = ep->ContextRecord->Rip;
    /* step over the instruction, like an emulating handler would */
    if (code == EXCEPTION_BREAKPOINT) ep->ContextRecord->Rip = seen_addr + 1;
    else ep->ContextRecord->Rip = seen_addr + ((*(BYTE *)seen_addr == 0x0f) ? 2 : 1);
    return EXCEPTION_CONTINUE_EXECUTION;
}

extern void trap_ud2( void ), trap_hlt( void ), trap_int3( void );
extern char trap_ud2_at[], trap_hlt_at[], trap_int3_at[];
__asm__( ".globl trap_ud2, trap_ud2_at\n trap_ud2:\n trap_ud2_at: ud2\n ret\n"
         ".globl trap_hlt, trap_hlt_at\n trap_hlt:\n trap_hlt_at: hlt\n ret\n"
         ".globl trap_int3, trap_int3_at\n trap_int3:\n trap_int3_at: int3\n ret\n" );

static void one_trap( const char *name, void (*fn)(void), const char *at, DWORD want )
{
    LARGE_INTEGER t0, t1, freq;
    int i, n = 2000;

    seen_code = 0; seen_addr = seen_rip = 0;
    fn();
    check( seen_code == want && seen_addr == (ULONG_PTR)at && seen_rip == (ULONG_PTR)at, name,
           "code %08lx (want %08lx) addr %p rip %p (want %p)",
           seen_code, want, (void *)seen_addr, (void *)seen_rip, at );

    /* the cost per round trip, for comparison with the ~15-57 us Highball measured */
    QueryPerformanceFrequency( &freq );
    QueryPerformanceCounter( &t0 );
    for (i = 0; i < n; i++) fn();
    QueryPerformanceCounter( &t1 );
    printf( "INFO %-12s %d traps in %.1f ms (%.1f us each)\n", name, n,
            (t1.QuadPart - t0.QuadPart) * 1000.0 / freq.QuadPart,
            (t1.QuadPart - t0.QuadPart) * 1e6 / freq.QuadPart / n );
}

static void exception_tests( void )
{
    PVOID h = AddVectoredExceptionHandler( 1, veh );
    one_trap( "trap-ud2", trap_ud2, trap_ud2_at, EXCEPTION_ILLEGAL_INSTRUCTION );
    one_trap( "trap-hlt", trap_hlt, trap_hlt_at, STATUS_PRIVILEGED_INSTRUCTION );
    one_trap( "trap-int3", trap_int3, trap_int3_at, EXCEPTION_BREAKPOINT );
    RemoveVectoredExceptionHandler( h );
}

int main( int argc, char **argv )
{
    printf( "selfread probe 1\n" );
    if (argc < 2 || strcmp( argv[1], "--no-files" )) file_tests();
    if (argc < 2 || strcmp( argv[1], "--no-traps" )) exception_tests();
    printf( "RESULT %d failure(s)\n", failures );
    return failures;
}
