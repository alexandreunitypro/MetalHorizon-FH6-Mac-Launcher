// tsshim: a d3d12.dll that sits in front of D3DMetal's and serves DirectX 12 timestamp queries.
//
// D3DMetal 3.0 has no timestamp queries: CreateQueryHeap hands back a heap, then EndQuery and
// ResolveQueryData for query type 2 log a refusal and do nothing, so a game that times its
// frames reads garbage and crashes (Guardians of the Galaxy, highball #63). This proxy loads
// the real D3DMetal d3d12.dll (HB_D3D12_REAL, a Windows path), forwards everything, and after
// D3D12CreateDevice patches four vtable slots: the device's CreateQueryHeap answers timestamp
// heaps itself, the command list's EndQuery stamps the CPU clock into that heap, its
// ResolveQueryData copies the stamps into the destination buffer through an upload ring, and
// the queue reports the CPU clock's frequency. Everything else is D3DMetal untouched.
//
// Two more gaps are closed the same way (both found on D3DMetal 4.0b2 with Forza Horizon 6,
// 2026-10-05, see the hooks for the measurements):
// - CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL) with a shader model D3DMetal does not know
//   returns E_INVALIDARG where a current Windows runtime answers with the highest model it
//   supports. The hook asks again with lower values and returns that answer.
// - ResolveSubresource from a multisampled depth texture into a colour texture ends in a Metal
//   assertion that aborts the thread. The hook drops the call (HB_TSSHIM_DEPTHRESOLVE=1 lets it
//   through, for a D3DMetal that has learned to do it).
//
// And one wrong result (D3DMetal 4.0b2 and 4.0b3, Forza Horizon 6, 2026-10-20):
// - Input layouts that place elements with D3D12_APPEND_ALIGNED_ELEMENT get them at the wrong
//   offsets, so a vertex shader reads another attribute's bytes. Pipelines are handed to D3DMetal
//   with those offsets written out explicitly, as D3D12's rules give them (HB_TSSHIM_APPEND_OFFSETS=0
//   passes the layouts through as the game wrote them).
//
// And one missing translation (D3DMetal 4.0b3, Forza Horizon 6, 2026-10-24):
// - A pixel shader that reads SV_ShadingRate gets a pipeline Metal refuses, so D3DMetal draws nothing
//   with it. Such shaders are handed over with that input read as SV_ViewportArrayIndex, which is 0 here,
//   the value SV_ShadingRate has on a device without variable rate shading (dxil_shadingrate.c;
//   HB_TSSHIM_SHADINGRATE=0 passes them through unchanged).
//
// And one setting D3DMetal reads where D3D12 does not (D3DMetal 4.0b3, Forza Horizon 6, 2026-10-25):
// - Render target 0's blend description makes D3DMetal compile the pixel shader for dual-source blending
//   even in a pipeline without render targets, and that compile fails. There, where D3D12 never blends,
//   the blend is handed over switched off (HB_TSSHIM_UNUSED_BLEND=0 passes it through).
//
// HB_TSSHIM_INSPECT=1 logs what the game creates and where each draw's pixels go (inspect.c, for tools/mac_fh6_inspect.sh).
//
// HB_TSSHIM_DUMP=1 writes every graphics pipeline's vertex and pixel shader to C:\highball\shaders, as the
// game gave them, and their pairs to pairs-<pid>.txt, for tools/dxilbench.
//
// Build: x86_64-w64-mingw32-gcc -shared -O2 -Wall -static-libgcc -o d3d12.dll d3d12.c dxil_shadingrate.c inspect.c d3d12.def
// then stamp the "Wine builtin DLL" marker so WINEDLLPATH_PREPEND picks it up.
#define INITGUID
#include <windows.h>
#include <initguid.h>
#include <d3d12.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "dxil_shadingrate.h"
#include "inspect.h"

static HMODULE real_dll;
static HINSTANCE self;
static int dbg, idle;
static UINT64 qpc_freq;
// Debug lines go to a file: a GUI-subsystem game started by Steam has no stderr handle on the
// Windows side, so fprintf(stderr) vanished (The Last Caretaker, 2026-09-19). C:\highball\logs is
// where Highball keeps the renderers' own logs inside the bottle.
static FILE *dbg_file;
static FILE *dbg_out(void)
{
    if (!dbg_file) {
        char path[MAX_PATH]; snprintf(path, sizeof path, "C:\\highball\\logs\\tsshim-%lu.log", (unsigned long)GetCurrentProcessId());
        dbg_file = fopen(path, "a");
        if (!dbg_file) dbg_file = stderr;
    }
    return dbg_file;
}
static CRITICAL_SECTION log_lock; static int log_lock_ready;
#define LOG(...) do { if (dbg) { if (!log_lock_ready) { InitializeCriticalSection(&log_lock); log_lock_ready = 1; } \
    EnterCriticalSection(&log_lock); FILE *f_ = dbg_out(); SYSTEMTIME st_; GetLocalTime(&st_); \
    fprintf(f_, "%02u:%02u:%02u.%03u tsshim[%lu]: ", st_.wHour, st_.wMinute, st_.wSecond, st_.wMilliseconds, (unsigned long)GetCurrentThreadId()); fprintf(f_, __VA_ARGS__); fputc('\n', f_); fflush(f_); LeaveCriticalSection(&log_lock); } } while (0)

// Wine tells builtin modules apart by name (the file name on Wine 10, the PE's internal export name
// on CrossOver's Wine 11), so a second "d3d12.dll" at another path comes back as this shim. Highball
// lays the real one out beside the shim as apd12.dll, export name patched to match, with its Mach-O
// half as x86_64-unix/apd12.so (InstalledEngine.timestampShimDir), and passes the path in
// HB_D3D12_REAL. The bare-name fallback below is for experiments only.
static HMODULE load_real(void)
{
    WCHAR path[1024];
    DWORD n;
    if (real_dll) return real_dll;
    n = GetEnvironmentVariableW(L"HB_D3D12_REAL", path, 1024);
    if (n && n < 1024) real_dll = LoadLibraryW(path);
    else real_dll = LoadLibraryW(L"d3d12_d3dmetal.dll");
    if (real_dll == self) { fprintf(stderr, "tsshim: the real d3d12.dll resolved to the shim itself\n"); real_dll = NULL; }
    if (!real_dll) fprintf(stderr, "tsshim: cannot load the real D3DMetal d3d12.dll (%ls, error %lu)\n", n ? path : L"d3d12_d3dmetal.dll", GetLastError());
    return real_dll;
}

// Forwarded exports: a jump through a pointer resolved at load, so no signature is guessed.
#define FORWARD(name) \
    static void *p_##name __attribute__((used)); \
    __asm__(".text\n.globl " #name "\n" #name ":\n\tjmp *p_" #name "(%rip)\n");
FORWARD(D3D12CoreCreateLayeredDevice)
FORWARD(D3D12CoreGetLayeredDeviceSize)
FORWARD(D3D12CoreRegisterLayers)
FORWARD(D3D12CreateRootSignatureDeserializer)
FORWARD(D3D12CreateVersionedRootSignatureDeserializer)
FORWARD(D3D12EnableExperimentalFeatures)
FORWARD(D3D12GetDebugInterface)
FORWARD(D3D12SerializeRootSignature)
FORWARD(D3D12SerializeVersionedRootSignature)
FORWARD(GetBehaviorValue)
#define RESOLVE(name) do { p_##name = (void *)GetProcAddress(real_dll, #name); if (!p_##name) LOG("real d3d12.dll lacks %s", #name); } while (0)

// ---- the fake timestamp query heap -------------------------------------------------------

typedef struct FakeHeap {
    const ID3D12QueryHeapVtbl *lpVtbl;
    LONG ref;
    UINT count;
    UINT64 *values;
    ID3D12Device *device;
} FakeHeap;

static const ID3D12QueryHeapVtbl fake_heap_vtbl;
static int is_fake(ID3D12QueryHeap *h) { return h && h->lpVtbl == &fake_heap_vtbl; }

static HRESULT STDMETHODCALLTYPE fh_QueryInterface(ID3D12QueryHeap *iface, REFIID riid, void **out)
{
    if (!out) return E_POINTER;
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_ID3D12Object) || IsEqualGUID(riid, &IID_ID3D12DeviceChild)
        || IsEqualGUID(riid, &IID_ID3D12Pageable) || IsEqualGUID(riid, &IID_ID3D12QueryHeap)) {
        InterlockedIncrement(&((FakeHeap *)iface)->ref); *out = iface; return S_OK;
    }
    *out = NULL; return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE fh_AddRef(ID3D12QueryHeap *iface) { return InterlockedIncrement(&((FakeHeap *)iface)->ref); }
static ULONG STDMETHODCALLTYPE fh_Release(ID3D12QueryHeap *iface)
{
    FakeHeap *h = (FakeHeap *)iface; ULONG r = InterlockedDecrement(&h->ref);
    if (!r) { h->device->lpVtbl->Release(h->device); free(h->values); free(h); }
    return r;
}
static HRESULT STDMETHODCALLTYPE fh_GetPrivateData(ID3D12QueryHeap *iface, REFGUID guid, UINT *size, void *data) { if (size) *size = 0; return (HRESULT)0x887A0002L; /* DXGI_ERROR_NOT_FOUND */ }
static HRESULT STDMETHODCALLTYPE fh_SetPrivateData(ID3D12QueryHeap *iface, REFGUID guid, UINT size, const void *data) { return S_OK; }
static HRESULT STDMETHODCALLTYPE fh_SetPrivateDataInterface(ID3D12QueryHeap *iface, REFGUID guid, const IUnknown *data) { return S_OK; }
static HRESULT STDMETHODCALLTYPE fh_SetName(ID3D12QueryHeap *iface, LPCWSTR name) { return S_OK; }
static HRESULT STDMETHODCALLTYPE fh_GetDevice(ID3D12QueryHeap *iface, REFIID riid, void **out)
{
    FakeHeap *h = (FakeHeap *)iface; return h->device->lpVtbl->QueryInterface(h->device, riid, out);
}
static const ID3D12QueryHeapVtbl fake_heap_vtbl = {
    fh_QueryInterface, fh_AddRef, fh_Release, fh_GetPrivateData, fh_SetPrivateData, fh_SetPrivateDataInterface, fh_SetName, fh_GetDevice
};

// ---- the upload ring the stamps travel through ---------------------------------------------

#define RING_BYTES (8u << 20)
typedef struct Ring { ID3D12Device *device; ID3D12Resource *buffer; UINT8 *cpu; volatile LONG64 cursor; } Ring;
static Ring rings[4];
static CRITICAL_SECTION ring_lock;

