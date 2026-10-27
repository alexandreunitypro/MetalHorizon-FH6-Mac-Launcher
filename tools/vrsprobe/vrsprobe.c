/* vrsprobe: what the D3D12 device answers about Variable Rate Shading (CheckFeatureSupport OPTIONS6)
 * and the other optional features a renderer picks its shaders by (OPTIONS7 mesh shaders / sampler
 * feedback, OPTIONS tiled resources, OPTIONS5 raytracing), seen exactly as the game sees it: through
 * the shim, CrossOver's d3d12 and D3DMetal. No game, changes nothing.
 *
 * pipeline mode: builds a graphics pipeline from a vertex shader and a pixel shader (DXIL files, as
 * tools/dxilbench emit writes them: the pixel shader reads SV_ShadingRate and writes blue 1 when it reads
 * 0), the way Forza Horizon 6 does, once through CreateGraphicsPipelineState and once through a pipeline
 * state stream, draws one pixel with each and reads it back. A pipeline D3DMetal marked no-op leaves the
 * clear colour (0 0 0 0); a drawn one gives about 128 128 255 0.
 * targets mode: creates a pipeline from a dumped game pixel shader (its embedded root signature, RTS0)
 * and any vertex shader, with <n> R8G8B8A8 render targets and a D32 depth buffer, the way a shadow pass
 * (n = 0) does; D3DMetal compiles the fragment function there and logs it when it fails.
 * Usage: vrsprobe.exe
 *        vrsprobe.exe pipeline <vs.dxil> <ps.dxil>
 *        vrsprobe.exe targets <vs.dxil> <ps.dxil> <n> [dual]   (dual: render target 0 blends ONE, SRC1_COLOR) */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d12.h>

static void *read_file(const char *path, SIZE_T *size)
{
    FILE *f = fopen(path, "rb"); void *p; long n;
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    p = malloc(n);
    if (p && fread(p, 1, n, f) != (size_t)n) { free(p); p = NULL; }
    fclose(f); *size = n;
    return p;
}

static void features(ID3D12Device *dev)
{
    D3D12_FEATURE_DATA_D3D12_OPTIONS o = {0};
    D3D12_FEATURE_DATA_D3D12_OPTIONS5 o5 = {0};
    D3D12_FEATURE_DATA_D3D12_OPTIONS6 o6 = {0};
    D3D12_FEATURE_DATA_D3D12_OPTIONS7 o7 = {0};
    HRESULT hr;
    hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS6, &o6, sizeof(o6));
    printf("PROBE options6 -> hr %08lx VariableShadingRateTier %d AdditionalShadingRates %d PerPrimitiveWithViewportIndexing %d"
           " ShadingRateImageTileSize %u BackgroundProcessing %d\n", hr, o6.VariableShadingRateTier, o6.AdditionalShadingRatesSupported,
           o6.PerPrimitiveShadingRateSupportedWithViewportIndexing, o6.ShadingRateImageTileSize, o6.BackgroundProcessingSupported);
    hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS7, &o7, sizeof(o7));
    printf("PROBE options7 -> hr %08lx MeshShaderTier %d SamplerFeedbackTier %d\n", hr, o7.MeshShaderTier, o7.SamplerFeedbackTier);
    hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS, &o, sizeof(o));
    printf("PROBE options -> hr %08lx ResourceBindingTier %d TiledResourcesTier %d ResourceHeapTier %d\n", hr, o.ResourceBindingTier,
           o.TiledResourcesTier, o.ResourceHeapTier);
    hr = ID3D12Device_CheckFeatureSupport(dev, D3D12_FEATURE_D3D12_OPTIONS5, &o5, sizeof(o5));
    printf("PROBE options5 -> hr %08lx RaytracingTier %d\n", hr, o5.RaytracingTier);
}

