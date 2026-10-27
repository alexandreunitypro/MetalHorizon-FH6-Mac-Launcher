/* fontprobe: why do Wine dialogs get 0x0 base units on this Mac? Prints the dialog base units, the
 * text metrics of the stock and message-box fonts, and how many font families GDI can see. */
#include <windows.h>
#include <stdio.h>

static int families;
static int CALLBACK fam_proc(const LOGFONTW *lf, const TEXTMETRICW *tm, DWORD type, LPARAM p)
{
    if (families++ < 8) printf("  family %ls (type %lu)\n", lf->lfFaceName, type);
    return 1;
}

static void metrics(HDC dc, HFONT f, const char *what)
{
    TEXTMETRICW tm = {0}; WCHAR face[64] = {0}; SIZE sz = {0};
    HGDIOBJ old = SelectObject(dc, f);
    BOOL ok = GetTextMetricsW(dc, &tm);
    GetTextFaceW(dc, 64, face);
    GetTextExtentPoint32W(dc, L"Forza", 5, &sz);
    printf("%-22s ok=%d face=%ls height=%ld avewidth=%ld 'Forza'=%ldx%ld\n", what, ok, face,
           tm.tmHeight, tm.tmAveCharWidth, sz.cx, sz.cy);
    SelectObject(dc, old);
}

int main(void)
{
    NONCLIENTMETRICSW ncm = { sizeof(ncm) };
    HDC dc = GetDC(0);
    LOGFONTW lf = {0};
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("GetDialogBaseUnits = %08lx\n", GetDialogBaseUnits());
    metrics(dc, GetStockObject(SYSTEM_FONT), "SYSTEM_FONT");
    metrics(dc, GetStockObject(DEFAULT_GUI_FONT), "DEFAULT_GUI_FONT");
    SystemParametersInfoW(SPI_GETNONCLIENTMETRICS, sizeof(ncm), &ncm, 0);
    printf("message font: %ls height %ld\n", ncm.lfMessageFont.lfFaceName, ncm.lfMessageFont.lfHeight);
    metrics(dc, CreateFontIndirectW(&ncm.lfMessageFont), "message font");
    lstrcpyW(lf.lfFaceName, L"Tahoma"); lf.lfHeight = -11;
    metrics(dc, CreateFontIndirectW(&lf), "Tahoma");
    lf.lfFaceName[0] = 0; lf.lfCharSet = DEFAULT_CHARSET;
    EnumFontFamiliesExW(dc, &lf, fam_proc, 0, 0);
    printf("font families seen by GDI: %d\n", families);
    ReleaseDC(0, dc);
    printf("fontprobe done\n");
    return 0;
}