static Ring *ring_for(ID3D12Device *dev)
{
    Ring *r = NULL; int i;
    EnterCriticalSection(&ring_lock);
    for (i = 0; i < 4 && !r; i++) if (rings[i].device == dev) r = &rings[i];
    for (i = 0; i < 4 && !r; i++) if (!rings[i].device) {
        D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_UPLOAD, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 0, 0 };
        D3D12_RESOURCE_DESC rd = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, RING_BYTES, 1, 1, 1, DXGI_FORMAT_UNKNOWN, { 1, 0 }, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE };
        ID3D12Resource *buf = NULL; void *cpu = NULL;
        if (SUCCEEDED(dev->lpVtbl->CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_GENERIC_READ, NULL, &IID_ID3D12Resource, (void **)&buf))
            && SUCCEEDED(buf->lpVtbl->Map(buf, 0, NULL, &cpu))) {
            rings[i].device = dev; dev->lpVtbl->AddRef(dev);
            rings[i].buffer = buf; rings[i].cpu = cpu; rings[i].cursor = 0; r = &rings[i];
            LOG("upload ring of %u bytes created", RING_BYTES);
        } else { if (buf) buf->lpVtbl->Release(buf); LOG("upload ring creation failed"); }
        break;
    }
    LeaveCriticalSection(&ring_lock);
    return r;
}

static UINT64 now_ticks(void) { LARGE_INTEGER c; QueryPerformanceCounter(&c); return (UINT64)c.QuadPart; }

// ---- the hooks -----------------------------------------------------------------------------

typedef HRESULT (STDMETHODCALLTYPE *PFN_CreateQueryHeap)(ID3D12Device *, const D3D12_QUERY_HEAP_DESC *, REFIID, void **);
typedef void (STDMETHODCALLTYPE *PFN_Query)(ID3D12GraphicsCommandList *, ID3D12QueryHeap *, D3D12_QUERY_TYPE, UINT);
typedef void (STDMETHODCALLTYPE *PFN_ResolveQueryData)(ID3D12GraphicsCommandList *, ID3D12QueryHeap *, D3D12_QUERY_TYPE, UINT, UINT, ID3D12Resource *, UINT64);
typedef HRESULT (STDMETHODCALLTYPE *PFN_GetTimestampFrequency)(ID3D12CommandQueue *, UINT64 *);
typedef HRESULT (STDMETHODCALLTYPE *PFN_GetClockCalibration)(ID3D12CommandQueue *, UINT64 *, UINT64 *);
static PFN_CreateQueryHeap real_CreateQueryHeap;
static PFN_Query real_EndQuery, real_BeginQuery;
static PFN_ResolveQueryData real_ResolveQueryData;
static PFN_GetTimestampFrequency real_GetTimestampFrequency;
static PFN_GetClockCalibration real_GetClockCalibration;

static HRESULT STDMETHODCALLTYPE hook_CreateQueryHeap(ID3D12Device *dev, const D3D12_QUERY_HEAP_DESC *desc, REFIID riid, void **out)
{
    FakeHeap *h; HRESULT hr;
    if (!desc || (desc->Type != D3D12_QUERY_HEAP_TYPE_TIMESTAMP && desc->Type != D3D12_QUERY_HEAP_TYPE_COPY_QUEUE_TIMESTAMP))
        return real_CreateQueryHeap(dev, desc, riid, out);
    if (!out) return S_FALSE;
    h = calloc(1, sizeof *h); if (!h) return E_OUTOFMEMORY;
    h->lpVtbl = &fake_heap_vtbl; h->ref = 1; h->count = desc->Count;
    h->values = calloc(desc->Count ? desc->Count : 1, sizeof(UINT64));
    h->device = dev; dev->lpVtbl->AddRef(dev);
    hr = fh_QueryInterface((ID3D12QueryHeap *)h, riid, out);
    fh_Release((ID3D12QueryHeap *)h);
    LOG("timestamp query heap of %u entries served by the shim (hr 0x%08lx)", desc->Count, (unsigned long)hr);
    return hr;
}

static void STDMETHODCALLTYPE hook_EndQuery(ID3D12GraphicsCommandList *list, ID3D12QueryHeap *heap, D3D12_QUERY_TYPE type, UINT index)
{
    FakeHeap *h;
    if (!is_fake(heap)) { inspect_game_query(list, heap, type, FALSE); real_EndQuery(list, heap, type, index); return; }
    h = (FakeHeap *)heap; if (index < h->count) h->values[index] = now_ticks();
}

static void STDMETHODCALLTYPE hook_BeginQuery(ID3D12GraphicsCommandList *list, ID3D12QueryHeap *heap, D3D12_QUERY_TYPE type, UINT index)
{
    if (!is_fake(heap)) { inspect_game_query(list, heap, type, TRUE); real_BeginQuery(list, heap, type, index); }
}

static void STDMETHODCALLTYPE hook_ResolveQueryData(ID3D12GraphicsCommandList *list, ID3D12QueryHeap *heap, D3D12_QUERY_TYPE type,
                                                    UINT start, UINT count, ID3D12Resource *dst, UINT64 offset)
{
    FakeHeap *h; Ring *r; UINT64 bytes, off; LONG64 pos; int tries;
    if (!is_fake(heap)) { real_ResolveQueryData(list, heap, type, start, count, dst, offset); return; }
    h = (FakeHeap *)heap; r = ring_for(h->device);
    if (!r || !dst || !count || start >= h->count) return;
    if (start + count > h->count) count = h->count - start;
    bytes = (UINT64)count * 8; if (bytes > RING_BYTES / 2) return;
    for (tries = 0; tries < 2; tries++) {
        pos = InterlockedExchangeAdd64(&r->cursor, (LONG64)bytes); off = (UINT64)pos % RING_BYTES;
        if (off + bytes <= RING_BYTES) break;
        InterlockedExchangeAdd64(&r->cursor, (LONG64)(RING_BYTES - off));   // skip the tail, start over
    }
    if (tries == 2) return;
    memcpy(r->cpu + off, h->values + start, (size_t)bytes);
    list->lpVtbl->CopyBufferRegion(list, dst, offset, r->buffer, off, bytes);
}

static HRESULT STDMETHODCALLTYPE hook_GetTimestampFrequency(ID3D12CommandQueue *q, UINT64 *f)
{
    if (!f) return E_INVALIDARG;
    *f = qpc_freq; return S_OK;
}
static HRESULT STDMETHODCALLTYPE hook_GetClockCalibration(ID3D12CommandQueue *q, UINT64 *gpu, UINT64 *cpu)
{
    UINT64 t = now_ticks(); if (gpu) *gpu = t; if (cpu) *cpu = t; return S_OK;
}

// ---- patching ------------------------------------------------------------------------------

void patch_slot(void **slot, void *hook, void **saved)
{
    DWORD old;
    if (*slot == hook) return;
    // D3DMetal's vtables live in its framework's __DATA segment on the Mach-O side: writable, but
    // outside Wine's view of memory, so VirtualProtect refuses the address. Try it for the PE case,
    // then write regardless (verified on D3DMetal 3.0 with Wine 10 and 11, 2026-09-07).
    if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &old)) old = 0;
    if (!*saved) *saved = *slot;
    *slot = hook;
    if (old) VirtualProtect(slot, sizeof(void *), old, &old);
}

