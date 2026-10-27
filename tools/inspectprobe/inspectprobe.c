/* inspectprobe: draws, every frame for a while, one triangle per case below, each losing its pixels at a known step,
 * so the shim's inspector (HB_TSSHIM_INSPECT=1, tools/tsshim/inspect.c) can be checked against the answer. No game.
 * The pipelines are created in this order, so the inspector numbers them 0 to 8:
 *   0 ok         depth LESS_EQUAL, writes depth 0.25 everywhere      written
 *   1 depth      depth EQUAL at 0.3, no write                        depth test
 *   2 discard    pixel shader discards every pixel                   discarded
 *   3 culled     back-facing triangle, cull BACK                     culled
 *   4 offscreen  triangle moved off the screen                       nothing on screen
 *   5 stencil    stencil test NEVER                                  stencil
 *   6 stream     as 1, through a pipeline state stream (DEPTH_STENCIL1) depth test
 *   7 indirect   no depth test, drawn only through ExecuteIndirect   written
 *   8 close      depth EQUAL at 0.2499998 (just in front of 0.25)     depth test, but LESS_EQUAL or a bias of 64 lets it through
 * Cases 1 and 6 lie behind the depth 0.25 case 0 wrote (GREATER_EQUAL lets them through, LESS_EQUAL does not).
 * Usage: inspectprobe.exe <vs.dxil> <ps_color.dxil> <ps_discard.dxil> [seconds, default 12] */
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

#define W 64
#define H 64
static const D3D12_DEPTH_STENCILOP_DESC never = { D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_KEEP, D3D12_COMPARISON_FUNC_NEVER };
static const D3D12_DEPTH_STENCILOP_DESC always = { D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_KEEP, D3D12_COMPARISON_FUNC_ALWAYS };

