// dxilbench: reproduces, without the game and without Wine, what D3DMetal does with a pair of DirectX
// shaders: DXIL -> Metal through the Metal shader converter that ships inside D3DMetal.framework
// (libmetalirconverter.dylib), then a Metal render pipeline on this Mac's GPU. A pipeline Metal refuses
// here is one D3DMetal marks "no-op" in the game. HLSL test shaders are compiled with the DXC that
// ships beside it (libdxcompiler.dylib). x86_64 only, like those libraries (runs under Rosetta).
//
// Usage: dxilbench selftest                  synthetic VS + PS reading SV_ShadingRate, before/after the fix
//        dxilbench pair <vs.dxil> <ps.dxil>  a dumped game pipeline, before/after the fix
//        dxilbench ps <ps.dxil>              convert one pixel shader, print the converter's verdict
//        dxilbench emit <dir>                write the selftest shaders as <dir>/vs.dxil and <dir>/ps.dxil (tools/vrsprobe)
//        dxilbench dis <file>                DXC's disassembly of a shader
//        dxilbench settings <ps.dxil>        the pixel shader under each per-pipeline setting D3DMetal gives the
//                                            converter (dual-source blending, depth feedback, int/unorm8 target
//                                            masks, sample mask): which one makes the fragment function fail
//        [SCAN_ALL=1] dxilbench scan <dir>   every <digest>.ps (and .vs with SCAN_ALL) that HB_TSSHIM_DUMP wrote: which ones the converter or
//                                            Metal refuse, and which read SV_ShadingRate
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <vector>

extern "C" {
#include "../tsshim/dxil_shadingrate.h"
}

static std::string res_dir()
{
    const char *e = getenv("D3DM_RESOURCES");
    return e ? e : "/Users/alexandre/.codex/visualizations/2026/10/19/01a1562c-64fc-74c0-9f71-acf814cbaad7/Blackwell FH6 Final.app/Contents/Resources/GPTK4/external/D3DMetal.framework/Versions/A/Resources";
}

// ---- DXC (libdxcompiler.dylib), with the non-Windows COM layout of its WinAdapter.h (no virtual destructor) --
struct GUIDX { uint32_t a; uint16_t b, c; uint8_t d[8]; };
struct IUnknownX {
    virtual int32_t QueryInterface(const GUIDX &, void **) = 0;
    virtual unsigned long AddRef() = 0;
    virtual unsigned long Release() = 0;
};
struct IDxcBlobX : IUnknownX { virtual void *GetBufferPointer() = 0; virtual size_t GetBufferSize() = 0; };
struct IDxcBlobEncodingX : IDxcBlobX { virtual int32_t GetEncoding(int *, uint32_t *) = 0; };
struct IDxcOperationResultX : IUnknownX {
    virtual int32_t GetStatus(int32_t *) = 0; virtual int32_t GetResult(IDxcBlobX **) = 0; virtual int32_t GetErrorBuffer(IDxcBlobEncodingX **) = 0;
};
struct IDxcLibraryX : IUnknownX {
    virtual int32_t SetMalloc(void *) = 0; virtual int32_t CreateBlobFromBlob(IDxcBlobX *, uint32_t, uint32_t, IDxcBlobX **) = 0;
    virtual int32_t CreateBlobFromFile(const wchar_t *, uint32_t *, IDxcBlobEncodingX **) = 0;
    virtual int32_t CreateBlobWithEncodingFromPinned(const void *, uint32_t, uint32_t, IDxcBlobEncodingX **) = 0;
};
struct IDxcCompilerX : IUnknownX {
    virtual int32_t Compile(IDxcBlobX *, const wchar_t *, const wchar_t *, const wchar_t *, const wchar_t **, uint32_t, const void *, uint32_t,
                         void *, IDxcOperationResultX **) = 0;
    virtual int32_t Preprocess(IDxcBlobX *, const wchar_t *, const wchar_t **, uint32_t, const void *, uint32_t, void *, IDxcOperationResultX **) = 0;
    virtual int32_t Disassemble(IDxcBlobX *, IDxcBlobEncodingX **) = 0;
};
static const GUIDX CLSID_DxcCompilerX = { 0x73e22d93, 0xe6ce, 0x47f3, { 0xb5, 0xbf, 0xf0, 0x66, 0x4f, 0x39, 0xc1, 0xb0 } };
static const GUIDX CLSID_DxcLibraryX = { 0x6245d6af, 0x66e0, 0x48fd, { 0x80, 0xb4, 0x4d, 0x27, 0x17, 0x96, 0x74, 0x8c } };
static const GUIDX IID_IDxcCompilerX = { 0x8c210bf3, 0x011f, 0x4422, { 0x8d, 0x70, 0x6f, 0x9a, 0xcb, 0x8d, 0xb6, 0x17 } };
static const GUIDX CLSID_DxcAssemblerX = { 0xd728db68, 0xf903, 0x4f80, { 0x94, 0xcd, 0xdc, 0xcf, 0x76, 0xec, 0x71, 0x51 } };
static const GUIDX IID_IDxcAssemblerX = { 0x091f7a26, 0x1c1f, 0x4948, { 0x90, 0x4b, 0xe6, 0xe3, 0xa8, 0xa7, 0x71, 0xd5 } };
struct IDxcAssemblerX : IUnknownX { virtual int32_t AssembleToContainer(IDxcBlobX *, IDxcOperationResultX **) = 0; };
static IDxcAssemblerX *dxcasm;
static const GUIDX IID_IDxcLibraryX = { 0xe5204dc7, 0xd18c, 0x4c3c, { 0xbd, 0xfb, 0x85, 0x16, 0x73, 0x98, 0x0f, 0xe7 } };
typedef int32_t (*PFN_DxcCreateInstance)(const GUIDX &, const GUIDX &, void **);
static IDxcCompilerX *dxc; static IDxcLibraryX *dxclib;

