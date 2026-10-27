/* d3d12probe: calls the D3D12/DXGI entry points a game uses at start-up, one per process, so a crash
 * in the graphics stack (here D3DMetal's WineMonitor::Init) can be reproduced without the game.
 * Usage: d3d12probe.exe factory|create|getinterface|monitors|features
 * features: what the device reports through CheckFeatureSupport (shader model asked from 6.9 down to
 * 6.0, feature level, binding/raytracing/mesh tiers), i.e. what a game's hardware check reads.
 * Built twice: plain, and with -DAGILITY (exports D3D12SDKVersion/D3D12SDKPath like FH6 does). */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <dxgi1_4.h>
#include <d3d12.h>

#ifdef AGILITY
__declspec(dllexport) extern const UINT D3D12SDKVersion = 614;
__declspec(dllexport) extern const char *D3D12SDKPath = ".\\D3D12\\";
#endif

typedef struct { int MeshShaderTier; int SamplerFeedbackTier; } MY_OPTIONS7; /* D3D12_FEATURE_D3D12_OPTIONS7 = 32 */
DEFINE_GUID(MY_CLSID_D3D12SDKConfiguration, 0x7cda6aca, 0xa03e, 0x49c8, 0x94, 0x58, 0x03, 0x34, 0xd2, 0x0e, 0x07, 0xce);
DEFINE_GUID(MY_IID_ID3D12SDKConfiguration, 0xe9eb5314, 0x33aa, 0x42b2, 0xa7, 0x18, 0xd7, 0x7f, 0x58, 0xb1, 0xf1, 0xc7);

static BOOL CALLBACK mon_proc(HMONITOR m, HDC dc, RECT *r, LPARAM p)
{
    printf("  monitor %p %ldx%ld\n", (void *)m, r->right - r->left, r->bottom - r->top);
    return TRUE;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "create";
    HMODULE d3d12, dxgi;
    HRESULT hr = E_FAIL;

    setvbuf(stdout, NULL, _IONBF, 0);
    printf("PROBE mode=%s agility=%d\n", mode,
#ifdef AGILITY
           1
#else
           0
#endif
    );
    if (!strcmp(mode, "monitors"))
    {
        printf("PROBE EnumDisplayMonitors -> %d\n", EnumDisplayMonitors(NULL, NULL, mon_proc, 0));
        return 0;
    }
    dxgi = LoadLibraryA("dxgi.dll");
    d3d12 = LoadLibraryA("d3d12.dll");
    printf("PROBE dxgi=%p d3d12=%p\n", (void *)dxgi, (void *)d3d12);
    if (!strcmp(mode, "factory"))
    {
        HRESULT (WINAPI *pCreateDXGIFactory2)(UINT, REFIID, void **) = (void *)GetProcAddress(dxgi, "CreateDXGIFactory2");
        IDXGIFactory4 *f = NULL; IDXGIAdapter1 *a = NULL;
        printf("PROBE calling CreateDXGIFactory2\n");
        hr = pCreateDXGIFactory2 ? pCreateDXGIFactory2(0, &IID_IDXGIFactory4, (void **)&f) : E_NOINTERFACE;
        printf("PROBE CreateDXGIFactory2 -> %08lx\n", hr);
        if (f && SUCCEEDED(IDXGIFactory4_EnumAdapters1(f, 0, &a)))
        {
            DXGI_ADAPTER_DESC1 d; IDXGIAdapter1_GetDesc1(a, &d);
            printf("PROBE adapter %ls vendor %04x device %04x\n", d.Description, d.VendorId, d.DeviceId);
        }
    }
    else if (!strcmp(mode, "getinterface"))
    {
        HRESULT (WINAPI *pD3D12GetInterface)(REFCLSID, REFIID, void **) = (void *)GetProcAddress(d3d12, "D3D12GetInterface");
        void *p = NULL;
        printf("PROBE calling D3D12GetInterface(SDKConfiguration) %p\n", (void *)pD3D12GetInterface);
        hr = pD3D12GetInterface ? pD3D12GetInterface(&MY_CLSID_D3D12SDKConfiguration, &MY_IID_ID3D12SDKConfiguration, &p) : E_NOINTERFACE;
        printf("PROBE D3D12GetInterface -> %08lx %p\n", hr, p);
    }
    else if (!strcmp(mode, "features"))
    {
        PFN_D3D12_CREATE_DEVICE pD3D12CreateDevice = (void *)GetProcAddress(d3d12, "D3D12CreateDevice");
        ID3D12Device *dev = NULL;
        D3D_FEATURE_LEVEL levels[] = { 0xc200, 0xc100, 0xc000, 0xb100, 0xb000 };
        D3D12_FEATURE_DATA_FEATURE_LEVELS fl = { 5, levels, 0 };
        D3D12_FEATURE_DATA_D3D12_OPTIONS o = {0};
        D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5 = {0};
        MY_OPTIONS7 o7 = {0};
        int sm;
        hr = pD3D12CreateDevice ? pD3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev) : E_NOINTERFACE;
        printf("PROBE D3D12CreateDevice -> %08lx\n", hr);
        if (dev)
        {
            for (sm = 0x69; sm >= 0x60; sm--)
            {
                D3D12_FEATURE_DATA_SHADER_MODEL d = { sm };
                hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_SHADER_MODEL, &d, sizeof(d));
                printf("PROBE shader model asked %x.%x -> hr %08lx highest %x.%x\n", sm >> 4, sm & 0xf, hr,
                       d.HighestShaderModel >> 4, d.HighestShaderModel & 0xf);
            }
            hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_FEATURE_LEVELS, &fl, sizeof(fl));
            printf("PROBE feature levels -> hr %08lx max %x\n", hr, fl.MaxSupportedFeatureLevel);
            hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS, &o, sizeof(o));
            printf("PROBE options -> hr %08lx binding tier %d tiled %d conservative %d\n", hr, o.ResourceBindingTier,
                   o.TiledResourcesTier, o.ConservativeRasterizationTier);
            hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof(o5));
            printf("PROBE options5 -> hr %08lx raytracing tier %d\n", hr, o5.RaytracingTier);
            hr = ID3D12Device_CheckFeatureSupport(dev, (D3D12_FEATURE)32, &o7, sizeof(o7));
            printf("PROBE options7 -> hr %08lx mesh shader tier %d sampler feedback %d\n", hr, o7.MeshShaderTier,
                   o7.SamplerFeedbackTier);
        }
    }
    else
    {
        PFN_D3D12_CREATE_DEVICE pD3D12CreateDevice = (void *)GetProcAddress(d3d12, "D3D12CreateDevice");
        ID3D12Device *dev = NULL;
        printf("PROBE calling D3D12CreateDevice %p\n", (void *)pD3D12CreateDevice);
        hr = pD3D12CreateDevice ? pD3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev) : E_NOINTERFACE;
        printf("PROBE D3D12CreateDevice -> %08lx %p\n", hr, (void *)dev);
    }
    printf("PROBE done\n");
    return 0;
}