/* Draws one triangle over a 1x1 target with the pipeline and returns the pixel (RGBA8). */
static UINT32 draw_one(ID3D12Device *dev, ID3D12CommandQueue *q, ID3D12RootSignature *rs, ID3D12PipelineState *pso)
{
    D3D12_HEAP_PROPERTIES def = { D3D12_HEAP_TYPE_DEFAULT }, rb = { D3D12_HEAP_TYPE_READBACK };
    D3D12_RESOURCE_DESC td = { D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, 1, 1, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 },
                               D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET };
    D3D12_RESOURCE_DESC bd = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, 256, 1, 1, 1, DXGI_FORMAT_UNKNOWN, { 1, 0 }, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, 0 };
    D3D12_CLEAR_VALUE clear = { DXGI_FORMAT_R8G8B8A8_UNORM, { { 0, 0, 0, 0 } } };
    D3D12_DESCRIPTOR_HEAP_DESC hd = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1, 0, 0 };
    ID3D12Resource *rt = NULL, *buf = NULL; ID3D12DescriptorHeap *heap = NULL; ID3D12CommandAllocator *alloc = NULL;
    ID3D12GraphicsCommandList *list = NULL; ID3D12Fence *fence = NULL; D3D12_CPU_DESCRIPTOR_HANDLE rtv;
    D3D12_VIEWPORT vp = { 0, 0, 1, 1, 0, 1 }; D3D12_RECT sc = { 0, 0, 1, 1 }; D3D12_RESOURCE_BARRIER bar;
    D3D12_TEXTURE_COPY_LOCATION src, dst; FLOAT black[4] = { 0, 0, 0, 0 }; UINT32 px = 0xdeadbeef; void *map; HANDLE ev;
    if (FAILED(ID3D12Device_CreateCommittedResource(dev, &def, 0, &td, D3D12_RESOURCE_STATE_RENDER_TARGET, &clear, &IID_ID3D12Resource, (void **)&rt))
        || FAILED(ID3D12Device_CreateCommittedResource(dev, &rb, 0, &bd, D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&buf))
        || FAILED(ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap))
        || FAILED(ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc))
        || FAILED(ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, pso, &IID_ID3D12GraphicsCommandList, (void **)&list))
        || FAILED(ID3D12Device_CreateFence(dev, 0, 0, &IID_ID3D12Fence, (void **)&fence))) { printf("PROBE setup failed\n"); return px; }
    heap->lpVtbl->GetCPUDescriptorHandleForHeapStart(heap, &rtv);   /* the C binding returns through a pointer */
    ID3D12Device_CreateRenderTargetView(dev, rt, NULL, rtv);
    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, black, 0, NULL);
    ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, NULL);
    ID3D12GraphicsCommandList_RSSetViewports(list, 1, &vp);
    ID3D12GraphicsCommandList_RSSetScissorRects(list, 1, &sc);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, rs);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_DrawInstanced(list, 3, 1, 0, 0);
    memset(&bar, 0, sizeof bar);
    bar.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION; bar.Transition.pResource = rt;
    bar.Transition.StateBefore = D3D12_RESOURCE_STATE_RENDER_TARGET; bar.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &bar);
    memset(&src, 0, sizeof src); memset(&dst, 0, sizeof dst);
    src.pResource = rt; src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    dst.pResource = buf; dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint.Footprint.Format = DXGI_FORMAT_R8G8B8A8_UNORM; dst.PlacedFootprint.Footprint.Width = 1;
    dst.PlacedFootprint.Footprint.Height = 1; dst.PlacedFootprint.Footprint.Depth = 1; dst.PlacedFootprint.Footprint.RowPitch = 256;
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    ID3D12GraphicsCommandList_Close(list);
    ID3D12CommandQueue_ExecuteCommandLists(q, 1, (ID3D12CommandList **)&list);
    ev = CreateEventA(NULL, FALSE, FALSE, NULL);
    ID3D12CommandQueue_Signal(q, fence, 1);
    ID3D12Fence_SetEventOnCompletion(fence, 1, ev);
    WaitForSingleObject(ev, 10000);
    if (SUCCEEDED(ID3D12Resource_Map(buf, 0, NULL, &map))) { px = *(UINT32 *)map; ID3D12Resource_Unmap(buf, 0, NULL); }
    return px;
}

