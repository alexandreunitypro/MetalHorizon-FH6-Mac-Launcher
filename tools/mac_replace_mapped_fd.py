#!/usr/bin/env python3
"""Replace mapped_fd_to_handle() in a Wine dlls/ntdll/unix/loader.c with the macOS-aware version
from patches/wine/0001 (same code, inserted without depending on surrounding comments)."""
import sys

OLD = '''static NTSTATUS mapped_fd_to_handle( int fd, HANDLE *handle )
{
    char path[32];
    NTSTATUS status;
    int own_fd;

    snprintf( path, sizeof(path), "/proc/self/fd/%d", fd );
    if ((own_fd = open( path, O_RDONLY )) == -1)
        return wine_server_fd_to_handle( fd, GENERIC_READ | SYNCHRONIZE, 0, handle );

    status = wine_server_fd_to_handle( own_fd, GENERIC_READ | SYNCHRONIZE, 0, handle );
    close( own_fd );
    return status;
}
'''

NEW = '''/* macOS has no /proc: reopen through the name F_GETPATH gives, which needs the file to keep a
 * name (see patches/xodus-cli/0001). The reopened file must be the same device and inode. If
 * nothing works, fall back to the shared descriptor and say so once: a title that hashes its own
 * image several times then reads nothing on the second pass. */
static int reopen_mapped_fd( int fd )
{
    struct stat st_fd, st_own;
    int own_fd = -1;
#ifdef F_GETPATH
    char path[PATH_MAX];

    if (fcntl( fd, F_GETPATH, path ) != -1) own_fd = open( path, O_RDONLY | O_CLOEXEC );
#else
    char path[32];

    snprintf( path, sizeof(path), "/proc/self/fd/%d", fd );
    own_fd = open( path, O_RDONLY | O_CLOEXEC );
#endif
    if (own_fd == -1) return -1;
    if (fstat( fd, &st_fd ) == -1 || fstat( own_fd, &st_own ) == -1 ||
        st_fd.st_dev != st_own.st_dev || st_fd.st_ino != st_own.st_ino)
    {
        close( own_fd );
        return -1;
    }
    return own_fd;
}

static NTSTATUS mapped_fd_to_handle( int fd, HANDLE *handle )
{
    static int warned;
    NTSTATUS status;
    int own_fd;

    if ((own_fd = reopen_mapped_fd( fd )) == -1)
    {
        if (!warned++)
            ERR( "mapped image fd %d cannot be reopened (errno %d); every handle on it shares one "
                 "file position\\n", fd, errno );
        return wine_server_fd_to_handle( fd, GENERIC_READ | SYNCHRONIZE, 0, handle );
    }

    status = wine_server_fd_to_handle( own_fd, GENERIC_READ | SYNCHRONIZE, 0, handle );
    close( own_fd );
    return status;
}
'''

path = sys.argv[1]
src = open(path).read()
if "reopen_mapped_fd" in src:
    print("already applied"); sys.exit(0)
if src.count(OLD) != 1:
    print("mapped_fd_to_handle not found exactly once; nothing changed"); sys.exit(1)
if "#include <limits.h>" not in src:
    src = src.replace("#include <fcntl.h>\n", "#include <fcntl.h>\n#include <limits.h>\n", 1)
open(path, "w").write(src.replace(OLD, NEW))
print("loader.c updated")