static bool dxc_init()
{
    void *h = dlopen((res_dir() + "/libdxcompiler.dylib").c_str(), RTLD_NOW);
    PFN_DxcCreateInstance create = h ? (PFN_DxcCreateInstance)dlsym(h, "DxcCreateInstance") : NULL;
    if (!create) { printf("BENCH cannot load libdxcompiler.dylib: %s\n", dlerror()); return false; }
    int32_t hr1 = create(CLSID_DxcCompilerX, IID_IDxcCompilerX, (void **)&dxc), hr2 = create(CLSID_DxcLibraryX, IID_IDxcLibraryX, (void **)&dxclib);
    if (hr1 || hr2) { printf("BENCH DxcCreateInstance failed %x %x\n", hr1, hr2); return false; }
    if (create(CLSID_DxcAssemblerX, IID_IDxcAssemblerX, (void **)&dxcasm)) dxcasm = NULL;
    return true;
}

static std::vector<uint8_t> dxc_compile(const char *src, const wchar_t *profile)
{
    std::vector<uint8_t> out; IDxcBlobEncodingX *blob = NULL; IDxcOperationResultX *res = NULL; int32_t status = -1;
    const wchar_t *args[] = { L"-Qembed_debug" };
    dxclib->CreateBlobWithEncodingFromPinned(src, (uint32_t)strlen(src), 65001, &blob);
    if (dxc->Compile(blob, L"bench.hlsl", L"main", profile, args, 0, NULL, 0, NULL, &res) || !res) { printf("BENCH Compile call failed\n"); return out; }
    res->GetStatus(&status);
    if (status) {
        IDxcBlobEncodingX *err = NULL; res->GetErrorBuffer(&err);
        printf("BENCH dxc status %x, error (%zu bytes): %.*s\n", status, err ? err->GetBufferSize() : 0,
               err ? (int)err->GetBufferSize() : 0, err ? (const char *)err->GetBufferPointer() : "");
        return out;
    }
    IDxcBlobX *b = NULL; res->GetResult(&b);
    out.assign((uint8_t *)b->GetBufferPointer(), (uint8_t *)b->GetBufferPointer() + b->GetBufferSize());
    return out;
}

static std::string dxc_disasm_text(const std::vector<uint8_t> &dxil)
{
    IDxcBlobEncodingX *blob = NULL, *text = NULL;
    dxclib->CreateBlobWithEncodingFromPinned(dxil.data(), (uint32_t)dxil.size(), 0, &blob);
    if (dxc->Disassemble(blob, &text) || !text) return "";
    return std::string((const char *)text->GetBufferPointer(), text->GetBufferSize());
}

// LLVM IR text (DXC's disassembly, edited) back to a DXIL container, or empty with the assembler's error printed.
static std::vector<uint8_t> dxc_assemble(const std::string &ir)
{
    std::vector<uint8_t> out; IDxcBlobEncodingX *blob = NULL; IDxcOperationResultX *res = NULL; int32_t status = -1;
    if (!dxcasm) { printf("BENCH this libdxcompiler has no assembler\n"); return out; }
    dxclib->CreateBlobWithEncodingFromPinned(ir.data(), (uint32_t)ir.size(), 65001, &blob);
    if (dxcasm->AssembleToContainer(blob, &res) || !res) { printf("BENCH AssembleToContainer call failed\n"); return out; }
    res->GetStatus(&status);
    if (status) {
        IDxcBlobEncodingX *err = NULL; res->GetErrorBuffer(&err);
        printf("BENCH assembler status %x: %.*s\n", status, err ? (int)err->GetBufferSize() : 0, err ? (const char *)err->GetBufferPointer() : "");
        return out;
    }
    IDxcBlobX *b = NULL; res->GetResult(&b);
    out.assign((uint8_t *)b->GetBufferPointer(), (uint8_t *)b->GetBufferPointer() + b->GetBufferSize());
    return out;
}

