/* winlist: prints every top-level window of the running Wine session (same prefix) with its
 * process, class, title, size, and the text of its child controls, so a message box that macOS
 * draws too small to read can still be read. Read-only. */
#include <windows.h>
#include <stdio.h>

static BOOL CALLBACK child_proc(HWND h, LPARAM p)
{
    WCHAR cls[128], txt[1024];
    GetClassNameW(h, cls, 128);
    txt[0] = 0; SendMessageTimeoutW(h, WM_GETTEXT, 1024, (LPARAM)txt, SMTO_ABORTIFHUNG, 500, NULL);
    if (txt[0]) printf("    child %ls: \"%ls\"\n", cls, txt);
    return TRUE;
}

static BOOL CALLBACK top_proc(HWND h, LPARAM p)
{
    WCHAR cls[128], title[512];
    DWORD pid = 0; RECT r;
    GetWindowThreadProcessId(h, &pid);
    if (pid == GetCurrentProcessId()) return TRUE;
    GetClassNameW(h, cls, 128);
    title[0] = 0; SendMessageTimeoutW(h, WM_GETTEXT, 512, (LPARAM)title, SMTO_ABORTIFHUNG, 500, NULL);
    GetWindowRect(h, &r);
    printf("window %p pid %04lx visible %d %ldx%ld at %ld,%ld class \"%ls\" title \"%ls\"\n", (void *)h, pid,
           IsWindowVisible(h), r.right - r.left, r.bottom - r.top, r.left, r.top, cls, title);
    EnumChildWindows(h, child_proc, 0);
    return TRUE;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    EnumWindows(top_proc, 0);
    printf("winlist done\n");
    return 0;
}