// Diagnostic only (HB_TSSHIM_DEBUG): log each resource the game creates, so a Metal assertion
// such as "MTLTextureDescriptor has invalid pixelFormat (0)" (The Last Caretaker, 2026-09-19)
// can be tied to the DXGI format D3DMetal failed to map. Forwarded untouched otherwise.
static HRESULT (STDMETHODCALLTYPE *real_CreateCommittedResource)(ID3D12Device *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreatePlacedResource)(ID3D12Device *, ID3D12Heap *, UINT64, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);
static void log_resource(const char *what, const D3D12_RESOURCE_DESC *d, HRESULT hr)
{
    if (!d || d->Dimension == D3D12_RESOURCE_DIMENSION_BUFFER) return;
    LOG("%s dim=%d format=%u %llux%u depth/array=%u mips=%u samples=%u flags=0x%x hr=0x%lx", what, (int)d->Dimension, (unsigned)d->Format,
        (unsigned long long)d->Width, (unsigned)d->Height, (unsigned)d->DepthOrArraySize, (unsigned)d->MipLevels, (unsigned)d->SampleDesc.Count, (unsigned)d->Flags, (unsigned long)hr);
}
static HRESULT STDMETHODCALLTYPE hook_CreateCommittedResource(ID3D12Device *dev, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_STATES st, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out)
{
    if (dbg) { log_resource("CreateCommittedResource begin", d, 0); }
    HRESULT hr = real_CreateCommittedResource(dev, hp, hf, d, st, cv, riid, out);
    if (dbg) { log_resource("CreateCommittedResource done", d, hr); if (d && d->Dimension != D3D12_RESOURCE_DIMENSION_BUFFER) LOG("  -> res=%p", out ? *out : NULL); }
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreatePlacedResource(ID3D12Device *dev, ID3D12Heap *heap, UINT64 off, const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_STATES st, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out)
{
    if (dbg) { log_resource("CreatePlacedResource begin", d, 0); }
    HRESULT hr = real_CreatePlacedResource(dev, heap, off, d, st, cv, riid, out);
    if (dbg) { log_resource("CreatePlacedResource done", d, hr); if (d && d->Dimension != D3D12_RESOURCE_DIMENSION_BUFFER) LOG("  -> res=%p", out ? *out : NULL); }
    return hr;
}
static HRESULT (STDMETHODCALLTYPE *real_CreateReservedResource)(ID3D12Device *, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);
static HRESULT STDMETHODCALLTYPE hook_CreateReservedResource(ID3D12Device *dev, const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_STATES st, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out)
{
    if (dbg) { log_resource("CreateReservedResource begin", d, 0); }
    HRESULT hr = real_CreateReservedResource(dev, d, st, cv, riid, out);
    if (dbg) { log_resource("CreateReservedResource done", d, hr); if (d && d->Dimension != D3D12_RESOURCE_DIMENSION_BUFFER) LOG("  -> res=%p", out ? *out : NULL); }
    return hr;
}
// Views: a cast over a typeless texture is where a format D3DMetal cannot map would surface.
static void (STDMETHODCALLTYPE *real_CreateShaderResourceView)(ID3D12Device *, ID3D12Resource *, const D3D12_SHADER_RESOURCE_VIEW_DESC *, D3D12_CPU_DESCRIPTOR_HANDLE);
static void (STDMETHODCALLTYPE *real_CreateUnorderedAccessView)(ID3D12Device *, ID3D12Resource *, ID3D12Resource *, const D3D12_UNORDERED_ACCESS_VIEW_DESC *, D3D12_CPU_DESCRIPTOR_HANDLE);
static void (STDMETHODCALLTYPE *real_CreateRenderTargetView)(ID3D12Device *, ID3D12Resource *, const D3D12_RENDER_TARGET_VIEW_DESC *, D3D12_CPU_DESCRIPTOR_HANDLE);
static void (STDMETHODCALLTYPE *real_CreateDepthStencilView)(ID3D12Device *, ID3D12Resource *, const D3D12_DEPTH_STENCIL_VIEW_DESC *, D3D12_CPU_DESCRIPTOR_HANDLE);
static void STDMETHODCALLTYPE hook_CreateShaderResourceView(ID3D12Device *dev, ID3D12Resource *res, const D3D12_SHADER_RESOURCE_VIEW_DESC *d, D3D12_CPU_DESCRIPTOR_HANDLE h)
{
    if (dbg && d) LOG("SRV begin res=%p format=%u viewdim=%d", res, (unsigned)d->Format, (int)d->ViewDimension);
    real_CreateShaderResourceView(dev, res, d, h);
    if (dbg && d) LOG("SRV done res=%p", res);
}
static void STDMETHODCALLTYPE hook_CreateUnorderedAccessView(ID3D12Device *dev, ID3D12Resource *res, ID3D12Resource *counter, const D3D12_UNORDERED_ACCESS_VIEW_DESC *d, D3D12_CPU_DESCRIPTOR_HANDLE h)
{
    if (dbg && d) LOG("UAV begin res=%p format=%u viewdim=%d", res, (unsigned)d->Format, (int)d->ViewDimension);
    real_CreateUnorderedAccessView(dev, res, counter, d, h);
    if (dbg && d) LOG("UAV done res=%p", res);
}
static void STDMETHODCALLTYPE hook_CreateRenderTargetView(ID3D12Device *dev, ID3D12Resource *res, const D3D12_RENDER_TARGET_VIEW_DESC *d, D3D12_CPU_DESCRIPTOR_HANDLE h)
{
    if (dbg && d) LOG("RTV begin res=%p format=%u viewdim=%d", res, (unsigned)d->Format, (int)d->ViewDimension);
    real_CreateRenderTargetView(dev, res, d, h);
    if (dbg && d) LOG("RTV done res=%p", res);
}
static void STDMETHODCALLTYPE hook_CreateDepthStencilView(ID3D12Device *dev, ID3D12Resource *res, const D3D12_DEPTH_STENCIL_VIEW_DESC *d, D3D12_CPU_DESCRIPTOR_HANDLE h)
{
    if (dbg && d) LOG("DSV begin res=%p format=%u viewdim=%d", res, (unsigned)d->Format, (int)d->ViewDimension);
    real_CreateDepthStencilView(dev, res, d, h);
    if (dbg && d) LOG("DSV done res=%p", res);
}

// ---- feature queries -------------------------------------------------------------------------

// A program asks for the highest shader model it understands and the runtime answers with the
// highest one it supports at or below that. D3DMetal only accepts the values it knows (up to 0x68,
// SM 6.8, on 4.0b2, answering 0x66) and returns E_INVALIDARG for a newer one, which a program built
// against a newer SDK takes as "no usable shader model": Forza Horizon 6's 461.691 build asks with
// 0x6a and stopped at "Your graphics card is not supported (FH206)" (M4, macOS 27.0, D3DMetal 4.0b2).
// The Windows runtime the game ships knows its own enum, so on Windows the question never fails.
//
// OPTIONS11, 64-bit atomics on descriptor heap resources: D3DMetal 3 answers no on an M1 Pro, and
// Capcom's RE Engine then refuses the adapter ("unsupported graphics card", the Onimusha: Way of
// the Sword demo, highball-db#450, and Kunitsu-Gami). A player who patched D3DMetal to answer yes
// ran the Onimusha demo through its benchmark at 32 fps, so the game does not need the feature to
// draw. HB_TSSHIM_ATOMIC64=1, set only by such a game's fix, makes the shim answer yes; nothing
// else changes, and without the variable the answer is D3DMetal's.
static int claim_atomic64;
static HRESULT (STDMETHODCALLTYPE *real_CheckFeatureSupport)(ID3D12Device *, D3D12_FEATURE, void *, UINT);
static HRESULT STDMETHODCALLTYPE hook_CheckFeatureSupport(ID3D12Device *dev, D3D12_FEATURE feature, void *data, UINT size)
{
    HRESULT hr = real_CheckFeatureSupport(dev, feature, data, size);
    if (feature == D3D12_FEATURE_SHADER_MODEL && hr == E_INVALIDARG && data && size >= sizeof(D3D12_FEATURE_DATA_SHADER_MODEL)) {
        D3D12_FEATURE_DATA_SHADER_MODEL *sm = data;
        UINT asked = sm->HighestShaderModel, v;
        for (v = asked - 1; v >= D3D_SHADER_MODEL_6_0 && v < asked; v--) {
            sm->HighestShaderModel = v;
            if (SUCCEEDED(hr = real_CheckFeatureSupport(dev, feature, data, size))) break;
        }
        if (FAILED(hr)) sm->HighestShaderModel = asked;
        LOG("shader model query for 0x%x answered as 0x%x (hr 0x%08lx)", asked, (unsigned)sm->HighestShaderModel, (unsigned long)hr);
    } else if (feature == D3D12_FEATURE_D3D12_OPTIONS11 && claim_atomic64 && SUCCEEDED(hr) && data
               && size >= sizeof(D3D12_FEATURE_DATA_D3D12_OPTIONS11)) {
        D3D12_FEATURE_DATA_D3D12_OPTIONS11 *o = data;
        if (!o->AtomicInt64OnDescriptorHeapResourceSupported) LOG("OPTIONS11: answering yes to 64-bit atomics on descriptor heap resources (HB_TSSHIM_ATOMIC64)");
        o->AtomicInt64OnDescriptorHeapResourceSupported = TRUE;
    } else if (dbg) LOG("CheckFeatureSupport feature=%d size=%u hr=0x%08lx", (int)feature, size, (unsigned long)hr);
    return hr;
}

// ---- depth resolve ---------------------------------------------------------------------------

// ResolveSubresource(colour texture, multisampled depth texture, R32_FLOAT): Windows drivers take
// it. D3DMetal 4.0b2 builds a Metal texture view of the source in the destination's format, and
// Metal has no cast between depth and colour formats:
//   _mtlValidateArgumentsForTextureViewOnDevice: failed assertion `Texture Creation
//   source texture pixelFormat (MTLPixelFormatDepth32Float) not compatible with texture view
//   pixelFormat (MTLPixelFormatR32Float)'
// The assertion aborts D3DMetal's thread with the game's locks held, so the game stands still for
// good. Forza Horizon 6 issues the call every frame in its Character Select scene (960x544, 4
// samples) and froze there on every load; with the call dropped the scene draws and the game goes
// on (820 calls dropped in 36 s, M4, macOS 27.0). The destination keeps whatever it held, so an
// effect that reads it may be off; nothing visible in that scene.
static int pass_depth_resolve;
static void (STDMETHODCALLTYPE *real_ResolveSubresource)(ID3D12GraphicsCommandList *, ID3D12Resource *, UINT, ID3D12Resource *, UINT, DXGI_FORMAT);
static int is_depth_texture(ID3D12Resource *res, D3D12_RESOURCE_DESC *d)
{
    memset(d, 0, sizeof *d);
    if (!res) return 0;
    res->lpVtbl->GetDesc(res, d);
    return d->Dimension != D3D12_RESOURCE_DIMENSION_BUFFER && (d->Flags & D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL) != 0;
}
static void STDMETHODCALLTYPE hook_ResolveSubresource(ID3D12GraphicsCommandList *list, ID3D12Resource *dst, UINT dst_sub, ID3D12Resource *src, UINT src_sub, DXGI_FORMAT format)
{
    D3D12_RESOURCE_DESC dd, sd;
    if (!pass_depth_resolve && is_depth_texture(src, &sd) && sd.SampleDesc.Count > 1 && !is_depth_texture(dst, &dd)) {
        static LONG told;
        if (!InterlockedExchange(&told, 1))
            LOG("multisampled depth resolve into a colour texture dropped (source format %u, %u samples, destination format %u %llux%u, format %u)",
                (unsigned)sd.Format, (unsigned)sd.SampleDesc.Count, (unsigned)dd.Format, (unsigned long long)dd.Width, (unsigned)dd.Height, (unsigned)format);
        return;
    }
    real_ResolveSubresource(list, dst, dst_sub, src, src_sub, format);
}

// ---- input layouts ---------------------------------------------------------------------------

// D3D12_APPEND_ALIGNED_ELEMENT puts an element directly after the previous element of the same input
// slot, in declaration order, aligned to the smaller of 4 bytes and its own size. D3DMetal (4.0b2 and
// 4.0b3) places such elements elsewhere. Forza Horizon 6 draws its livery vinyls with a slot of nine
// appended elements (NORMAL R16G16_SNORM, TEXCOORD0-3 R16G16_UNORM, TANGENT0-2 R10G10B10A2_UNORM,
// COLOR0 R8G8B8A8_UNORM, stride 36) of which the vertex shader reads TEXCOORD0 and COLOR0: the vinyl
// meshes carry COLOR alpha 255 at every vertex, yet the shapes came out as gradients from 0 to 1 across
// each quad, the finished livery had alpha 0.25 to 0.7 inside solid shapes, and a liveried car showed
// mostly its base paint; the vinyl picker's shape thumbnails were gradients too. Other meshes read
// shifted normals and tangents (blotchy, faceted reflections on factory paint) and the trees' wind
// data. With the offsets written out the livery reaches alpha 1 and the car, the thumbnails, the
// reflections and the trees draw right (M4 Max, macOS 27.0.1, D3DMetal 4.0b3). Equivalent by D3D12's
// rules, so it is applied to every pipeline; HB_TSSHIM_APPEND_OFFSETS=0 turns it off.
static int keep_append_offsets;
static UINT vertex_format_size(DXGI_FORMAT f)
{
    if (f >= DXGI_FORMAT_R32G32B32A32_TYPELESS && f <= DXGI_FORMAT_R32G32B32A32_SINT) return 16;
    if (f >= DXGI_FORMAT_R32G32B32_TYPELESS && f <= DXGI_FORMAT_R32G32B32_SINT) return 12;
    if (f >= DXGI_FORMAT_R16G16B16A16_TYPELESS && f <= DXGI_FORMAT_X32_TYPELESS_G8X24_UINT) return 8;
    if (f >= DXGI_FORMAT_R10G10B10A2_TYPELESS && f <= DXGI_FORMAT_X24_TYPELESS_G8_UINT) return 4;
    if (f >= DXGI_FORMAT_R8G8_TYPELESS && f <= DXGI_FORMAT_R16_SINT) return 2;
    if (f >= DXGI_FORMAT_R8_TYPELESS && f <= DXGI_FORMAT_A8_UNORM) return 1;
    if (f == DXGI_FORMAT_B5G6R5_UNORM || f == DXGI_FORMAT_B5G5R5A1_UNORM || f == DXGI_FORMAT_B4G4R4A4_UNORM) return 2;
    if (f >= DXGI_FORMAT_B8G8R8A8_UNORM && f <= DXGI_FORMAT_B8G8R8X8_UNORM_SRGB) return 4;
    return 0;
}
// Writes the layout with every appended offset resolved into out (room for in->NumElements); returns
// FALSE when nothing was appended or an element's format is one this table does not size.
static BOOL resolve_append_offsets(const D3D12_INPUT_LAYOUT_DESC *in, D3D12_INPUT_ELEMENT_DESC *out)
{
    UINT end[D3D12_IA_VERTEX_INPUT_RESOURCE_SLOT_COUNT] = { 0 }, i; BOOL appended = FALSE;
    if (keep_append_offsets || !in || !in->pInputElementDescs || !in->NumElements
        || in->NumElements > D3D12_IA_VERTEX_INPUT_STRUCTURE_ELEMENT_COUNT) return FALSE;
    for (i = 0; i < in->NumElements; i++) {
        D3D12_INPUT_ELEMENT_DESC e = in->pInputElementDescs[i]; UINT size = vertex_format_size(e.Format);
        if (!size || e.InputSlot >= D3D12_IA_VERTEX_INPUT_RESOURCE_SLOT_COUNT) return FALSE;
        if (e.AlignedByteOffset == D3D12_APPEND_ALIGNED_ELEMENT) {
            UINT align = size < 4 ? size : 4;
            e.AlignedByteOffset = (end[e.InputSlot] + align - 1) / align * align;
            appended = TRUE;
        }
        end[e.InputSlot] = e.AlignedByteOffset + size;
        out[i] = e;
    }
    if (appended) {
        static LONG told;
        if (!InterlockedExchange(&told, 1)) LOG("input layouts with appended elements are given explicit offsets");
    }
    return appended;
}

// ---- pixel shaders reading SV_ShadingRate -------------------------------------------------------

// The Metal shader converter in D3DMetal 4.0b3 has no mapping for a pixel shader's SV_ShadingRate input and
// makes it a varying, user(sv_shadingrate0), that no vertex shader writes; Metal refuses the pipeline
// ("Fragment input(s) `user(sv_shadingrate0)` mismatching vertex shader output type(s) or not written by
// vertex shader") and D3DMetal marks it no-op, so its draws vanish. Forza Horizon 6 lost 148 pipelines that
// way in a drive through the open world, all on one vertex shader with 50 pixel shaders (M5 Pro, macOS 27.0.1).
// D3DMetal reports no variable rate shading (OPTIONS6 tier 0), where the input reads D3D12_SHADING_RATE_1X1,
// 0, so the input is handed to D3DMetal as SV_ViewportArrayIndex, which Metal supplies itself and which is 0
// when the vertex shader does not write one (dxil_shadingrate.c; tools/dxilbench reproduces the refusal and
// checks the fixed shader reads 0). HB_TSSHIM_SHADINGRATE=0 turns it off.
static int keep_shadingrate;
static LONG shadingrate_fixed;
static BOOL fix_shadingrate(const D3D12_SHADER_BYTECODE *b, void **copy)
{
    char why[128]; unsigned char *buf; int r; LONG n;
    *copy = NULL;
    if (keep_shadingrate || !b->pShaderBytecode || b->BytecodeLength < 32 || !dxil_reads_shadingrate(b->pShaderBytecode, b->BytecodeLength))
        return FALSE;
    if (!(buf = malloc(b->BytecodeLength))) return FALSE;
    memcpy(buf, b->pShaderBytecode, b->BytecodeLength);
    r = dxil_fix_shadingrate_input(buf, b->BytecodeLength, why, sizeof why);
    if (r <= 0) { LOG("pixel shader reading SV_ShadingRate left as it is: %s", why); free(buf); return FALSE; }
    n = InterlockedIncrement(&shadingrate_fixed);
    if (n <= 3 || !(n % 100)) LOG("pixel shader reading SV_ShadingRate handed over with it read as 0 (%ld so far)", (long)n);
    *copy = buf;
    return TRUE;
}

// ---- blending without a render target -------------------------------------------------------------

// D3DMetal forces dual-source blending on a pixel shader whenever render target 0's blend description has
// BlendEnable and a SRC1 factor (its IsDualSourceBlendingEnabled), without looking at whether the pipeline has
// a render target 0, and the Metal shader converter takes dual-source blending only from a shader that writes
// exactly SV_Target0 and SV_Target1 ("Unable to force-enable dual-source blending: the pixel shader does not
// support dual-source blending"). Forza Horizon 6 builds the shadow passes of its glass, water, ocean and
// dithered-alpha materials with no render target, the material's dual-source blend left in, and a pixel shader
// that writes SV_Target0 and discards: 65 of the 73 pipelines D3DMetal logged as "Failed to compile fragment
// function" and marked no-op (M5 Pro, macOS 27.0.1; tools/dxilbench settings and dualtest show it). Without a
// render target 0 D3D12 blends nothing there, so the blend goes over switched off. HB_TSSHIM_UNUSED_BLEND=0
// turns it off. (The 8 others, the skid-mark decals, really blend dual-source into one target from a shader
// that writes three: not changed here.)
static int keep_unused_blend;
static LONG unused_blend_fixed;
static BOOL is_src1(D3D12_BLEND b) { return b >= D3D12_BLEND_SRC1_COLOR && b <= D3D12_BLEND_INV_SRC1_ALPHA; }
static BOOL fix_unused_blend(D3D12_BLEND_DESC *b, UINT targets, DXGI_FORMAT target0)
{
    D3D12_RENDER_TARGET_BLEND_DESC *t = &b->RenderTarget[0]; LONG n;
    if (keep_unused_blend || !t->BlendEnable) return FALSE;
    // render target 0's description also blends targets 1-7 unless IndependentBlendEnable
    if (targets && (target0 != DXGI_FORMAT_UNKNOWN || !b->IndependentBlendEnable)) return FALSE;
    if (!is_src1(t->SrcBlend) && !is_src1(t->DestBlend) && !is_src1(t->SrcBlendAlpha) && !is_src1(t->DestBlendAlpha)) return FALSE;
    t->BlendEnable = FALSE;
    n = InterlockedIncrement(&unused_blend_fixed);
    if (n <= 3 || !(n % 100)) LOG("dual-source blend on render target 0 of a pipeline without one switched off (%ld so far)", (long)n);
    return TRUE;
}

// ---- shader dump (HB_TSSHIM_DUMP) ----------------------------------------------------------------

static int dump_shaders;
static FILE *pairs_file;
static CRITICAL_SECTION dump_lock;
// Named by the container's digest; a file that exists already is left alone.
static void dump_one(D3D12_SHADER_BYTECODE b, const char *ext, char name[33])
{
    char path[MAX_PATH]; HANDLE h; DWORD done; int i;
    strcpy(name, "-");
    if (!b.pShaderBytecode || b.BytecodeLength < 20 || b.BytecodeLength > 0x7fffffff) return;
    for (i = 0; i < 16; i++) sprintf(name + 2 * i, "%02x", ((const UINT8 *)b.pShaderBytecode)[4 + i]);
    snprintf(path, sizeof path, "C:\\highball\\shaders\\%s.%s", name, ext);
    h = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile(h, b.pShaderBytecode, (DWORD)b.BytecodeLength, &done, NULL);
    CloseHandle(h);
}
static void dump_pipeline(D3D12_SHADER_BYTECODE vs, D3D12_SHADER_BYTECODE ps)
{
    char v[33], p[33];
    if (!dump_shaders) return;
    dump_one(vs, "vs", v); dump_one(ps, "ps", p);
    EnterCriticalSection(&dump_lock);
    if (!pairs_file) {
        char path[MAX_PATH]; snprintf(path, sizeof path, "C:\\highball\\shaders\\pairs-%lu.txt", (unsigned long)GetCurrentProcessId());
        pairs_file = fopen(path, "a");
    }
    if (pairs_file) { fprintf(pairs_file, "%s %s\n", v, p); fflush(pairs_file); }
    LeaveCriticalSection(&dump_lock);
}

// ---- shader replacement (HB_TSSHIM_REPLACE) ------------------------------------------------------

// HB_TSSHIM_REPLACE=<name>[,<name>...] hands D3DMetal C:\highball\replace\<name>\<digest>.<vs|ps> in place of the
// game's shader whose container digest that is. tools/mac_shader_fixes.sh and tools/dxilbench/replace_output.py
// build them from the files HB_TSSHIM_DUMP wrote. A shader in the folder's dualsrc\ subfolder is handed over only
// in pipelines where D3DMetal compiles for dual-source blending (render target 0 blends with a SRC1 factor, see
// fix_unused_blend), so a pipeline that uses the same shader otherwise keeps the original. Counts go to
// C:\highball\logs\tsshim-replace-<pid>.log. A digest the game no longer uses (a game update) simply never matches.
typedef struct { UINT8 digest[16]; void *code; SIZE_T size; BOOL dualsrc_only; LONG used; } Replacement;
static Replacement *replacements; static int nreplacements; static FILE *replace_log;
static void load_replacement_folder(const char *folder, BOOL dualsrc_only)
{
    char pattern[MAX_PATH], path[MAX_PATH]; WIN32_FIND_DATAA fd; HANDLE h; int i, before = nreplacements;
    snprintf(pattern, sizeof pattern, "%s\\*", folder);
    if ((h = FindFirstFileA(pattern, &fd)) == INVALID_HANDLE_VALUE) return;
    do {
        Replacement r; FILE *f; long n; unsigned v;
        if (strlen(fd.cFileName) != 35 || fd.cFileName[32] != '.') continue;
        for (i = 0; i < 16 && sscanf(fd.cFileName + 2 * i, "%2x", &v) == 1; i++) r.digest[i] = (UINT8)v;
        if (i < 16) continue;
        snprintf(path, sizeof path, "%s\\%s", folder, fd.cFileName);
        if (!(f = fopen(path, "rb"))) continue;
        fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
        r.code = n > 32 ? malloc(n) : NULL; r.size = n; r.used = 0; r.dualsrc_only = dualsrc_only;
        if (r.code && fread(r.code, 1, n, f) == (size_t)n && !memcmp(r.code, "DXBC", 4)) {
            Replacement *grown = realloc(replacements, (nreplacements + 1) * sizeof *grown);
            if (grown) { replacements = grown; replacements[nreplacements++] = r; } else free(r.code);
        } else free(r.code);
        fclose(f);
    } while (FindNextFileA(h, &fd));
    FindClose(h);
    if (replace_log) { fprintf(replace_log, "%d replacement shaders from %s%s\n", nreplacements - before, folder, dualsrc_only ? " (dual-source pipelines only)" : ""); fflush(replace_log); }
}
static void load_replacements(const char *names)
{
    char list[256], folder[MAX_PATH], *name, *ctx = NULL;
    snprintf(folder, sizeof folder, "C:\\highball\\logs\\tsshim-replace-%lu.log", (unsigned long)GetCurrentProcessId());
    replace_log = fopen(folder, "a");
    snprintf(list, sizeof list, "%s", names);
    for (name = strtok_s(list, ",", &ctx); name; name = strtok_s(NULL, ",", &ctx)) {
        if (!*name || strchr(name, '\\') || strchr(name, '/') || strstr(name, "..")) continue;
        snprintf(folder, sizeof folder, "C:\\highball\\replace\\%s", name); load_replacement_folder(folder, FALSE);
        snprintf(folder, sizeof folder, "C:\\highball\\replace\\%s\\dualsrc", name); load_replacement_folder(folder, TRUE);
    }
}
static BOOL replace_shader(D3D12_SHADER_BYTECODE *b, BOOL dualsrc)
{
    int i;
    if (!nreplacements || !b->pShaderBytecode || b->BytecodeLength < 20) return FALSE;
    for (i = 0; i < nreplacements; i++) {
        if (replacements[i].dualsrc_only && !dualsrc) continue;
        if (memcmp(replacements[i].digest, (const UINT8 *)b->pShaderBytecode + 4, 16)) continue;
        b->pShaderBytecode = replacements[i].code; b->BytecodeLength = replacements[i].size;
        if (replace_log && InterlockedIncrement(&replacements[i].used) <= 3) {
            fprintf(replace_log, "replaced shader %d of %d%s\n", i, nreplacements, replacements[i].dualsrc_only ? " in a dual-source pipeline" : ""); fflush(replace_log);
        }
        return TRUE;
    }
    return FALSE;
}
// What D3DMetal's IsDualSourceBlendingEnabled checks: render target 0's BlendEnable and a SRC1 factor.
static BOOL blend_forces_dualsrc(const D3D12_BLEND_DESC *b)
{
    const D3D12_RENDER_TARGET_BLEND_DESC *t = &b->RenderTarget[0];
    return t->BlendEnable && (is_src1(t->SrcBlend) || is_src1(t->DestBlend) || is_src1(t->SrcBlendAlpha) || is_src1(t->DestBlendAlpha));
}

// ---- an EQUAL depth test after a depth pre-pass (HB_TSSHIM_DEPTH_EQUAL=1, an experiment) ----------------

// Forza Horizon 6 draws the leaves of nearby trees black with D3DMetal 4.0b3: their silhouette is there (it hides
// what is behind), their colour pass writes nothing -- forcing the foliage albedo to magenta turned distant foliage
// magenta but left those leaves black (M5 Pro, 2026-10-25). The usual cause of that picture: a depth pre-pass draws
// the shape, and the colour pass tests depth EQUAL without writing it, so a position computed one bit differently
// by the colour pass's vertex shader (wind animation on near leaves, compiled for Metal) fails the test everywhere.
// With HB_TSSHIM_DEPTH_EQUAL=1 such a pipeline gets "equal or nearer" instead, and a depth bias of 8 units towards
// the viewer so a fragment a bit behind its own pre-pass value still passes; which way is nearer (reverse-Z or
// not) is read from the depth-writing pipelines created so far. Off by default.
static int depth_equal_fix;
static LONG depth_greater, depth_less, depth_equal_fixed;
static void count_depth_direction(BOOL on, BOOL write, int func)
{
    if (!on || !write) return;
    if (func == D3D12_COMPARISON_FUNC_GREATER || func == D3D12_COMPARISON_FUNC_GREATER_EQUAL) InterlockedIncrement(&depth_greater);
    else if (func == D3D12_COMPARISON_FUNC_LESS || func == D3D12_COMPARISON_FUNC_LESS_EQUAL) InterlockedIncrement(&depth_less);
}
// The test to use instead, or 0 to leave the pipeline as it is; *bias gets the depth bias to add.
static int fix_depth_equal(BOOL on, BOOL write, int func, int *bias)
{
    LONG g = depth_greater, l = depth_less, n;
    if (!depth_equal_fix || !on || write || func != D3D12_COMPARISON_FUNC_EQUAL || g == l) return 0;
    *bias = g > l ? 8 : -8;
    n = InterlockedIncrement(&depth_equal_fixed);
    if (n <= 3 || !(n % 100)) LOG("depth EQUAL without depth writes made %s, bias %d (%ld so far; %ld greater, %ld less seen)",
                                  g > l ? "GREATER_EQUAL" : "LESS_EQUAL", *bias, (long)n, (long)g, (long)l);
    return g > l ? D3D12_COMPARISON_FUNC_GREATER_EQUAL : D3D12_COMPARISON_FUNC_LESS_EQUAL;
}

// What a graphics pipeline description goes to D3DMetal with: shaders replaced (diagnostics), appended offsets
// written out, the pixel shader fixed, an unused blend switched off and (as an experiment) an EQUAL depth test
// widened, each only where needed. The copies live until free_fixups.
typedef struct {
    D3D12_INPUT_ELEMENT_DESC elems[D3D12_IA_VERTEX_INPUT_STRUCTURE_ELEMENT_COUNT]; void *ps, *stream; BOOL blend;
    UINT64 hash[8]; UINT targets, format0;   // a stream's shaders by subobject type (VS PS DS HS GS - AS MS), for the debug log
    BOOL depth_on, depth_write; int depth_func, depth_new;   // the game's depth test, and what it was changed to
} Fixups;
static void free_fixups(Fixups *fx) { free(fx->ps); free(fx->stream); }
static const D3D12_GRAPHICS_PIPELINE_STATE_DESC *fix_graphics_desc(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *d, D3D12_GRAPHICS_PIPELINE_STATE_DESC *copy, Fixups *fx)
{
    BOOL layout, ps, rvs, rps; D3D12_BLEND_DESC blend; D3D12_SHADER_BYTECODE vsb, psb; int bias = 0;
    fx->ps = fx->stream = NULL; fx->depth_new = 0;
    if (!d) return d;
    dump_pipeline(d->VS, d->PS);
    vsb = d->VS; psb = d->PS;
    rvs = replace_shader(&vsb, FALSE); rps = replace_shader(&psb, blend_forces_dualsrc(&d->BlendState));
    layout = resolve_append_offsets(&d->InputLayout, fx->elems);
    ps = fix_shadingrate(&psb, &fx->ps);
    blend = d->BlendState; fx->blend = fix_unused_blend(&blend, d->NumRenderTargets, d->RTVFormats[0]);
    fx->depth_on = d->DepthStencilState.DepthEnable; fx->depth_write = d->DepthStencilState.DepthWriteMask != D3D12_DEPTH_WRITE_MASK_ZERO;
    fx->depth_func = d->DepthStencilState.DepthFunc;
    count_depth_direction(fx->depth_on, fx->depth_write, fx->depth_func);
    fx->depth_new = fix_depth_equal(fx->depth_on, fx->depth_write, fx->depth_func, &bias);
    if (!layout && !ps && !fx->blend && !rvs && !rps && !fx->depth_new) return d;
    *copy = *d;
    copy->VS = vsb; copy->PS = psb;
    if (layout) copy->InputLayout.pInputElementDescs = fx->elems;
    if (ps) copy->PS.pShaderBytecode = fx->ps;
    if (fx->blend) copy->BlendState = blend;
    if (fx->depth_new) { copy->DepthStencilState.DepthFunc = fx->depth_new; copy->RasterizerState.DepthBias += bias; }
    return copy;
}

// A pipeline state stream is a run of subobjects, each a D3D12_PIPELINE_STATE_SUBOBJECT_TYPE followed by
// its description at that description's alignment, the pair padded to pointer size. The input layout and the
// pixel shader are rewritten; a stream with a subobject type this table does not know is passed through untouched.
SIZE_T stream_inner_size(UINT type, SIZE_T *inner_align)
{
    static const struct { UINT size, align; } t[] = {
        { 8, 8 },      // ROOT_SIGNATURE
        { 16, 8 }, { 16, 8 }, { 16, 8 }, { 16, 8 }, { 16, 8 }, { 16, 8 },   // VS PS DS HS GS CS
        { 32, 8 },     // STREAM_OUTPUT
        { 328, 4 },    // BLEND
        { 4, 4 },      // SAMPLE_MASK
        { 44, 4 },     // RASTERIZER
        { 52, 4 },     // DEPTH_STENCIL
        { 16, 8 },     // INPUT_LAYOUT
        { 4, 4 },      // IB_STRIP_CUT_VALUE
        { 4, 4 },      // PRIMITIVE_TOPOLOGY
        { 36, 4 },     // RENDER_TARGET_FORMATS
        { 4, 4 },      // DEPTH_STENCIL_FORMAT
        { 8, 4 },      // SAMPLE_DESC
        { 4, 4 },      // NODE_MASK
        { 16, 8 },     // CACHED_PSO
        { 4, 4 },      // FLAGS
        { 56, 4 },     // DEPTH_STENCIL1
        { 24, 8 },     // VIEW_INSTANCING
        { 0, 0 },      // 23 unused
        { 16, 8 }, { 16, 8 },   // AS MS
        { 60, 4 },     // DEPTH_STENCIL2
        { 44, 4 },     // RASTERIZER1
        { 40, 4 },     // RASTERIZER2
    };
    if (type >= sizeof t / sizeof *t || !t[type].size) return 0;
    *inner_align = t[type].align;
    return t[type].size;
}
static UINT64 bytecode_hash(D3D12_SHADER_BYTECODE b);
static BOOL rewrite_stream(const D3D12_PIPELINE_STATE_STREAM_DESC *in, D3D12_PIPELINE_STATE_STREAM_DESC *out, Fixups *fx)
{
    const UINT8 *s; SIZE_T o = 0, layout_at = 0, vs_at = 0, ps_at = 0, blend_at = 0, formats_at = 0, depth_at = 0, raster_at = 0;
    UINT raster_type = 0; int bias = 0;
    D3D12_INPUT_LAYOUT_DESC layout; D3D12_SHADER_BYTECODE vs = { 0 }, ps = { 0 }; BOOL new_layout = FALSE, new_ps = FALSE, new_vs = FALSE, replaced_ps = FALSE; UINT8 *buf;
    D3D12_BLEND_DESC blend; struct D3D12_RT_FORMAT_ARRAY formats = { { 0 }, 0 };   // no RENDER_TARGET_FORMATS subobject: no render targets
    fx->ps = fx->stream = NULL; fx->blend = FALSE; memset(fx->hash, 0, sizeof fx->hash); fx->targets = fx->format0 = 0;
    fx->depth_on = TRUE; fx->depth_write = TRUE; fx->depth_func = D3D12_COMPARISON_FUNC_LESS; fx->depth_new = 0;   // D3D12's defaults
    if (!in || !in->pPipelineStateSubobjectStream || !in->SizeInBytes) return FALSE;
    s = in->pPipelineStateSubobjectStream;
    while (o + sizeof(UINT) <= in->SizeInBytes) {
        UINT type; SIZE_T align, size, at;
        memcpy(&type, s + o, sizeof type);
        if (!(size = stream_inner_size(type, &align))) return FALSE;
        at = (o + sizeof(UINT) + align - 1) & ~(align - 1);
        if (at + size > in->SizeInBytes) return FALSE;
        if (type == D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_INPUT_LAYOUT) layout_at = at;
        else if (type == D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS) vs_at = at;
        else if (type == D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS) ps_at = at;
        else if (type == D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_BLEND) blend_at = at;
        else if (type == D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS) formats_at = at;
        else if (type == D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL || type == 21 || type == 26) depth_at = at;   // DEPTH_STENCIL, 1, 2
        else if (type == D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER || type == 27 || type == 28) { raster_at = at; raster_type = type; }
        if (dbg && type >= D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS && type <= D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_MS
            && type != D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_CS && type != 7 + 16 && type < 26)
        {
            D3D12_SHADER_BYTECODE b; UINT slot = type <= 5 ? type - 1 : type - 18;   // VS..GS -> 0..4, AS MS -> 6 7
            memcpy(&b, s + at, sizeof b);
            if (slot < 8) fx->hash[slot] = bytecode_hash(b);
        }
        o = (at + size + sizeof(void *) - 1) & ~(sizeof(void *) - 1);
    }
    if (vs_at) memcpy(&vs, s + vs_at, sizeof vs);
    if (ps_at) memcpy(&ps, s + ps_at, sizeof ps);
    if (vs_at || ps_at) dump_pipeline(vs, ps);
    if (blend_at) memcpy(&blend, s + blend_at, sizeof blend);
    if (vs_at) new_vs = replace_shader(&vs, FALSE);
    if (ps_at) replaced_ps = replace_shader(&ps, blend_at && blend_forces_dualsrc(&blend));
    if (layout_at) { memcpy(&layout, s + layout_at, sizeof layout); new_layout = resolve_append_offsets(&layout, fx->elems); }
    if (ps_at) new_ps = fix_shadingrate(&ps, &fx->ps);
    if (formats_at) memcpy(&formats, s + formats_at, sizeof formats);
    fx->targets = formats.NumRenderTargets; fx->format0 = formats.RTFormats[0];
    if (blend_at) fx->blend = fix_unused_blend(&blend, formats.NumRenderTargets, formats.RTFormats[0]);
    if (depth_at) {   // all three depth-stencil descriptions start DepthEnable, DepthWriteMask, DepthFunc
        UINT v[3]; memcpy(v, s + depth_at, sizeof v);
        fx->depth_on = v[0]; fx->depth_write = v[1] != D3D12_DEPTH_WRITE_MASK_ZERO; fx->depth_func = v[2];
    }
    count_depth_direction(fx->depth_on, fx->depth_write, fx->depth_func);
    if (depth_at && raster_at) fx->depth_new = fix_depth_equal(fx->depth_on, fx->depth_write, fx->depth_func, &bias);
    if ((!new_layout && !new_ps && !fx->blend && !new_vs && !replaced_ps && !fx->depth_new) || !(buf = malloc(in->SizeInBytes))) { free(fx->ps); fx->ps = NULL; fx->blend = FALSE; fx->depth_new = 0; return FALSE; }
    memcpy(buf, s, in->SizeInBytes);
    if (new_vs) memcpy(buf + vs_at, &vs, sizeof vs);
    if (replaced_ps) memcpy(buf + ps_at, &ps, sizeof ps);
    if (new_layout) { layout.pInputElementDescs = fx->elems; memcpy(buf + layout_at, &layout, sizeof layout); }
    if (new_ps) { ps.pShaderBytecode = fx->ps; memcpy(buf + ps_at, &ps, sizeof ps); }
    if (fx->blend) memcpy(buf + blend_at, &blend, sizeof blend);
    if (fx->depth_new) {
        UINT f = fx->depth_new; memcpy(buf + depth_at + 8, &f, sizeof f);
        if (raster_type == D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER) { INT b; memcpy(&b, buf + raster_at + 12, sizeof b); b += bias; memcpy(buf + raster_at + 12, &b, sizeof b); }
        else { FLOAT b; memcpy(&b, buf + raster_at + 12, sizeof b); b += bias; memcpy(buf + raster_at + 12, &b, sizeof b); }   // RASTERIZER1/2: a float
    }
    out->SizeInBytes = in->SizeInBytes; out->pPipelineStateSubobjectStream = buf; fx->stream = buf;
    return TRUE;
}

// With HB_TSSHIM_DEBUG every graphics pipeline is logged under the number D3DMetal gives it, with the game's shaders
// (the digests HB_TSSHIM_DUMP names its files after, before any fix) (one counter
// for graphics and compute pipelines, counted as they are created, so creation is serialised here while
// debugging), which ties D3DMetal's "marking PSO(N) as no-op" errors to the shaders behind them.
CRITICAL_SECTION pso_lock; unsigned pso_seq;
static UINT64 bytecode_hash(D3D12_SHADER_BYTECODE b)
{
    UINT64 h = 0;
    if (b.pShaderBytecode && b.BytecodeLength >= 32 && !memcmp(b.pShaderBytecode, "DXBC", 4)) memcpy(&h, (const UINT8 *)b.pShaderBytecode + 4, 8);
    return h;
}
HRESULT (STDMETHODCALLTYPE *real_CreateGraphicsPipelineState)(ID3D12Device *, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateComputePipelineState)(ID3D12Device *, const D3D12_COMPUTE_PIPELINE_STATE_DESC *, REFIID, void **);
static HRESULT STDMETHODCALLTYPE hook_CreateGraphicsPipelineState(ID3D12Device *dev, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *d, REFIID riid, void **out)
{
    D3D12_GRAPHICS_PIPELINE_STATE_DESC copy; Fixups fx; HRESULT hr; unsigned n; const D3D12_GRAPHICS_PIPELINE_STATE_DESC *game = d;
    d = fix_graphics_desc(d, &copy, &fx);
    if (!dbg && !inspect_serial) {
        hr = real_CreateGraphicsPipelineState(dev, d, riid, out);
        if (inspect_on) inspect_graphics(SUCCEEDED(hr) && out ? *out : NULL, inspect_next_id(), game, d, dev, hr);
        free_fixups(&fx); return hr;
    }
    EnterCriticalSection(&pso_lock);
    hr = real_CreateGraphicsPipelineState(dev, d, riid, out);
    n = pso_seq++;
    LeaveCriticalSection(&pso_lock);
    if (inspect_on) inspect_graphics(SUCCEEDED(hr) && out ? *out : NULL, n, game, d, dev, hr);
    if (d && dbg) {
        const D3D12_BLEND_DESC *b = &d->BlendState;
        LOG("pipeline %u: vs %016llx ps %016llx ds %016llx hs %016llx gs %016llx, %u targets (format %u), %u samples, hr 0x%08lx%s%s", n,
            (unsigned long long)bytecode_hash(game->VS), (unsigned long long)bytecode_hash(game->PS), (unsigned long long)bytecode_hash(game->DS),
            (unsigned long long)bytecode_hash(game->HS), (unsigned long long)bytecode_hash(game->GS), d->NumRenderTargets, (unsigned)d->RTVFormats[0],
            d->SampleDesc.Count, (unsigned long)hr, fx.ps ? ", pixel shader's SV_ShadingRate read as 0" : "", fx.blend ? ", unused dual-source blend off" : "");
        LOG("pipeline %u: depth test %d write %d func %d%s, formats %u %u %u %u %u %u %u %u depth %u, independent blend %d, target 0 blend %d (%d %d %d / %d %d %d) mask %x, a2c %d, cull %d",
            n, fx.depth_on, fx.depth_write, fx.depth_func, fx.depth_new ? " (widened)" : "", (unsigned)d->RTVFormats[0], (unsigned)d->RTVFormats[1], (unsigned)d->RTVFormats[2], (unsigned)d->RTVFormats[3],
            (unsigned)d->RTVFormats[4], (unsigned)d->RTVFormats[5], (unsigned)d->RTVFormats[6], (unsigned)d->RTVFormats[7], (unsigned)d->DSVFormat,
            b->IndependentBlendEnable, b->RenderTarget[0].BlendEnable, b->RenderTarget[0].SrcBlend, b->RenderTarget[0].DestBlend, b->RenderTarget[0].BlendOp,
            b->RenderTarget[0].SrcBlendAlpha, b->RenderTarget[0].DestBlendAlpha, b->RenderTarget[0].BlendOpAlpha, b->RenderTarget[0].RenderTargetWriteMask,
            b->AlphaToCoverageEnable, d->RasterizerState.CullMode);
    }
    free_fixups(&fx);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateComputePipelineState(ID3D12Device *dev, const D3D12_COMPUTE_PIPELINE_STATE_DESC *d, REFIID riid, void **out)
{
    HRESULT hr; unsigned n;
    if (!dbg && !inspect_serial) {
        hr = real_CreateComputePipelineState(dev, d, riid, out);
        if (inspect_on) inspect_compute(SUCCEEDED(hr) && out ? *out : NULL, inspect_next_id(), d, hr);
        return hr;
    }
    EnterCriticalSection(&pso_lock);
    hr = real_CreateComputePipelineState(dev, d, riid, out);
    n = pso_seq++;
    LeaveCriticalSection(&pso_lock);
    if (inspect_on) inspect_compute(SUCCEEDED(hr) && out ? *out : NULL, n, d, hr);
    if (d) LOG("pipeline %u: cs %016llx, hr 0x%08lx", n, (unsigned long long)bytecode_hash(d->CS), (unsigned long)hr);
    return hr;
}
HRESULT (STDMETHODCALLTYPE *real_CreatePipelineState)(ID3D12Device2 *, const D3D12_PIPELINE_STATE_STREAM_DESC *, REFIID, void **);
static HRESULT STDMETHODCALLTYPE hook_CreatePipelineState(ID3D12Device2 *dev, const D3D12_PIPELINE_STATE_STREAM_DESC *d, REFIID riid, void **out)
{
    D3D12_PIPELINE_STATE_STREAM_DESC copy; Fixups fx; HRESULT hr; unsigned n; const D3D12_PIPELINE_STATE_STREAM_DESC *game = d;
    if (rewrite_stream(d, &copy, &fx)) d = &copy;
    if (!dbg && !inspect_serial) {
        hr = real_CreatePipelineState(dev, d, riid, out);
        if (inspect_on) inspect_stream(SUCCEEDED(hr) && out ? *out : NULL, inspect_next_id(), game, d, (ID3D12Device *)dev, hr);
        free_fixups(&fx); return hr;
    }
    EnterCriticalSection(&pso_lock);   // counted with the others, so the numbers stay D3DMetal's
    hr = real_CreatePipelineState(dev, d, riid, out);
    n = pso_seq++;
    LeaveCriticalSection(&pso_lock);
    if (inspect_on) inspect_stream(SUCCEEDED(hr) && out ? *out : NULL, n, game, d, (ID3D12Device *)dev, hr);
    LOG("pipeline %u: stream vs %016llx ps %016llx ds %016llx hs %016llx gs %016llx as %016llx ms %016llx, %u targets (format %u), depth test %d write %d func %d%s, hr 0x%08lx%s%s", n,
        (unsigned long long)fx.hash[0], (unsigned long long)fx.hash[1], (unsigned long long)fx.hash[2], (unsigned long long)fx.hash[3],
        (unsigned long long)fx.hash[4], (unsigned long long)fx.hash[6], (unsigned long long)fx.hash[7], fx.targets, fx.format0,
        fx.depth_on, fx.depth_write, fx.depth_func, fx.depth_new ? " (widened)" : "",
        (unsigned long)hr, fx.ps ? ", pixel shader's SV_ShadingRate read as 0" : "",
        fx.blend ? ", unused dual-source blend off" : "");
    free_fixups(&fx);
    return hr;
}
// A pipeline library hands back a stored pipeline only for the description it was stored with, and the
// stored one went to D3DMetal rewritten, so loads are rewritten the same way.
static HRESULT (STDMETHODCALLTYPE *real_LoadGraphicsPipeline)(ID3D12PipelineLibrary *, LPCWSTR, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *, REFIID, void **);
static HRESULT STDMETHODCALLTYPE hook_LoadGraphicsPipeline(ID3D12PipelineLibrary *lib, LPCWSTR name, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *d, REFIID riid, void **out)
{
    D3D12_GRAPHICS_PIPELINE_STATE_DESC copy; Fixups fx; HRESULT hr; const D3D12_GRAPHICS_PIPELINE_STATE_DESC *game = d;
    d = fix_graphics_desc(d, &copy, &fx);
    hr = real_LoadGraphicsPipeline(lib, name, d, riid, out);
    if (inspect_on) {
        ID3D12Device *dev = NULL;
        if (FAILED(lib->lpVtbl->GetDevice(lib, &IID_ID3D12Device, (void **)&dev))) dev = NULL;
        inspect_graphics(SUCCEEDED(hr) && out ? *out : NULL, ~0u, game, d, dev, hr);
        if (dev) dev->lpVtbl->Release(dev);
    }
    free_fixups(&fx);
    return hr;
}
static HRESULT (STDMETHODCALLTYPE *real_LoadPipeline)(ID3D12PipelineLibrary1 *, LPCWSTR, const D3D12_PIPELINE_STATE_STREAM_DESC *, REFIID, void **);
static HRESULT STDMETHODCALLTYPE hook_LoadPipeline(ID3D12PipelineLibrary1 *lib, LPCWSTR name, const D3D12_PIPELINE_STATE_STREAM_DESC *d, REFIID riid, void **out)
{
    D3D12_PIPELINE_STATE_STREAM_DESC copy; Fixups fx; HRESULT hr; const D3D12_PIPELINE_STATE_STREAM_DESC *game = d;
    if (rewrite_stream(d, &copy, &fx)) d = &copy;
    hr = real_LoadPipeline(lib, name, d, riid, out);
    if (inspect_on) {
        ID3D12Device *dev = NULL;
        if (FAILED(lib->lpVtbl->GetDevice(lib, &IID_ID3D12Device, (void **)&dev))) dev = NULL;
        inspect_stream(SUCCEEDED(hr) && out ? *out : NULL, ~0u, game, d, dev, hr);
        if (dev) dev->lpVtbl->Release(dev);
    }
    free_fixups(&fx);
    return hr;
}
static HRESULT (STDMETHODCALLTYPE *real_CreatePipelineLibrary)(ID3D12Device1 *, const void *, SIZE_T, REFIID, void **);
static HRESULT STDMETHODCALLTYPE hook_CreatePipelineLibrary(ID3D12Device1 *dev, const void *blob, SIZE_T len, REFIID riid, void **out)
{
    HRESULT hr = real_CreatePipelineLibrary(dev, blob, len, riid, out);
    if (SUCCEEDED(hr) && out && *out) {
        IUnknown *u = *out; ID3D12PipelineLibrary *lib = NULL; ID3D12PipelineLibrary1 *lib1 = NULL;
        if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12PipelineLibrary, (void **)&lib)) && lib) {
            ID3D12PipelineLibraryVtbl *vt = (ID3D12PipelineLibraryVtbl *)lib->lpVtbl;
            patch_slot((void **)&vt->LoadGraphicsPipeline, (void *)hook_LoadGraphicsPipeline, (void **)&real_LoadGraphicsPipeline);
            lib->lpVtbl->Release(lib);
        }
        if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12PipelineLibrary1, (void **)&lib1)) && lib1) {
            ID3D12PipelineLibrary1Vtbl *vt = (ID3D12PipelineLibrary1Vtbl *)lib1->lpVtbl;
            patch_slot((void **)&vt->LoadGraphicsPipeline, (void *)hook_LoadGraphicsPipeline, (void **)&real_LoadGraphicsPipeline);
            patch_slot((void **)&vt->LoadPipeline, (void *)hook_LoadPipeline, (void **)&real_LoadPipeline);
            lib1->lpVtbl->Release(lib1);
        }
    }
    return hr;
}
// The two calls below exist only from ID3D12Device1 and ID3D12Device2 on, so they are patched only in
// vtables reached through those interfaces.
static void patch_device1_vtbl(void *iface)
{
    ID3D12Device1Vtbl *vt = *(ID3D12Device1Vtbl **)iface;
    patch_slot((void **)&vt->CreatePipelineLibrary, (void *)hook_CreatePipelineLibrary, (void **)&real_CreatePipelineLibrary);
}
static void patch_device2_vtbl(void *iface)
{
    ID3D12Device2Vtbl *vt = *(ID3D12Device2Vtbl **)iface;
    patch_slot((void **)&vt->CreatePipelineState, (void *)hook_CreatePipelineState, (void **)&real_CreatePipelineState);
}