static int pipeline(ID3D12Device *dev, const char *vs_path, const char *ps_path)
{
    typedef HRESULT (WINAPI *PFN_Serialize)(const D3D12_ROOT_SIGNATURE_DESC *, D3D_ROOT_SIGNATURE_VERSION, ID3DBlob **, ID3DBlob **);
    PFN_Serialize serialize = (PFN_Serialize)GetProcAddress(GetModuleHandleA("d3d12.dll"), "D3D12SerializeRootSignature");
    D3D12_ROOT_SIGNATURE_DESC rsd = { 0, NULL, 0, NULL, D3D12_ROOT_SIGNATURE_FLAG_NONE };
    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, 0, 0 };
    D3D12_GRAPHICS_PIPELINE_STATE_DESC d; ID3DBlob *blob = NULL; ID3D12RootSignature *rs = NULL; ID3D12CommandQueue *q = NULL;
    ID3D12PipelineState *pso = NULL; ID3D12Device2 *dev2 = NULL; SIZE_T vs_size = 0, ps_size = 0; void *vs, *ps; HRESULT hr; int i;
    if (!(vs = read_file(vs_path, &vs_size)) || !(ps = read_file(ps_path, &ps_size))) { printf("PROBE cannot read the shaders\n"); return 1; }
    if (!serialize || FAILED(serialize(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, NULL))
        || FAILED(ID3D12Device_CreateRootSignature(dev, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob), &IID_ID3D12RootSignature, (void **)&rs))
        || FAILED(ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q))) { printf("PROBE root signature / queue failed\n"); return 1; }
    memset(&d, 0, sizeof d);
    d.pRootSignature = rs; d.VS.pShaderBytecode = vs; d.VS.BytecodeLength = vs_size; d.PS.pShaderBytecode = ps; d.PS.BytecodeLength = ps_size;
    for (i = 0; i < 8; i++) d.BlendState.RenderTarget[i].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    d.SampleMask = ~0u; d.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; d.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    d.RasterizerState.DepthClipEnable = TRUE; d.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    d.NumRenderTargets = 1; d.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM; d.SampleDesc.Count = 1;
    hr = ID3D12Device_CreateGraphicsPipelineState(dev, &d, &IID_ID3D12PipelineState, (void **)&pso);
    printf("PROBE CreateGraphicsPipelineState -> %08lx\n", hr);
    if (pso) printf("PROBE pixel from CreateGraphicsPipelineState: %08x\n", draw_one(dev, q, rs, pso));
    if (SUCCEEDED(ID3D12Device_QueryInterface(dev, &IID_ID3D12Device2, (void **)&dev2))) {
        struct {   /* the same pipeline as a stream: each subobject type padded to pointer size, then its description */
            struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; ID3D12RootSignature *v; } root;
            struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; D3D12_SHADER_BYTECODE v; } vs, ps;
            struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; struct D3D12_RT_FORMAT_ARRAY v; } rtv;
            struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; D3D12_RASTERIZER_DESC v; } rast;
        } s;
        D3D12_PIPELINE_STATE_STREAM_DESC sd = { sizeof s, &s };
        ID3D12PipelineState *pso2 = NULL;
        memset(&s, 0, sizeof s);
        s.root.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_ROOT_SIGNATURE; s.root.v = rs;
        s.vs.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS; s.vs.v = d.VS;
        s.ps.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS; s.ps.v = d.PS;
        s.rtv.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS; s.rtv.v.NumRenderTargets = 1; s.rtv.v.RTFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
        s.rast.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER; s.rast.v = d.RasterizerState;
        hr = ID3D12Device2_CreatePipelineState(dev2, &sd, &IID_ID3D12PipelineState, (void **)&pso2);
        printf("PROBE CreatePipelineState (stream) -> %08lx\n", hr);
        if (pso2) printf("PROBE pixel from CreatePipelineState: %08x\n", draw_one(dev, q, rs, pso2));
    }
    return 0;
}