int main(int argc, char **argv)
{
    typedef HRESULT (WINAPI *PFN_Serialize)(const D3D12_ROOT_SIGNATURE_DESC *, D3D_ROOT_SIGNATURE_VERSION, ID3DBlob **, ID3DBlob **);
    HMODULE d3d12; PFN_D3D12_CREATE_DEVICE create; PFN_Serialize serialize;
    ID3D12Device *dev = NULL; ID3D12Device2 *dev2 = NULL; ID3D12CommandQueue *q = NULL; ID3D12RootSignature *rs = NULL; ID3DBlob *blob = NULL;
    ID3D12PipelineState *pso[9] = { 0 }; ID3D12Resource *rt = NULL, *ds = NULL, *args = NULL; ID3D12DescriptorHeap *rtvh = NULL, *dsvh = NULL;
    ID3D12CommandAllocator *alloc = NULL; ID3D12GraphicsCommandList *list = NULL; ID3D12Fence *fence = NULL; ID3D12CommandSignature *sig = NULL;
    D3D12_ROOT_PARAMETER param; D3D12_ROOT_SIGNATURE_DESC rsd; D3D12_GRAPHICS_PIPELINE_STATE_DESC base, d;
    D3D12_COMMAND_QUEUE_DESC qd = { D3D12_COMMAND_LIST_TYPE_DIRECT, 0, 0, 0 };
    D3D12_HEAP_PROPERTIES def = { D3D12_HEAP_TYPE_DEFAULT }, up = { D3D12_HEAP_TYPE_UPLOAD };
    D3D12_RESOURCE_DESC td = { D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, W, H, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 }, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET };
    D3D12_RESOURCE_DESC dd = { D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, W, H, 1, 1, DXGI_FORMAT_D32_FLOAT_S8X24_UINT, { 1, 0 }, D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL };
    D3D12_RESOURCE_DESC bd = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, 256, 1, 1, 1, DXGI_FORMAT_UNKNOWN, { 1, 0 }, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, 0 };
    D3D12_CLEAR_VALUE cc = { DXGI_FORMAT_R8G8B8A8_UNORM, { { 0, 0, 0, 0 } } }, dc = { DXGI_FORMAT_D32_FLOAT_S8X24_UINT };
    D3D12_DESCRIPTOR_HEAP_DESC rhd = { D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 1, 0, 0 }, dhd = { D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 1, 0, 0 };
    D3D12_INDIRECT_ARGUMENT_DESC arg = { D3D12_INDIRECT_ARGUMENT_TYPE_DRAW };
    D3D12_COMMAND_SIGNATURE_DESC sd = { sizeof(D3D12_DRAW_ARGUMENTS), 1, &arg, 0 };
    D3D12_CPU_DESCRIPTOR_HANDLE rtv, dsv; D3D12_VIEWPORT vp = { 0, 0, W, H, 0, 1 }; D3D12_RECT sc = { 0, 0, W, H };
    static const float consts[9][4] = { { 0, 0, 0.25f, 0 }, { 0, 0, 0.3f, 0 }, { 0, 0, 0.5f, 0 }, { 0, 0, 0.5f, 0 }, { 10, 0, 0.5f, 0 },
                                        { 0, 0, 0.5f, 1 }, { 0, 0, 0.3f, 1 }, { 0, 0, 0.5f, 1 }, { 0, 0, 0.2499998f, 0 } };
    FLOAT black[4] = { 0, 0, 0, 0 }; SIZE_T vs_size, psc_size, psd_size; void *vs, *psc, *psd, *map; HANDLE ev; HRESULT hr;
    DWORD seconds = argc > 4 ? (DWORD)atoi(argv[4]) : 12, start; UINT64 value = 0; int i, frames = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 4 || !(vs = read_file(argv[1], &vs_size)) || !(psc = read_file(argv[2], &psc_size)) || !(psd = read_file(argv[3], &psd_size))) {
        printf("PROBE usage: inspectprobe.exe <vs.dxil> <ps_color.dxil> <ps_discard.dxil> [seconds]\n"); return 1;
    }
    d3d12 = LoadLibraryA("d3d12.dll");
    create = d3d12 ? (void *)GetProcAddress(d3d12, "D3D12CreateDevice") : NULL;
    serialize = d3d12 ? (void *)GetProcAddress(d3d12, "D3D12SerializeRootSignature") : NULL;
    hr = create ? create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev) : E_NOINTERFACE;
    printf("PROBE D3D12CreateDevice -> %08lx\n", hr);
    if (!dev || !serialize) return 1;
    memset(&param, 0, sizeof param);
    param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS; param.Constants.Num32BitValues = 4; param.ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    rsd.NumParameters = 1; rsd.pParameters = &param; rsd.NumStaticSamplers = 0; rsd.pStaticSamplers = NULL; rsd.Flags = 0;
    if (FAILED(serialize(&rsd, D3D_ROOT_SIGNATURE_VERSION_1, &blob, NULL))
        || FAILED(ID3D12Device_CreateRootSignature(dev, 0, ID3D10Blob_GetBufferPointer(blob), ID3D10Blob_GetBufferSize(blob), &IID_ID3D12RootSignature, (void **)&rs))
        || FAILED(ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&q))) { printf("PROBE root signature / queue failed\n"); return 1; }

    memset(&base, 0, sizeof base);
    base.pRootSignature = rs; base.VS.pShaderBytecode = vs; base.VS.BytecodeLength = vs_size; base.PS.pShaderBytecode = psc; base.PS.BytecodeLength = psc_size;
    for (i = 0; i < 8; i++) base.BlendState.RenderTarget[i].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    base.SampleMask = ~0u; base.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID; base.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    base.RasterizerState.DepthClipEnable = TRUE; base.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    base.NumRenderTargets = 1; base.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM; base.DSVFormat = DXGI_FORMAT_D32_FLOAT_S8X24_UINT; base.SampleDesc.Count = 1;
    base.DepthStencilState.FrontFace = base.DepthStencilState.BackFace = always;
    base.DepthStencilState.StencilReadMask = base.DepthStencilState.StencilWriteMask = 0xff;
    for (i = 0; i < 9; i++) {
        d = base;
        if (i == 0) { d.DepthStencilState.DepthEnable = TRUE; d.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL; d.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS_EQUAL; }
        if (i == 1 || i == 8) { d.DepthStencilState.DepthEnable = TRUE; d.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_EQUAL; }
        if (i == 2) { d.PS.pShaderBytecode = psd; d.PS.BytecodeLength = psd_size; }
        if (i == 3) d.RasterizerState.CullMode = D3D12_CULL_MODE_BACK;
        if (i == 5) { d.DepthStencilState.StencilEnable = TRUE; d.DepthStencilState.FrontFace = d.DepthStencilState.BackFace = never; }
        if (i == 6) {
            struct {   /* each subobject type padded to pointer size, then its description */
                struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; ID3D12RootSignature *v; } root;
                struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; D3D12_SHADER_BYTECODE v; } vs, ps;
                struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; struct D3D12_RT_FORMAT_ARRAY v; } rtv;
                struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; DXGI_FORMAT v; } dsf;
                struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; D3D12_RASTERIZER_DESC v; } rast;
                struct { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE t; D3D12_DEPTH_STENCIL_DESC1 v; } depth;
            } s;
            D3D12_PIPELINE_STATE_STREAM_DESC ssd = { sizeof s, &s };
            memset(&s, 0, sizeof s);
            s.root.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_ROOT_SIGNATURE; s.root.v = rs;
            s.vs.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_VS; s.vs.v = base.VS;
            s.ps.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS; s.ps.v = base.PS;
            s.rtv.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS; s.rtv.v.NumRenderTargets = 1; s.rtv.v.RTFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
            s.dsf.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL_FORMAT; s.dsf.v = DXGI_FORMAT_D32_FLOAT_S8X24_UINT;
            s.rast.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER; s.rast.v = base.RasterizerState;
            s.depth.t = D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL1; s.depth.v.DepthEnable = TRUE;
            s.depth.v.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO; s.depth.v.DepthFunc = D3D12_COMPARISON_FUNC_EQUAL;
            s.depth.v.StencilReadMask = s.depth.v.StencilWriteMask = 0xff; s.depth.v.FrontFace = s.depth.v.BackFace = always;
            if (FAILED(ID3D12Device_QueryInterface(dev, &IID_ID3D12Device2, (void **)&dev2))) { printf("PROBE no ID3D12Device2\n"); return 1; }
            hr = ID3D12Device2_CreatePipelineState(dev2, &ssd, &IID_ID3D12PipelineState, (void **)&pso[i]);
        } else hr = ID3D12Device_CreateGraphicsPipelineState(dev, &d, &IID_ID3D12PipelineState, (void **)&pso[i]);
        printf("PROBE pipeline %d -> %08lx\n", i, hr);
        if (FAILED(hr)) return 1;
    }

    if (FAILED(ID3D12Device_CreateCommittedResource(dev, &def, 0, &td, D3D12_RESOURCE_STATE_RENDER_TARGET, &cc, &IID_ID3D12Resource, (void **)&rt))
        || FAILED(ID3D12Device_CreateCommittedResource(dev, &def, 0, &dd, D3D12_RESOURCE_STATE_DEPTH_WRITE, &dc, &IID_ID3D12Resource, (void **)&ds))
        || FAILED(ID3D12Device_CreateCommittedResource(dev, &up, 0, &bd, D3D12_RESOURCE_STATE_GENERIC_READ, NULL, &IID_ID3D12Resource, (void **)&args))
        || FAILED(ID3D12Device_CreateDescriptorHeap(dev, &rhd, &IID_ID3D12DescriptorHeap, (void **)&rtvh))
        || FAILED(ID3D12Device_CreateDescriptorHeap(dev, &dhd, &IID_ID3D12DescriptorHeap, (void **)&dsvh))
        || FAILED(ID3D12Device_CreateCommandSignature(dev, &sd, NULL, &IID_ID3D12CommandSignature, (void **)&sig))
        || FAILED(ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc))
        || FAILED(ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list))
        || FAILED(ID3D12Device_CreateFence(dev, 0, 0, &IID_ID3D12Fence, (void **)&fence))) { printf("PROBE setup failed\n"); return 1; }
    if (SUCCEEDED(ID3D12Resource_Map(args, 0, NULL, &map))) { D3D12_DRAW_ARGUMENTS a = { 3, 1, 0, 0 }; memcpy(map, &a, sizeof a); ID3D12Resource_Unmap(args, 0, NULL); }
    rtvh->lpVtbl->GetCPUDescriptorHandleForHeapStart(rtvh, &rtv);   /* the C binding returns through a pointer */
    dsvh->lpVtbl->GetCPUDescriptorHandleForHeapStart(dsvh, &dsv);
    ID3D12Device_CreateRenderTargetView(dev, rt, NULL, rtv);
    ID3D12Device_CreateDepthStencilView(dev, ds, NULL, dsv);
    ID3D12GraphicsCommandList_Close(list);
    ev = CreateEventA(NULL, FALSE, FALSE, NULL);

    for (start = GetTickCount(); GetTickCount() - start < seconds * 1000; frames++) {
        ID3D12CommandAllocator_Reset(alloc);
        ID3D12GraphicsCommandList_Reset(list, alloc, pso[0]);
        ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, black, 0, NULL);
        ID3D12GraphicsCommandList_ClearDepthStencilView(list, dsv, D3D12_CLEAR_FLAG_DEPTH | D3D12_CLEAR_FLAG_STENCIL, 0.5f, 0, 0, NULL);
        ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, &dsv);
        ID3D12GraphicsCommandList_RSSetViewports(list, 1, &vp);
        ID3D12GraphicsCommandList_RSSetScissorRects(list, 1, &sc);
        ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, rs);
        ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ID3D12GraphicsCommandList_OMSetStencilRef(list, 0);
        for (i = 0; i < 9; i++) {
            ID3D12GraphicsCommandList_SetPipelineState(list, pso[i]);
            ID3D12GraphicsCommandList_SetGraphicsRoot32BitConstants(list, 0, 4, consts[i], 0);
            if (i == 7) ID3D12GraphicsCommandList_ExecuteIndirect(list, sig, 1, args, 0, NULL, 0);
            else ID3D12GraphicsCommandList_DrawInstanced(list, 3, 1, 0, 0);
        }
        ID3D12GraphicsCommandList_Close(list);
        ID3D12CommandQueue_ExecuteCommandLists(q, 1, (ID3D12CommandList **)&list);
        ID3D12CommandQueue_Signal(q, fence, ++value);
        ID3D12Fence_SetEventOnCompletion(fence, value, ev);
        if (WaitForSingleObject(ev, 10000) != WAIT_OBJECT_0) { printf("PROBE frame %d did not finish\n", frames); return 1; }
        Sleep(5);
    }
    printf("PROBE frames %d, device removed reason %08lx\n", frames, ID3D12Device_GetDeviceRemovedReason(dev));
    printf("PROBE done\n");
    return 0;
}