static void patch_device_vtbl(void *iface)
{
    ID3D12DeviceVtbl *vt = *(ID3D12DeviceVtbl **)iface;
    patch_slot((void **)&vt->CreateQueryHeap, (void *)hook_CreateQueryHeap, (void **)&real_CreateQueryHeap);
    patch_slot((void **)&vt->CheckFeatureSupport, (void *)hook_CheckFeatureSupport, (void **)&real_CheckFeatureSupport);
    patch_slot((void **)&vt->CreateGraphicsPipelineState, (void *)hook_CreateGraphicsPipelineState, (void **)&real_CreateGraphicsPipelineState);
    if (dbg || inspect_on) patch_slot((void **)&vt->CreateComputePipelineState, (void *)hook_CreateComputePipelineState, (void **)&real_CreateComputePipelineState);
    if (dbg >= 2) {
        patch_slot((void **)&vt->CreateCommittedResource, (void *)hook_CreateCommittedResource, (void **)&real_CreateCommittedResource);
        patch_slot((void **)&vt->CreatePlacedResource, (void *)hook_CreatePlacedResource, (void **)&real_CreatePlacedResource);
        patch_slot((void **)&vt->CreateReservedResource, (void *)hook_CreateReservedResource, (void **)&real_CreateReservedResource);
        patch_slot((void **)&vt->CreateShaderResourceView, (void *)hook_CreateShaderResourceView, (void **)&real_CreateShaderResourceView);
        patch_slot((void **)&vt->CreateUnorderedAccessView, (void *)hook_CreateUnorderedAccessView, (void **)&real_CreateUnorderedAccessView);
        patch_slot((void **)&vt->CreateRenderTargetView, (void *)hook_CreateRenderTargetView, (void **)&real_CreateRenderTargetView);
        patch_slot((void **)&vt->CreateDepthStencilView, (void *)hook_CreateDepthStencilView, (void **)&real_CreateDepthStencilView);
    }
    inspect_patch_device(iface);
}
static void patch_list_vtbl(void *iface)
{
    ID3D12GraphicsCommandListVtbl *vt = *(ID3D12GraphicsCommandListVtbl **)iface;
    patch_slot((void **)&vt->EndQuery, (void *)hook_EndQuery, (void **)&real_EndQuery);
    patch_slot((void **)&vt->BeginQuery, (void *)hook_BeginQuery, (void **)&real_BeginQuery);
    patch_slot((void **)&vt->ResolveQueryData, (void *)hook_ResolveQueryData, (void **)&real_ResolveQueryData);
    patch_slot((void **)&vt->ResolveSubresource, (void *)hook_ResolveSubresource, (void **)&real_ResolveSubresource);
    inspect_patch_list(iface);
}
static void patch_queue_vtbl(void *iface)
{
    ID3D12CommandQueueVtbl *vt = *(ID3D12CommandQueueVtbl **)iface;
    patch_slot((void **)&vt->GetTimestampFrequency, (void *)hook_GetTimestampFrequency, (void **)&real_GetTimestampFrequency);
    patch_slot((void **)&vt->GetClockCalibration, (void *)hook_GetClockCalibration, (void **)&real_GetClockCalibration);
    inspect_patch_queue(iface);
}