static int targets(ID3D12Device *dev, const char *vs_path, const char *ps_path, int n, int dual)
{
    D3D12_GRAPHICS_PIPELINE_STATE_DESC d; ID3D12RootSignature *rs = NULL; ID3D12PipelineState *pso = NULL;
    SIZE_T vs_size = 0, ps_size = 0; void *vs, *ps; HRESULT hr; int i;
    if (!(vs = read_file(vs_path, &vs_size)) || !(ps = read_file(ps_path, &ps_size))) { printf("PROBE cannot read the shaders\n"); return 1; }
    hr = ID3D12Device_CreateRootSignature(dev, 0, ps, ps_size, &IID_ID3D12RootSignature, (void **)&rs);
    printf("PROBE root signature from the pixel shader -> %08lx\n", hr);
    if (!rs) return 1;
    memset(&d, 0, sizeof d);
    d.pRootSignature = rs; d.VS.pShaderBytecode = vs; d.VS.BytecodeLength = vs_size; d.PS.pShaderBytecode = ps; d.PS.BytecodeLength = ps_size;
    for (i = 0; i < 8; i++) d.BlendState.RenderTarget[i].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    d.SampleMask = ~0u; d.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; d.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    d.RasterizerState.DepthClipEnable = TRUE; d.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    d.DepthStencilState.DepthEnable = TRUE; d.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
    d.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS_EQUAL; d.DSVFormat = DXGI_FORMAT_D32_FLOAT;
    d.NumRenderTargets = n; for (i = 0; i < n; i++) d.RTVFormats[i] = DXGI_FORMAT_R8G8B8A8_UNORM;
    d.SampleDesc.Count = 1;
    if (dual) {
        d.BlendState.RenderTarget[0].BlendEnable = TRUE; d.BlendState.RenderTarget[0].SrcBlend = D3D12_BLEND_ONE;
        d.BlendState.RenderTarget[0].DestBlend = D3D12_BLEND_SRC1_COLOR; d.BlendState.RenderTarget[0].BlendOp = D3D12_BLEND_OP_ADD;
        d.BlendState.RenderTarget[0].SrcBlendAlpha = D3D12_BLEND_ONE; d.BlendState.RenderTarget[0].DestBlendAlpha = D3D12_BLEND_ZERO;
        d.BlendState.RenderTarget[0].BlendOpAlpha = D3D12_BLEND_OP_ADD;
    }
    hr = ID3D12Device_CreateGraphicsPipelineState(dev, &d, &IID_ID3D12PipelineState, (void **)&pso);
    printf("PROBE CreateGraphicsPipelineState with %d render targets%s -> %08lx\n", n, dual ? ", dual-source blend on target 0" : "", hr);
    Sleep(500);   /* D3DMetal may compile on a worker thread */
    return 0;
}

int main(int argc, char **argv)
{
    HMODULE d3d12;
    PFN_D3D12_CREATE_DEVICE pD3D12CreateDevice;
    ID3D12Device *dev = NULL;
    HRESULT hr;

    setvbuf(stdout, NULL, _IONBF, 0);
    d3d12 = LoadLibraryA("d3d12.dll");
    pD3D12CreateDevice = d3d12 ? (void *)GetProcAddress(d3d12, "D3D12CreateDevice") : NULL;
    hr = pD3D12CreateDevice ? pD3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev) : E_NOINTERFACE;
    printf("PROBE D3D12CreateDevice -> %08lx\n", hr);
    if (!dev) return 1;
    if (argc > 3 && !strcmp(argv[1], "pipeline")) pipeline(dev, argv[2], argv[3]);
    else if (argc > 4 && !strcmp(argv[1], "targets")) targets(dev, argv[2], argv[3], atoi(argv[4]), argc > 5 && !strcmp(argv[5], "dual"));
    else features(dev);
    ID3D12Device_Release(dev);
    printf("PROBE done\n");
    return 0;
}
