/* gpuprobe: everything a game can read about the GPU and its driver, so we can see why FH6 says
 * "carte graphique non prise en charge (FH205)" and "impossible de détecter la version du pilote".
 * Read-only: display devices, DXGI adapters (+ UMD version), and the display class registry keys. */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <dxgi1_4.h>

static void reg_value(HKEY k, const WCHAR *name)
{
    WCHAR buf[512]; DWORD type, size = sizeof(buf);
    if (RegQueryValueExW(k, name, NULL, &type, (BYTE *)buf, &size)) return;
    if (type == REG_SZ || type == REG_MULTI_SZ) printf("    %ls = %ls\n", name, buf);
    else if (type == REG_DWORD) printf("    %ls = 0x%lx\n", name, *(DWORD *)buf);
    else if (type == REG_QWORD) printf("    %ls = 0x%llx\n", name, *(ULONGLONG *)buf);
    else printf("    %ls (type %lu, %lu bytes)\n", name, type, size);
}

int main(void)
{
    DISPLAY_DEVICEW dd = { sizeof(dd) };
    IDXGIFactory1 *f = NULL; IDXGIAdapter1 *a;
    HRESULT (WINAPI *pCreateDXGIFactory1)(REFIID, void **);
    DWORD i;
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("== EnumDisplayDevices\n");
    for (i = 0; EnumDisplayDevicesW(NULL, i, &dd, 0); i++)
        printf("  %ls | %ls | %ls | flags %lx\n", dd.DeviceName, dd.DeviceString, dd.DeviceID, dd.StateFlags);

    printf("== DXGI adapters\n");
    pCreateDXGIFactory1 = (void *)GetProcAddress(LoadLibraryA("dxgi.dll"), "CreateDXGIFactory1");
    if (pCreateDXGIFactory1 && SUCCEEDED(pCreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&f)))
        for (i = 0; SUCCEEDED(IDXGIFactory1_EnumAdapters1(f, i, &a)); i++)
        {
            DXGI_ADAPTER_DESC1 d; LARGE_INTEGER umd = {{0}}; HRESULT hr;
            IDXGIAdapter1_GetDesc1(a, &d);
            hr = IDXGIAdapter1_CheckInterfaceSupport(a, &IID_IDXGIDevice, &umd);
            printf("  %ls vendor %04x device %04x subsys %08x rev %x vram %llu MB flags %x\n", d.Description,
                   d.VendorId, d.DeviceId, d.SubSysId, d.Revision, (ULONGLONG)d.DedicatedVideoMemory >> 20, d.Flags);
            printf("  CheckInterfaceSupport -> %08lx driver %u.%u.%u.%u\n", hr, HIWORD(umd.HighPart),
                   LOWORD(umd.HighPart), HIWORD(umd.LowPart), LOWORD(umd.LowPart));
        }
    else printf("  CreateDXGIFactory1 failed\n");

    printf("== registry display class\n");
    for (i = 0; i < 4; i++)
    {
        WCHAR path[200]; HKEY k;
        swprintf(path, 200, L"SYSTEM\\CurrentControlSet\\Control\\Class\\{4d36e968-e325-11ce-bfc1-08002be10318}\\%04u", i);
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, path, 0, KEY_READ, &k)) continue;
        printf("  %04lu\n", i);
        reg_value(k, L"DriverDesc"); reg_value(k, L"DriverVersion"); reg_value(k, L"DriverDate");
        reg_value(k, L"ProviderName"); reg_value(k, L"MatchingDeviceId");
        reg_value(k, L"HardwareInformation.AdapterString"); reg_value(k, L"HardwareInformation.qwMemorySize");
        RegCloseKey(k);
    }
    printf("gpuprobe done\n");
    return 0;
}