static void dxc_disasm(const std::vector<uint8_t> &dxil, const char *grep)
{
    IDxcBlobEncodingX *blob = NULL, *text = NULL;
    dxclib->CreateBlobWithEncodingFromPinned(dxil.data(), (uint32_t)dxil.size(), 0, &blob);
    if (dxc->Disassemble(blob, &text) || !text) { printf("BENCH disassembly failed\n"); return; }
    std::string s((const char *)text->GetBufferPointer(), text->GetBufferSize());
    size_t a = 0;
    while (a < s.size()) {
        size_t b = s.find('\n', a); if (b == std::string::npos) b = s.size();
        std::string line = s.substr(a, b - a);
        if (!grep || strstr(line.c_str(), grep)) printf("   | %s\n", line.c_str());
        a = b + 1;
    }
}

// ---- Metal shader converter (libmetalirconverter.dylib), its public C API ---------------------
typedef struct IRCompiler IRCompiler; typedef struct IRObject IRObject; typedef struct IRError IRError;
typedef struct IRMetalLibBinary IRMetalLibBinary; typedef struct IRShaderReflection IRShaderReflection;
static IRCompiler *(*pIRCompilerCreate)(void);
static IRObject *(*pIRObjectCreateFromDXIL)(const uint8_t *, size_t, int);
static IRObject *(*pIRCompilerAllocCompileAndLink)(IRCompiler *, const char *, const IRObject *, IRError **);
static int (*pIRObjectGetMetalIRShaderStage)(const IRObject *);
static IRMetalLibBinary *(*pIRMetalLibBinaryCreate)(void);
static bool (*pIRObjectGetMetalLibBinary)(const IRObject *, int, IRMetalLibBinary *);
static size_t (*pIRMetalLibGetBytecodeSize)(const IRMetalLibBinary *);
static size_t (*pIRMetalLibGetBytecode)(const IRMetalLibBinary *, uint8_t *);
static uint32_t (*pIRErrorGetCode)(const IRError *);
static const void *(*pIRErrorGetPayload)(const IRError *);
static IRShaderReflection *(*pIRShaderReflectionCreate)(void);
static bool (*pIRObjectGetReflection)(const IRObject *, int, IRShaderReflection *);
static const char *(*pIRShaderReflectionCopyJSONString)(const IRShaderReflection *);
static IRCompiler *irc;
static void (*pIRCompilerSetDualSourceBlendingConfiguration)(IRCompiler *, int);
static void (*pIRCompilerSetDepthFeedbackConfiguration)(IRCompiler *, int);
static void (*pIRCompilerSetIntRTMask)(IRCompiler *, uint8_t);
static void (*pIRCompilerSetSampleMask)(IRCompiler *, uint32_t);
static void (*pIRCompilerSetUnorm8RTMask)(IRCompiler *, uint8_t);

static bool ir_init()
{
    void *h = dlopen((res_dir() + "/libmetalirconverter.dylib").c_str(), RTLD_NOW);
    if (!h) { printf("BENCH cannot load libmetalirconverter.dylib: %s\n", dlerror()); return false; }
#define SYM(n) if (!(*(void **)&p##n = dlsym(h, #n))) { printf("BENCH missing %s\n", #n); return false; }
    SYM(IRCompilerCreate) SYM(IRObjectCreateFromDXIL) SYM(IRCompilerAllocCompileAndLink) SYM(IRObjectGetMetalIRShaderStage)
    SYM(IRMetalLibBinaryCreate) SYM(IRObjectGetMetalLibBinary) SYM(IRMetalLibGetBytecodeSize) SYM(IRMetalLibGetBytecode)
    SYM(IRErrorGetCode) SYM(IRErrorGetPayload) SYM(IRShaderReflectionCreate) SYM(IRObjectGetReflection) SYM(IRShaderReflectionCopyJSONString)
    SYM(IRCompilerSetDualSourceBlendingConfiguration) SYM(IRCompilerSetDepthFeedbackConfiguration) SYM(IRCompilerSetIntRTMask) SYM(IRCompilerSetSampleMask)
    *(void **)&pIRCompilerSetUnorm8RTMask = dlsym(h, "_Z25IRCompilerSetUnorm8RTMaskP10IRCompilerh");
    irc = pIRCompilerCreate();
    return irc != NULL;
}

struct Converted { id<MTLFunction> fn; std::string json; };