// Every interface generation may carry its own vtable copy, so patch each one the object answers to.
static void patch_all(IUnknown *obj, const IID *const *ids, int n, void (*patch)(void *))
{
    int i; void *p;
    patch(obj);
    for (i = 0; i < n; i++) {
        if (FAILED(obj->lpVtbl->QueryInterface(obj, ids[i], &p)) || !p) continue;
        patch(p); ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p);
    }
}

static void patch_device(ID3D12Device *dev)
{
    static const IID *const dev_ids[] = {
        &IID_ID3D12Device1, &IID_ID3D12Device2, &IID_ID3D12Device3, &IID_ID3D12Device4, &IID_ID3D12Device5,
#ifdef __ID3D12Device6_INTERFACE_DEFINED__
        &IID_ID3D12Device6,
#endif
#ifdef __ID3D12Device7_INTERFACE_DEFINED__
        &IID_ID3D12Device7,
#endif
#ifdef __ID3D12Device8_INTERFACE_DEFINED__
        &IID_ID3D12Device8,
#endif
#ifdef __ID3D12Device9_INTERFACE_DEFINED__
        &IID_ID3D12Device9,
#endif
#ifdef __ID3D12Device10_INTERFACE_DEFINED__
        &IID_ID3D12Device10,
#endif
    };
    static const IID *const list_ids[] = {
        &IID_ID3D12GraphicsCommandList1, &IID_ID3D12GraphicsCommandList2, &IID_ID3D12GraphicsCommandList3,
        &IID_ID3D12GraphicsCommandList4, &IID_ID3D12GraphicsCommandList5, &IID_ID3D12GraphicsCommandList6,
#ifdef __ID3D12GraphicsCommandList7_INTERFACE_DEFINED__
        &IID_ID3D12GraphicsCommandList7,
#endif
    };
    static const D3D12_COMMAND_LIST_TYPE types[] = { D3D12_COMMAND_LIST_TYPE_DIRECT, D3D12_COMMAND_LIST_TYPE_COMPUTE, D3D12_COMMAND_LIST_TYPE_COPY };
    int t, i;
    patch_all((IUnknown *)dev, dev_ids, sizeof dev_ids / sizeof *dev_ids, patch_device_vtbl);
    for (i = 0; i < (int)(sizeof dev_ids / sizeof *dev_ids); i++) {
        void *p = NULL;
        if (FAILED(dev->lpVtbl->QueryInterface(dev, dev_ids[i], &p)) || !p) continue;
        patch_device1_vtbl(p);
        if (i >= 1) patch_device2_vtbl(p);   // dev_ids[0] is ID3D12Device1, the rest are ID3D12Device2 and later
        ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p);
    }
    for (t = 0; t < 3; t++) {
        ID3D12CommandAllocator *alloc = NULL; ID3D12GraphicsCommandList *list = NULL; ID3D12CommandQueue *queue = NULL;
        D3D12_COMMAND_QUEUE_DESC qd = { types[t], 0, D3D12_COMMAND_QUEUE_FLAG_NONE, 0 };
        if (SUCCEEDED(dev->lpVtbl->CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue)) && queue) {
            patch_queue_vtbl(queue); queue->lpVtbl->Release(queue);
        }
        if (FAILED(dev->lpVtbl->CreateCommandAllocator(dev, types[t], &IID_ID3D12CommandAllocator, (void **)&alloc)) || !alloc) continue;
        if (SUCCEEDED(dev->lpVtbl->CreateCommandList(dev, 0, types[t], alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list)) && list) {
            patch_all((IUnknown *)list, list_ids, sizeof list_ids / sizeof *list_ids, patch_list_vtbl);
            list->lpVtbl->Close(list); list->lpVtbl->Release(list);
        }
        alloc->lpVtbl->Release(alloc);
    }
    inspect_device(dev);
    LOG("device %p patched (timestamp frequency %llu Hz)", (void *)dev, (unsigned long long)qpc_freq);
}