static Converted ir_convert(id<MTLDevice> dev, const std::vector<uint8_t> &dxil, const char *what)
{
    Converted c = { nil, "" }; IRError *err = NULL; IRCompiler *comp = irc;
    if (getenv("BENCH_DUAL")) {   // like D3DMetal: a compiler per stage, with its five settings for a target 0 that blends with SRC1
        comp = pIRCompilerCreate();
        pIRCompilerSetDualSourceBlendingConfiguration(comp, 1); pIRCompilerSetDepthFeedbackConfiguration(comp, 2);
        pIRCompilerSetIntRTMask(comp, 0); if (pIRCompilerSetUnorm8RTMask) pIRCompilerSetUnorm8RTMask(comp, 0); pIRCompilerSetSampleMask(comp, ~0u);
    }
    IRObject *in = pIRObjectCreateFromDXIL(dxil.data(), dxil.size(), 0);
    IRObject *out = in ? pIRCompilerAllocCompileAndLink(comp, NULL, in, &err) : NULL;
    if (!out) {
        printf("BENCH %s: converter refused it (code %u%s%s)\n", what, err ? pIRErrorGetCode(err) : 0,
               err && pIRErrorGetPayload(err) ? ", " : "", err && pIRErrorGetPayload(err) ? (const char *)pIRErrorGetPayload(err) : "");
        return c;
    }
    int stage = pIRObjectGetMetalIRShaderStage(out);
    IRMetalLibBinary *lib = pIRMetalLibBinaryCreate();
    pIRObjectGetMetalLibBinary(out, stage, lib);
    std::vector<uint8_t> bytes(pIRMetalLibGetBytecodeSize(lib));
    pIRMetalLibGetBytecode(lib, bytes.data());
    IRShaderReflection *refl = pIRShaderReflectionCreate();
    if (pIRObjectGetReflection(out, stage, refl)) c.json = pIRShaderReflectionCopyJSONString(refl);
    dispatch_data_t data = dispatch_data_create(bytes.data(), bytes.size(), NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *e = nil; id<MTLLibrary> ml = [dev newLibraryWithData:data error:&e];
    if (!ml) { printf("BENCH %s: Metal refused the library: %s\n", what, e.localizedDescription.UTF8String); return c; }
    c.fn = [ml newFunctionWithName:ml.functionNames.firstObject];
    return c;
}

// Vertex attributes of the converted vertex function, so the pipeline gets the vertex descriptor it needs.
static MTLVertexDescriptor *vertex_descriptor(id<MTLFunction> vs)
{
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor]; NSUInteger off = 0; bool any = false;
    for (MTLVertexAttribute *a in vs.vertexAttributes) {
        if (!a.active) continue;
        MTLVertexFormat f = MTLVertexFormatFloat4;
        switch (a.attributeType) {
        case MTLDataTypeUInt: f = MTLVertexFormatUInt; break;   case MTLDataTypeUInt2: f = MTLVertexFormatUInt2; break;
        case MTLDataTypeUInt3: f = MTLVertexFormatUInt3; break; case MTLDataTypeUInt4: f = MTLVertexFormatUInt4; break;
        case MTLDataTypeInt: f = MTLVertexFormatInt; break;     case MTLDataTypeInt2: f = MTLVertexFormatInt2; break;
        case MTLDataTypeInt3: f = MTLVertexFormatInt3; break;   case MTLDataTypeInt4: f = MTLVertexFormatInt4; break;
        default: break;
        }
        vd.attributes[a.attributeIndex].format = f; vd.attributes[a.attributeIndex].offset = off; vd.attributes[a.attributeIndex].bufferIndex = 30;
        off += 16; any = true;
    }
    if (!any) return nil;
    vd.layouts[30].stride = off;
    return vd;
}