// ---- exports -------------------------------------------------------------------------------

HRESULT WINAPI D3D12CreateDevice(IUnknown *adapter, D3D_FEATURE_LEVEL level, REFIID riid, void **out)
{
    typedef HRESULT (WINAPI *PFN)(IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
    PFN fn = real_dll ? (PFN)GetProcAddress(real_dll, "D3D12CreateDevice") : NULL;
    HRESULT hr;
    if (!fn) return E_FAIL;
    hr = fn(adapter, level, riid, out);
    if (SUCCEEDED(hr) && out && *out && !idle) {
        ID3D12Device *dev = NULL; IUnknown *u = (IUnknown *)*out;
        if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12Device, (void **)&dev)) && dev) { patch_device(dev); dev->lpVtbl->Release(dev); }
    }
    return hr;
}

// D3D12GetInterface, the Agility SDK entry point D3DMetal exports from 4.0 beta 3 (with a d3d12core.dll
// beside it). A game can create its device through the ID3D12DeviceFactory it hands out instead of
// D3D12CreateDevice, so a factory's CreateDevice is wrapped to patch those devices the same way. A
// D3DMetal without the export (3.0, 4.0 beta 2) gets E_NOINTERFACE, which is what a game would see
// from a Windows d3d12.dll that predates the Agility SDK.
static HRESULT (STDMETHODCALLTYPE *real_FactoryCreateDevice)(ID3D12DeviceFactory *, IUnknown *, D3D_FEATURE_LEVEL, REFIID, void **);
static HRESULT STDMETHODCALLTYPE hook_FactoryCreateDevice(ID3D12DeviceFactory *f, IUnknown *adapter, D3D_FEATURE_LEVEL level, REFIID riid, void **out)
{
    HRESULT hr = real_FactoryCreateDevice(f, adapter, level, riid, out);
    if (SUCCEEDED(hr) && out && *out) {
        ID3D12Device *dev = NULL; IUnknown *u = (IUnknown *)*out;
        if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12Device, (void **)&dev)) && dev) { patch_device(dev); dev->lpVtbl->Release(dev); }
    }
    return hr;
}
static void patch_factory_vtbl(void *iface)
{
    ID3D12DeviceFactoryVtbl *vt = *(ID3D12DeviceFactoryVtbl **)iface;
    patch_slot((void **)&vt->CreateDevice, (void *)hook_FactoryCreateDevice, (void **)&real_FactoryCreateDevice);
}

HRESULT WINAPI D3D12GetInterface(REFCLSID clsid, REFIID riid, void **out)
{
    typedef HRESULT (WINAPI *PFN)(REFCLSID, REFIID, void **);
    PFN fn = real_dll ? (PFN)GetProcAddress(real_dll, "D3D12GetInterface") : NULL;
    HRESULT hr;
    if (!fn) {
        LOG("D3D12GetInterface asked of a D3DMetal without it");
        if (out) *out = NULL;
        return E_NOINTERFACE;
    }
    hr = fn(clsid, riid, out);
    if (SUCCEEDED(hr) && out && *out && !idle) {
        ID3D12DeviceFactory *factory = NULL; IUnknown *u = (IUnknown *)*out;
        if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12DeviceFactory, (void **)&factory)) && factory) {
            patch_factory_vtbl(factory);
            LOG("device factory %p patched", (void *)factory);
            factory->lpVtbl->Release(factory);
        }
    }
    if (dbg) LOG("D3D12GetInterface hr=0x%08lx", (unsigned long)hr);
    return hr;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) {
        LARGE_INTEGER f;
        self = inst;
        DisableThreadLibraryCalls(inst);
        InitializeCriticalSection(&ring_lock);
        InitializeCriticalSection(&pso_lock);
        QueryPerformanceFrequency(&f); qpc_freq = (UINT64)f.QuadPart;
        // HB_TSSHIM_DEBUG=1: pipelines and feature queries; 2: also every resource and view (hundreds of MB, slow)
        { char v[8]; DWORD n = GetEnvironmentVariableA("HB_TSSHIM_DEBUG", v, sizeof v); dbg = n ? (n < sizeof v && v[0] == '2' ? 2 : 1) : 0; }
        { char v[8]; idle = GetEnvironmentVariableA("HB_D3D12_TSSHIM", v, sizeof v) == 1 && v[0] == '0'; }   // kill switch
        { char v[8]; pass_depth_resolve = GetEnvironmentVariableA("HB_TSSHIM_DEPTHRESOLVE", v, sizeof v) == 1 && v[0] == '1'; }
        { char v[8]; claim_atomic64 = GetEnvironmentVariableA("HB_TSSHIM_ATOMIC64", v, sizeof v) == 1 && v[0] == '1'; }
        { char v[8]; keep_append_offsets = GetEnvironmentVariableA("HB_TSSHIM_APPEND_OFFSETS", v, sizeof v) == 1 && v[0] == '0'; }
        { char v[8]; keep_shadingrate = GetEnvironmentVariableA("HB_TSSHIM_SHADINGRATE", v, sizeof v) == 1 && v[0] == '0'; }
        { char v[8]; keep_unused_blend = GetEnvironmentVariableA("HB_TSSHIM_UNUSED_BLEND", v, sizeof v) == 1 && v[0] == '0'; }
        { char v[8]; depth_equal_fix = GetEnvironmentVariableA("HB_TSSHIM_DEPTH_EQUAL", v, sizeof v) == 1 && v[0] == '1'; }
        { char v[8]; dump_shaders = GetEnvironmentVariableA("HB_TSSHIM_DUMP", v, sizeof v) == 1 && v[0] == '1'; }
        InitializeCriticalSection(&dump_lock);
        if (dump_shaders) { CreateDirectoryA("C:\\highball", NULL); CreateDirectoryA("C:\\highball\\shaders", NULL); }
        { char v[64]; DWORD n = GetEnvironmentVariableA("HB_TSSHIM_REPLACE", v, sizeof v); if (n && n < sizeof v) load_replacements(v); }
        if (!idle) inspect_init();
        if (!load_real()) return FALSE;
        RESOLVE(D3D12CoreCreateLayeredDevice); RESOLVE(D3D12CoreGetLayeredDeviceSize); RESOLVE(D3D12CoreRegisterLayers);
        RESOLVE(D3D12CreateRootSignatureDeserializer); RESOLVE(D3D12CreateVersionedRootSignatureDeserializer);
        RESOLVE(D3D12EnableExperimentalFeatures); RESOLVE(D3D12GetDebugInterface); RESOLVE(D3D12SerializeRootSignature);
        RESOLVE(D3D12SerializeVersionedRootSignature); RESOLVE(GetBehaviorValue);
        LOG("loaded in front of the real d3d12.dll");
    }
    if (reason == DLL_PROCESS_DETACH) inspect_finish();
    return TRUE;
}