// 0: pipeline created; 1: Metal refused it; 2: a shader did not convert
static int try_pipeline(id<MTLDevice> dev, const std::vector<uint8_t> &vs, const std::vector<uint8_t> &ps, const char *label)
{
    Converted v = ir_convert(dev, vs, "vertex shader"), p = ir_convert(dev, ps, "pixel shader");
    if (!v.fn || !p.fn) { printf("BENCH %s: CONVERSION FAILED\n", label); return 2; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = v.fn; d.fragmentFunction = p.fn; d.vertexDescriptor = vertex_descriptor(v.fn);
    for (int i = 0; i < 8; i++) d.colorAttachments[i].pixelFormat = MTLPixelFormatRGBA16Float;
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *e = nil; id<MTLRenderPipelineState> st = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    for (MTLVertexAttribute *a in p.fn.stageInputAttributes) if (a.active) printf("BENCH %s: fragment input %s\n", label, a.name.UTF8String);
    if (st) { printf("BENCH %s: PIPELINE OK\n", label); return 0; }
    printf("BENCH %s: PIPELINE REFUSED: %s\n", label, e.localizedDescription.UTF8String);
    return 1;
}

static std::vector<uint8_t> read_file(const char *path)
{
    std::vector<uint8_t> v; FILE *f = fopen(path, "rb"); long n;
    if (!f) { printf("BENCH cannot open %s\n", path); return v; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET); v.resize(n);
    if (fread(v.data(), 1, n, f) != (size_t)n) v.clear();
    fclose(f); return v;
}

static void digest_check(const std::vector<uint8_t> &c, const char *label)
{
    unsigned char d[16]; dxil_container_digest(c.data(), c.size(), d);
    printf("BENCH %s: stored digest %s computed digest\n", label, memcmp(d, c.data() + 4, 16) ? "DIFFERS FROM" : "matches");
}

// Draws one full-screen triangle into a 1x1 RGBA32Float target and returns the blue channel the pixel
// shader wrote (the selftest shader writes 1 when it read a shading rate of 0).
static float render_check(id<MTLDevice> dev, const std::vector<uint8_t> &vs, const std::vector<uint8_t> &ps)
{
    Converted v = ir_convert(dev, vs, "vertex shader"), p = ir_convert(dev, ps, "pixel shader");
    if (!v.fn || !p.fn) return -1;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = v.fn; d.fragmentFunction = p.fn; d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    NSError *e = nil; id<MTLRenderPipelineState> st = [dev newRenderPipelineStateWithDescriptor:d error:&e];
    if (!st) return -2;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(-7, -7, -7, -7); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    [enc setRenderPipelineState:st];
    // the converter's shaders take their root signature through a top-level argument buffer (index 2)
    // and draw parameters through buffer 20 or so; an empty buffer covers both for this shader
    id<MTLBuffer> zero = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    for (int i = 0; i < 31; i++) { [enc setVertexBuffer:zero offset:0 atIndex:i]; [enc setFragmentBuffer:zero offset:0 atIndex:i]; }
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    float px[4] = { -9, -9, -9, -9 };
    [rt getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
    printf("BENCH rendered pixel: %g %g %g %g%s\n", px[0], px[1], px[2], px[3], cb.error ? " (GPU error)" : "");
    return px[2];
}

static int fix_and_report(std::vector<uint8_t> &ps, const char *label)
{
    char why[256] = "";
    int r = dxil_fix_shadingrate_input(ps.data(), ps.size(), why, sizeof why);
    printf("BENCH %s: fix -> %d (%s)\n", label, r, why);
    return r;
}

static const char *VS_HLSL =
    "struct O { float4 pos : SV_Position; float2 uv : TEXCOORD0; nointerpolation uint id : TEXCOORD1; };\n"
    "O main(uint id : SV_VertexID) { O o; o.uv = float2((id << 1) & 2, id & 2); o.pos = float4(o.uv * 2 - 1, 0, 1); o.id = id; return o; }\n";
static const char *PS_HLSL =
    "float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0, nointerpolation uint id : TEXCOORD1, uint rate : SV_ShadingRate) : SV_Target\n"
    "{ return float4(uv, rate == 0 ? 1 : 0, id); }\n";

int main(int argc, char **argv)
{
    @autoreleasepool {
        const char *mode = argc > 1 ? argv[1] : "selftest";
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        setvbuf(stdout, NULL, _IONBF, 0);
        printf("BENCH GPU %s, mode %s\n", dev.name.UTF8String, mode);
        if (!ir_init()) return 1;
        if (!strcmp(mode, "selftest")) {
            if (!dxc_init()) return 1;
            std::vector<uint8_t> vs = dxc_compile(VS_HLSL, L"vs_6_6"), ps = dxc_compile(PS_HLSL, L"ps_6_6");
            if (vs.empty() || ps.empty()) return 1;
            printf("BENCH compiled vs %zu bytes, ps %zu bytes\n", vs.size(), ps.size());
            dxc_disasm(ps, "SV_ShadingRate");
            int before = try_pipeline(dev, vs, ps, "before");
            std::vector<uint8_t> fixed = ps;
            if (fix_and_report(fixed, "selftest") <= 0) return 1;
            digest_check(ps, "compiled");
            digest_check(fixed, "fixed");
            dxc_disasm(fixed, "SV_");
            int after = try_pipeline(dev, vs, fixed, "after");
            float blue = after == 0 ? render_check(dev, vs, fixed) : -1;
            printf("BENCH RESULT before=%s after=%s shading rate read after the fix=%s\n", before == 1 ? "refused" : before ? "conversion failed" : "ok",
                   after == 1 ? "refused" : after ? "conversion failed" : "ok", blue == 1 ? "0 (1x1)" : "NOT 0");
            return !(before == 1 && after == 0 && blue == 1);
        }
        if (!strcmp(mode, "emit") && argc > 2) {
            if (!dxc_init()) return 1;
            std::vector<uint8_t> vs = dxc_compile(VS_HLSL, L"vs_6_6"), ps = dxc_compile(PS_HLSL, L"ps_6_6");
            std::string d = argv[2]; FILE *f;
            if (vs.empty() || ps.empty()) return 1;
            if (!(f = fopen((d + "/vs.dxil").c_str(), "wb"))) return 1; fwrite(vs.data(), 1, vs.size(), f); fclose(f);
            if (!(f = fopen((d + "/ps.dxil").c_str(), "wb"))) return 1; fwrite(ps.data(), 1, ps.size(), f); fclose(f);
            printf("BENCH wrote %s/vs.dxil (%zu bytes) and %s/ps.dxil (%zu bytes)\n", argv[2], vs.size(), argv[2], ps.size());
            return 0;
        }
        if (!strcmp(mode, "variants")) {   // which system value a pixel shader may read when the vertex shader does not write it
            static const char *sem[] = { "SV_ShadingRate", "SV_RenderTargetArrayIndex", "SV_ViewportArrayIndex", "SV_SampleIndex", "SV_PrimitiveID", "SV_IsFrontFace" };
            if (!dxc_init()) return 1;
            std::vector<uint8_t> vs = dxc_compile(VS_HLSL, L"vs_6_6");
            for (const char *s : sem) {
                char src[512];
                snprintf(src, sizeof src, "float4 main(float4 pos : SV_Position, float2 uv : TEXCOORD0, nointerpolation uint id : TEXCOORD1, %s v : %s) : SV_Target\n"
                         "{ return float4(uv, v == 0 ? 1 : 0, id); }\n", strcmp(s, "SV_IsFrontFace") ? "uint" : "bool", s);
                std::vector<uint8_t> ps = dxc_compile(src, L"ps_6_6");
                if (!ps.empty()) { dxc_disasm(ps, s); try_pipeline(dev, vs, ps, s); }
            }
            return 0;
        }
        if (!strcmp(mode, "pair") && argc > 3) {
            std::vector<uint8_t> vs = read_file(argv[2]), ps = read_file(argv[3]);
            if (vs.empty() || ps.empty()) return 1;
            int before = try_pipeline(dev, vs, ps, "before");
            if (fix_and_report(ps, argv[3]) <= 0) return before;
            int after = try_pipeline(dev, vs, ps, "after");
            printf("BENCH RESULT before=%d after=%d\n", before, after);
            return after;
        }
        if (!strcmp(mode, "settings") && argc > 2) {
            std::vector<uint8_t> ps = read_file(argv[2]);
            struct { const char *what; int dual, depth; uint8_t intmask, unorm8; uint32_t samplemask; } v[] = {
                { "D3DMetal defaults (dual off, depth feedback off, masks 0, sample mask ~0)", 2, 2, 0, 0, ~0u },
                { "dual-source blending on", 1, 2, 0, 0, ~0u },
                { "depth feedback on", 2, 1, 0, 0, ~0u },
                { "int render target 0", 2, 2, 1, 0, ~0u },
                { "unorm8 render target 0", 2, 2, 0, 1, ~0u },
                { "sample mask 0", 2, 2, 0, 0, 0 },
                { "sample mask 1", 2, 2, 0, 0, 1 },
                { "sample mask 0xf", 2, 2, 0, 0, 0xf },
            };
            if (ps.empty()) return 1;
            for (auto &x : v) {
                irc = pIRCompilerCreate();
                pIRCompilerSetDualSourceBlendingConfiguration(irc, x.dual); pIRCompilerSetDepthFeedbackConfiguration(irc, x.depth);
                pIRCompilerSetIntRTMask(irc, x.intmask); if (pIRCompilerSetUnorm8RTMask) pIRCompilerSetUnorm8RTMask(irc, x.unorm8);
                pIRCompilerSetSampleMask(irc, x.samplemask);
                Converted c = ir_convert(dev, ps, x.what);
                printf("SETTINGS %-75s -> %s\n", x.what, c.fn ? "compiles" : "FAILS");
            }
            return 0;
        }
        if (!strcmp(mode, "dualtest")) {   // which pixel shaders the converter accepts with dual-source blending forced on
            static const char *src[] = {
                "struct O { float4 a : SV_Target0; float4 b : SV_Target1; }; O main(float4 p : SV_Position) { O o; o.a = p; o.b = p * 2; return o; }",
                "struct O { float4 a : SV_Target0; float4 b : SV_Target1; float4 c : SV_Target2; }; O main(float4 p : SV_Position) { O o; o.a = p; o.b = p * 2; o.c = p * 3; return o; }",
                "float4 main(float4 p : SV_Position) : SV_Target0 { return p; }",
            };
            static const char *what[] = { "writes targets 0 and 1", "writes targets 0, 1 and 2", "writes target 0 only" };
            if (!dxc_init()) return 1;
            for (int i = 0; i < 3; i++) {
                std::vector<uint8_t> ps = dxc_compile(src[i], L"ps_6_6");
                irc = pIRCompilerCreate(); pIRCompilerSetDualSourceBlendingConfiguration(irc, 1);
                Converted c = ir_convert(dev, ps, what[i]);
                printf("DUAL %-28s -> %s\n", what[i], c.fn ? "accepted" : "REFUSED");
            }
            return 0;
        }
        if (!strcmp(mode, "unwritten")) {   // a colour attachment the pixel shader does not write: kept (as on PC GPUs) or overwritten?
            if (!dxc_init()) return 1;
            std::vector<uint8_t> vs = dxc_compile(VS_HLSL, L"vs_6_6");
            std::vector<uint8_t> ps = dxc_compile("struct O { float4 b : SV_Target1; }; O main(float4 p : SV_Position) { O o; o.b = float4(0.25, 0.5, 0.75, 1); return o; }", L"ps_6_6");
            for (int mask = 0; mask < 2; mask++) {
                Converted v = ir_convert(dev, vs, "vs"), p = ir_convert(dev, ps, "ps");
                MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
                d.vertexFunction = v.fn; d.fragmentFunction = p.fn;
                d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float; d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
                if (mask) d.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
                NSError *e = nil; id<MTLRenderPipelineState> st = [dev newRenderPipelineStateWithDescriptor:d error:&e];
                if (!st) { printf("UNWRITTEN pipeline refused: %s\n", e.localizedDescription.UTF8String); return 1; }
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:4 height:4 mipmapped:NO];
                td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
                id<MTLTexture> t0 = [dev newTextureWithDescriptor:td], t1 = [dev newTextureWithDescriptor:td];
                id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = t0; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.colorAttachments[1].texture = t1; rp.colorAttachments[1].loadAction = MTLLoadActionClear; rp.colorAttachments[1].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:st];
                id<MTLBuffer> zero = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
                for (int k = 0; k < 31; k++) { [enc setVertexBuffer:zero offset:0 atIndex:k]; [enc setFragmentBuffer:zero offset:0 atIndex:k]; }
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
                uint16_t h[16] = { 0 };
                [t0 getBytes:h bytesPerRow:32 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
                __fp16 *f = (__fp16 *)h;
                printf("UNWRITTEN attachment 0 (cleared to 1 0 1 1), write mask %s: after the draw %g %g %g %g -> %s\n", mask ? "none" : "all",
                       (float)f[0], (float)f[1], (float)f[2], (float)f[3], (f[0] == 1 && f[1] == 0 && f[2] == 1) ? "kept" : "OVERWRITTEN");
            }
            return 0;
        }
        if (!strcmp(mode, "nantest")) {   // what saturate(), min and max give for a NaN made at run time (D3D: saturate(NaN) = 0)
            // the NaN is made from bits at run time (id is 0), so neither DXC nor Metal can fold it away
            static const char *src[] = {
                "float4 main(float4 p : SV_Position, float2 uv : TEXCOORD0, nointerpolation uint id : TEXCOORD1) : SV_Target { float n = asfloat(0x7fc00000u | id); return float4(saturate(n), 0.25, 0.25, 0.25); }",
                "float4 main(float4 p : SV_Position, float2 uv : TEXCOORD0, nointerpolation uint id : TEXCOORD1) : SV_Target { float n = asfloat(0x7fc00000u | id); return float4(min(max(n, 0.0), 1.0), 0.25, 0.25, 0.25); }",
                "float4 main(float4 p : SV_Position, float2 uv : TEXCOORD0, nointerpolation uint id : TEXCOORD1) : SV_Target { float n = asfloat(0x7f800000u | id); return float4(saturate(n), 0.25, 0.25, 0.25); }",
            };
            static const char *what[] = { "saturate(NaN)  [D3D: 0]", "min(max(NaN,0),1) [D3D: 0]", "saturate(+inf) [D3D: 1]" };
            if (!dxc_init()) return 1;
            std::vector<uint8_t> vs = dxc_compile(VS_HLSL, L"vs_6_6");
            for (int i = 0; i < 3; i++) {
                std::vector<uint8_t> ps = dxc_compile(src[i], L"ps_6_6");
                Converted v = ir_convert(dev, vs, "vs"), p = ir_convert(dev, ps, "ps");
                MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
                d.vertexFunction = v.fn; d.fragmentFunction = p.fn; d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
                NSError *e = nil; id<MTLRenderPipelineState> st = [dev newRenderPipelineStateWithDescriptor:d error:&e];
                if (!st) { printf("NAN %s: pipeline refused\n", what[i]); continue; }
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:1 height:1 mipmapped:NO];
                td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
                id<MTLTexture> rt = [dev newTextureWithDescriptor:td];
                id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                [enc setRenderPipelineState:st];
                id<MTLBuffer> zero = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
                for (int k = 0; k < 31; k++) { [enc setVertexBuffer:zero offset:0 atIndex:k]; [enc setFragmentBuffer:zero offset:0 atIndex:k]; }
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
                float px[4] = { -9, -9, -9, -9 };
                [rt getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0];
                printf("NAN %-30s -> Metal gives %g\n", what[i], px[0]);
            }
            return 0;
        }
        if (!strcmp(mode, "ll") && argc > 3) {        // raw disassembly to a file (for nansafe.py)
            std::vector<uint8_t> b = read_file(argv[2]);
            if (b.empty() || !dxc_init()) return 1;
            std::string ir = dxc_disasm_text(b); FILE *f = fopen(argv[3], "w");
            if (!f || ir.empty()) return 1;
            fwrite(ir.data(), 1, ir.size(), f); fclose(f); return 0;
        }
        if (!strcmp(mode, "asm") && argc > 3) {       // LLVM IR text to a DXIL container file
            std::vector<uint8_t> t = read_file(argv[2]);
            if (t.empty() || !dxc_init()) return 1;
            std::vector<uint8_t> c = dxc_assemble(std::string(t.begin(), t.end()));
            FILE *f = c.empty() ? NULL : fopen(argv[3], "wb");
            if (!f) return 1;
            fwrite(c.data(), 1, c.size(), f); fclose(f); return 0;
        }
        if (!strcmp(mode, "emitnan") && argc > 2) {   // the saturate(0/0) test pixel shader, for nansafe.py
            if (!dxc_init()) return 1;
            std::vector<uint8_t> ps = dxc_compile("float4 main(float4 p : SV_Position, float2 uv : TEXCOORD0, nointerpolation uint id : TEXCOORD1) : SV_Target { float n = asfloat(0x7fc00000u | id); return float4(saturate(n), saturate(uv.x * 3.0), 0.25, 0.25); }", L"ps_6_6");
            FILE *f = ps.empty() ? NULL : fopen(argv[2], "wb");
            if (!f) return 1;
            fwrite(ps.data(), 1, ps.size(), f); fclose(f); return 0;
        }
        if (!strcmp(mode, "renderps") && argc > 2) {  // draws the selftest vertex shader with this pixel shader, prints the pixel
            std::vector<uint8_t> ps = read_file(argv[2]);
            if (ps.empty() || !dxc_init()) return 1;
            std::vector<uint8_t> vs = dxc_compile(VS_HLSL, L"vs_6_6");
            float r = render_check(dev, vs, ps);
            return r < -1.5f;
        }
        if (!strcmp(mode, "roundtrip") && argc > 2) {   // disassemble, assemble back, convert: can game shaders be edited as text?
            std::vector<uint8_t> b = read_file(argv[2]);
            if (b.empty() || !dxc_init()) return 1;
            std::string ir = dxc_disasm_text(b);
            std::vector<uint8_t> back = dxc_assemble(ir);
            printf("BENCH roundtrip: %zu bytes -> %zu chars of IR -> %zu bytes\n", b.size(), ir.size(), back.size());
            if (back.empty()) return 1;
            Converted c = ir_convert(dev, back, "reassembled");
            printf("BENCH reassembled shader %s\n", c.fn ? "converts" : "does NOT convert");
            return !c.fn;
        }
        if (!strcmp(mode, "hlsl") && argc > 4) {   // compile an HLSL file (entry point main) for a profile, e.g. ps_6_6
            std::vector<uint8_t> src = read_file(argv[2]); std::string text(src.begin(), src.end());
            std::wstring profile(argv[3], argv[3] + strlen(argv[3]));
            if (src.empty() || !dxc_init()) return 1;
            std::vector<uint8_t> out = dxc_compile(text.c_str(), profile.c_str());
            FILE *f;
            if (out.empty() || !(f = fopen(argv[4], "wb"))) return 1;
            fwrite(out.data(), 1, out.size(), f); fclose(f);
            printf("BENCH wrote %s (%zu bytes)\n", argv[4], out.size());
            return 0;
        }
        if (!strcmp(mode, "dis") && argc > 2) {
            std::vector<uint8_t> b = read_file(argv[2]);
            if (b.empty() || !dxc_init()) return 1;
            dxc_disasm(b, NULL);
            return 0;
        }
        if (!strcmp(mode, "scan") && argc > 2) {
            NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@(argv[2]) error:nil];
            int total = 0, refused = 0, shadingrate = 0;
            bool all = getenv("SCAN_ALL") != NULL;   // vertex shaders too, and the converter's warnings tied to each file
            for (NSString *name in [files sortedArrayUsingSelector:@selector(compare:)]) {
                if (![name hasSuffix:@".ps"] && !(all && [name hasSuffix:@".vs"])) continue;
                if (all) { fprintf(stderr, "SCANFILE %s\n", name.UTF8String); fflush(stderr); }
                std::string path = std::string(argv[2]) + "/" + name.UTF8String;
                std::vector<uint8_t> ps = read_file(path.c_str());
                if (ps.empty()) continue;
                total++;
                if (dxil_reads_shadingrate(ps.data(), ps.size())) { shadingrate++; printf("SCAN %s reads SV_ShadingRate\n", name.UTF8String); }
                Converted c = ir_convert(dev, ps, name.UTF8String);
                if (!c.fn) { refused++; printf("SCAN %s NOT converted\n", name.UTF8String); }
            }
            printf("SCAN %d pixel shaders, %d not converted, %d read SV_ShadingRate\n", total, refused, shadingrate);
            return 0;
        }
        if (!strcmp(mode, "ps") && argc > 2) {
            std::vector<uint8_t> ps = read_file(argv[2]);
            Converted c = ir_convert(dev, ps, argv[2]);
            if (c.fn) for (MTLVertexAttribute *a in c.fn.stageInputAttributes) printf("BENCH input %s\n", a.name.UTF8String);
            printf("BENCH %s\n", c.fn ? "converted" : "NOT converted");
            return !c.fn;
        }
        printf("usage: dxilbench selftest | variants | unwritten | emit <dir> | hlsl <file> <profile> <out> | dis <file> | scan <dir> | pair <vs.dxil> <ps.dxil> | ps <ps.dxil>\n");
        return 2;
    }
}
