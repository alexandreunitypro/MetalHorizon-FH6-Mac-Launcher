// HB_TSSHIM_INSPECT=1: a log of what the game creates through D3D12 and of what each draw puts on screen, read by
// tools/mac_fh6_inspect.sh (written for Forza Horizon 6's black leaves, 2026-10-25).
//
// Creation: every pipeline (each shader's digest and debug name, depth, stencil, cull, targets, the answer D3DMetal
// gave), and every resource, heap, root signature, command signature, descriptor heap and command list, counted,
// with each failure in full.
// Drawing: for a short window every few seconds (HB_TSSHIM_INSPECT_PERIOD and HB_TSSHIM_INSPECT_WINDOW, in ms) every
// draw recorded on a direct command list is wrapped in an occlusion query, which counts the samples it wrote. A
// pipeline whose sampled draws write nothing, or one whose shader names contain a word of HB_TSSHIM_INSPECT_WATCH
// (comma separated), gets four twins, made on a worker thread from a copy of its description, that change nothing on
// screen (no colour write, no depth write, no stencil):
//   0  no pixel shader, no depth test                    is the geometry on screen at all
//   1  the same without culling                          or are its triangles culled
//   2  the game's pixel shader, no depth test            does the pixel shader discard every pixel
//   3  the game's pixel shader and depth test            does the depth test reject them (else the stencil does)
// A pipeline whose depth test is EQUAL without writing (a pass that relies on a depth pre-pass) gets four more, which say
// how far its depth is from the pre-pass's: the game's pixel shader with the test made GREATER_EQUAL, LESS_EQUAL,
// GREATER_EQUAL with a depth bias of 64, and GREATER_EQUAL with a bias of 4096 and a slope-scaled bias of 1.
// From then on each sampled draw of that pipeline is issued through the twins first, each in its own query, then as
// the game recorded it, so the log says per draw where its pixels were lost. HB_TSSHIM_INSPECT_MAX (default 400)
// caps how many pipelines get twins. Nothing is measured, and no twin made, until 2 s have passed without the game
// creating a pipeline: the inspector stays out of the way while the game compiles its shaders. HB_TSSHIM_INSPECT_AFTER=<n>
// also waits for n pipelines to exist (Forza Horizon 6 has about 16 900 once the world is loaded): with measuring in the
// menus, its load into the world crashed in the driver four times in five. Pipelines with a geometry, hull or domain shader get none: Metal emulates those
// stages, and in two runs out of three the twins of one (Forza Horizon 6's ForzaUIMaterialScreenShadow, VS+GS+PS) were
// followed, when the game loaded the world and the driver recompiled its variants, by a crash inside AGXMetalG17X
// (Metal4To3ConversionUtility::createFunction -> createLinkedFunctions -> libdispatch, a dispatch group at 0xd903). Pipelines are created one at a time while inspecting, so the numbers match
// D3DMetal's "PSO(N)" only with HB_TSSHIM_INSPECT_SERIAL=1, which creates pipelines one at a time: three runs in four
// with it crashed in the driver while the game loaded the world (see below), none of sixteen without the inspector, so
// by default the inspector numbers pipelines itself and creation runs as it does without it. Everything goes to C:\highball\logs\inspect-<pid>.log,
// the counts every 10 s. HB_TSSHIM_INSPECT_WINDOW defaults to 40 ms (about one frame), so a frame's queries fit the heap.
#include <windows.h>
#include <d3d12.h>
#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "inspect.h"

int inspect_on, inspect_serial;
static volatile LONG own_seq;
static volatile LONG64 last_pso_ms;
unsigned inspect_next_id(void) { return (unsigned)InterlockedIncrement(&own_seq) - 1; }
static BOOL quiet(LONG64 now) { return now - last_pso_ms >= 2000; }   // no pipeline created for 2 s
static UINT64 t_start, period = 5000, window = 40;
static LONG max_investigated = 400, after_psos;
static char watch[256];

// ---- the log ------------------------------------------------------------------------------------

static FILE *ilog;
static CRITICAL_SECTION ilog_lock;
static void ilog_line(const char *fmt, ...)
{
    va_list ap;
    if (!ilog) return;
    EnterCriticalSection(&ilog_lock);
    fprintf(ilog, "%.3f ", (double)(GetTickCount64() - t_start) / 1000.0);
    va_start(ap, fmt); vfprintf(ilog, fmt, ap); va_end(ap);
    fputc('\n', ilog);
    LeaveCriticalSection(&ilog_lock);
}
static void ilog_flush(void) { if (ilog) { EnterCriticalSection(&ilog_lock); fflush(ilog); LeaveCriticalSection(&ilog_lock); } }

// ---- shaders: digest, debug name, UAVs -------------------------------------------------------------

static const UINT8 *dxbc_part(const void *code, SIZE_T size, const char *fourcc, UINT *part_size)
{
    const UINT8 *b = code; UINT count, i, off, sz;
    if (!b || size < 32 || memcmp(b, "DXBC", 4)) return NULL;
    memcpy(&count, b + 28, 4);
    if (count > 64 || 32 + (SIZE_T)count * 4 > size) return NULL;
    for (i = 0; i < count; i++) {
        memcpy(&off, b + 32 + 4 * i, 4);
        if ((SIZE_T)off + 8 > size) continue;
        memcpy(&sz, b + off + 4, 4);
        if ((SIZE_T)off + 8 + sz > size) continue;
        if (!memcmp(b + off, fourcc, 4)) { *part_size = sz; return b + off + 8; }
    }
    return NULL;
}
// "<digest>:<name>", the name from the ILDN part (the file the game's build wrote the shader's debug data to), without
// its folder or extensions; the digest is the one HB_TSSHIM_DUMP names its files after.
static void shader_tag(D3D12_SHADER_BYTECODE b, char *out, size_t n)
{
    const UINT8 *code = b.pShaderBytecode, *p; UINT sz; UINT16 len; const char *s, *e, *c; size_t k; int i;
    if (!code || b.BytecodeLength < 32 || memcmp(code, "DXBC", 4)) { snprintf(out, n, "-"); return; }
    for (i = 0; i < 16; i++) sprintf(out + 2 * i, "%02x", code[4 + i]);
    out[32] = ':'; k = 33;
    if ((p = dxbc_part(code, b.BytecodeLength, "ILDN", &sz)) && sz > 4) {
        memcpy(&len, p + 2, 2); if (len > sz - 4) len = (UINT16)(sz - 4);
        s = (const char *)p + 4; e = s + len;
        for (c = s; c < e; c++) if (*c == '\\' || *c == '/') s = c + 1;
        for (c = s; c < e && *c && *c != '.' && k + 1 < n; c++) out[k++] = (*c <= ' ') ? '_' : *c;
    }
    if (k == 33) out[k++] = '-';
    out[k] = 0;
}
// The PSV0 part lists the shader's resources: UAVTyped 6, UAVRaw 7, UAVStructured 8, UAVStructuredWithCounter 9. A part
// that does not parse counts as having one, so a pixel shader that might write memory never runs twice.
static BOOL shader_has_uav(D3D12_SHADER_BYTECODE b)
{
    const UINT8 *p; UINT sz, info, count, bind, i, type;
    if (!(p = dxbc_part(b.pShaderBytecode, b.BytecodeLength, "PSV0", &sz))) return TRUE;
    if (sz < 4) return TRUE;
    memcpy(&info, p, 4);
    if ((SIZE_T)8 + info > sz) return TRUE;
    memcpy(&count, p + 4 + info, 4);
    if (!count) return FALSE;
    if ((SIZE_T)12 + info > sz) return TRUE;
    memcpy(&bind, p + 8 + info, 4);
    if (bind < 4) return TRUE;
    for (i = 0; i < count; i++) {
        SIZE_T at = 12 + info + (SIZE_T)i * bind;
        if (at + 4 > sz) return TRUE;
        memcpy(&type, p + at, 4);
        if (type >= 6 && type <= 9) return TRUE;
    }
    return FALSE;
}
static BOOL name_watched(const char *tag)
{
    char low[160], list[256], *w, *ctx = NULL; size_t i;
    if (!watch[0] || !(tag = strchr(tag, ':'))) return FALSE;
    for (i = 0; tag[i + 1] && i + 1 < sizeof low; i++) low[i] = (char)tolower((unsigned char)tag[i + 1]);
    low[i] = 0;
    snprintf(list, sizeof list, "%s", watch);
    for (w = strtok_s(list, ",", &ctx); w; w = strtok_s(NULL, ",", &ctx)) if (*w && strstr(low, w)) return TRUE;
    return FALSE;
}

// ---- copies of pipeline descriptions, for the twins ---------------------------------------------------

// Shader code is kept once per digest: the game may free its copy after creating the pipeline.
typedef struct { UINT8 key[16]; SIZE_T size; void *code; } Stored;
#define STORE_SIZE (1 << 15)
static Stored store[STORE_SIZE];
static CRITICAL_SECTION store_lock;
static SIZE_T stored_bytes;
static D3D12_SHADER_BYTECODE keep_bytecode(D3D12_SHADER_BYTECODE b, BOOL *ok)
{
    D3D12_SHADER_BYTECODE r = { NULL, 0 }; const UINT8 *code = b.pShaderBytecode; UINT h; int i;
    if (!code || !b.BytecodeLength) return r;
    if (b.BytecodeLength < 32 || memcmp(code, "DXBC", 4)) { *ok = FALSE; return r; }
    memcpy(&h, code + 4, 4);
    EnterCriticalSection(&store_lock);
    for (i = 0; i < 64; i++) {
        Stored *s = &store[(h + i) & (STORE_SIZE - 1)];
        if (s->code && s->size == b.BytecodeLength && !memcmp(s->key, code + 4, 16)) { r.pShaderBytecode = s->code; r.BytecodeLength = s->size; break; }
        if (!s->code) {
            if ((s->code = malloc(b.BytecodeLength))) {
                memcpy(s->code, code, b.BytecodeLength); memcpy(s->key, code + 4, 16); s->size = b.BytecodeLength;
                stored_bytes += s->size; r.pShaderBytecode = s->code; r.BytecodeLength = s->size;
            }
            break;
        }
    }
    LeaveCriticalSection(&store_lock);
    if (!r.pShaderBytecode) *ok = FALSE;
    return r;
}
static BOOL keep_layout(D3D12_INPUT_LAYOUT_DESC *l)
{
    D3D12_INPUT_ELEMENT_DESC *e; UINT i;
    if (!l->NumElements || !l->pInputElementDescs) { l->pInputElementDescs = NULL; l->NumElements = 0; return TRUE; }
    if (!(e = malloc(l->NumElements * sizeof *e))) return FALSE;
    memcpy(e, l->pInputElementDescs, l->NumElements * sizeof *e);
    for (i = 0; i < l->NumElements; i++) if (e[i].SemanticName && !(e[i].SemanticName = _strdup(e[i].SemanticName))) return FALSE;
    l->pInputElementDescs = e;
    return TRUE;
}
static D3D12_GRAPHICS_PIPELINE_STATE_DESC *copy_graphics(const D3D12_GRAPHICS_PIPELINE_STATE_DESC *d)
{
    D3D12_GRAPHICS_PIPELINE_STATE_DESC *c; BOOL ok = TRUE;
    if (!d || d->StreamOutput.NumEntries || !(c = malloc(sizeof *c))) return NULL;
    *c = *d;
    c->VS = keep_bytecode(d->VS, &ok); c->PS = keep_bytecode(d->PS, &ok); c->DS = keep_bytecode(d->DS, &ok);
    c->HS = keep_bytecode(d->HS, &ok); c->GS = keep_bytecode(d->GS, &ok);
    memset(&c->StreamOutput, 0, sizeof c->StreamOutput);
    c->CachedPSO.pCachedBlob = NULL; c->CachedPSO.CachedBlobSizeInBytes = 0;
    if (!ok || !keep_layout(&c->InputLayout)) { free(c); return NULL; }
    if (c->pRootSignature) c->pRootSignature->lpVtbl->AddRef(c->pRootSignature);
    return c;
}
typedef struct { SIZE_T size; UINT8 bytes[]; } StreamCopy;
#define NEXT_SUBOBJECT(at, size) (((at) + (size) + sizeof(void *) - 1) & ~(sizeof(void *) - 1))
static StreamCopy *copy_stream(const D3D12_PIPELINE_STATE_STREAM_DESC *in)
{
    StreamCopy *c; SIZE_T o = 0; BOOL ok = TRUE;
    if (!in || !in->pPipelineStateSubobjectStream || !in->SizeInBytes || !(c = malloc(sizeof *c + in->SizeInBytes))) return NULL;
    c->size = in->SizeInBytes; memcpy(c->bytes, in->pPipelineStateSubobjectStream, in->SizeInBytes);
    while (ok && o + sizeof(UINT) <= c->size) {
        UINT type; SIZE_T align, size, at; UINT8 *p;
        memcpy(&type, c->bytes + o, sizeof type);
        if (!(size = stream_inner_size(type, &align))) { ok = FALSE; break; }
        at = (o + sizeof(UINT) + align - 1) & ~(align - 1);
        if (at + size > c->size) { ok = FALSE; break; }
        p = c->bytes + at;
        switch (type) {
        case 0: { ID3D12RootSignature *rs; memcpy(&rs, p, sizeof rs); if (rs) rs->lpVtbl->AddRef(rs); break; }   // ROOT_SIGNATURE
        case 1: case 2: case 3: case 4: case 5: case 6: case 24: case 25: {   // VS PS DS HS GS CS AS MS
            D3D12_SHADER_BYTECODE sb; memcpy(&sb, p, sizeof sb); sb = keep_bytecode(sb, &ok); memcpy(p, &sb, sizeof sb); break;
        }
        case 7: { D3D12_STREAM_OUTPUT_DESC so; memcpy(&so, p, sizeof so); if (so.NumEntries) ok = FALSE; break; }
        case 12: { D3D12_INPUT_LAYOUT_DESC l; memcpy(&l, p, sizeof l); if (!keep_layout(&l)) ok = FALSE; memcpy(p, &l, sizeof l); break; }
        case 19: memset(p, 0, size); break;   // CACHED_PSO
        case 22: {   // VIEW_INSTANCING
            D3D12_VIEW_INSTANCING_DESC v; memcpy(&v, p, sizeof v);
            if (v.ViewInstanceCount && v.pViewInstanceLocations) {
                D3D12_VIEW_INSTANCE_LOCATION *loc = malloc(v.ViewInstanceCount * sizeof *loc);
                if (!loc) { ok = FALSE; break; }
                memcpy(loc, v.pViewInstanceLocations, v.ViewInstanceCount * sizeof *loc);
                v.pViewInstanceLocations = loc; memcpy(p, &v, sizeof v);
            }
            break;
        }
        }
        o = NEXT_SUBOBJECT(at, size);
    }
    if (!ok) { free(c); return NULL; }
    return c;
}

// ---- the twins -----------------------------------------------------------------------------------

// Variants 4-7, for an EQUAL test: the test they use instead, and the depth bias they add.
static const struct { D3D12_COMPARISON_FUNC func; INT bias; FLOAT slope; } eq_variant[4] = {
    { D3D12_COMPARISON_FUNC_GREATER_EQUAL, 0, 0.0f }, { D3D12_COMPARISON_FUNC_LESS_EQUAL, 0, 0.0f },
    { D3D12_COMPARISON_FUNC_GREATER_EQUAL, 64, 0.0f }, { D3D12_COMPARISON_FUNC_GREATER_EQUAL, 4096, 1.0f },
};
static void twin_blend(D3D12_BLEND_DESC *b, int v)
{
    int i;
    for (i = 0; i < 8; i++) {
        b->RenderTarget[i].RenderTargetWriteMask = 0;
        if (v < 2) { b->RenderTarget[i].BlendEnable = FALSE; b->RenderTarget[i].LogicOpEnable = FALSE; }
    }
    if (v < 2) b->AlphaToCoverageEnable = FALSE;
}
// DEPTH_STENCIL, DEPTH_STENCIL1 and DEPTH_STENCIL2 all start DepthEnable, DepthWriteMask, DepthFunc, StencilEnable;
// the last two end with DepthBoundsTestEnable.
static void twin_depth(UINT8 *ds, UINT type, int v)
{
    UINT zero = 0, one = 1;
    if (v < 3) memcpy(ds, &zero, 4);
    memcpy(ds + 4, &zero, 4);
    memcpy(ds + 12, &zero, 4);
    if (type == 21) memcpy(ds + 52, &zero, 4);
    else if (type == 26) memcpy(ds + 56, &zero, 4);
    if (v >= 4) { UINT f = eq_variant[v - 4].func; memcpy(ds, &one, 4); memcpy(ds + 8, &f, 4); }
}
// RASTERIZER has an integer depth bias, RASTERIZER1 and 2 a float one; all have CullMode at 4, DepthBias at 12,
// DepthBiasClamp at 16 and SlopeScaledDepthBias at 20.
static void twin_raster(UINT8 *r, UINT type, int v)
{
    if (v == 1) { UINT none = D3D12_CULL_MODE_NONE; memcpy(r + 4, &none, 4); }
    if (v >= 4) {
        FLOAT clamp = 0.0f, slope; memcpy(&slope, r + 20, 4); slope += eq_variant[v - 4].slope;
        if (type == 10) { INT b; memcpy(&b, r + 12, 4); b += eq_variant[v - 4].bias; memcpy(r + 12, &b, 4); }
        else { FLOAT b; memcpy(&b, r + 12, 4); b += (FLOAT)eq_variant[v - 4].bias; memcpy(r + 12, &b, 4); }
        memcpy(r + 16, &clamp, 4); memcpy(r + 20, &slope, 4);
    }
}
static void twin_graphics(D3D12_GRAPHICS_PIPELINE_STATE_DESC *t, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *c, int v)
{
    *t = *c;
    if (v < 2) { t->PS.pShaderBytecode = NULL; t->PS.BytecodeLength = 0; }
    twin_blend(&t->BlendState, v);
    if (v < 3) t->DepthStencilState.DepthEnable = FALSE;
    t->DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
    t->DepthStencilState.StencilEnable = FALSE;
    if (v == 1) t->RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    if (v >= 4) {
        t->DepthStencilState.DepthEnable = TRUE; t->DepthStencilState.DepthFunc = eq_variant[v - 4].func;
        t->RasterizerState.DepthBias += eq_variant[v - 4].bias; t->RasterizerState.SlopeScaledDepthBias += eq_variant[v - 4].slope;
        t->RasterizerState.DepthBiasClamp = 0.0f;
    }
}
static void emit(UINT8 *buf, SIZE_T *w, UINT type, const void *inner, SIZE_T size, SIZE_T align)
{
    SIZE_T at = (*w + sizeof(UINT) + align - 1) & ~(align - 1);
    memcpy(buf + *w, &type, sizeof type);
    memcpy(buf + at, inner, size);
    *w = NEXT_SUBOBJECT(at, size);
}
// The copy, subobject by subobject, with the twin's changes; a blend, depth-stencil or rasterizer the stream leaves
// at D3D12's default is added when the twin needs it changed.
static UINT8 *twin_stream(const StreamCopy *c, int v, SIZE_T *out_size)
{
    static const D3D12_DEPTH_STENCILOP_DESC keep = { D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_KEEP, D3D12_STENCIL_OP_KEEP, D3D12_COMPARISON_FUNC_ALWAYS };
    UINT8 *buf; SIZE_T o = 0, w = 0; BOOL blend = FALSE, depth = FALSE, raster = FALSE; int i;
    if (!(buf = calloc(1, c->size + 1024))) return NULL;
    while (o + sizeof(UINT) <= c->size) {
        UINT type; SIZE_T align, size, at; union { UINT8 b[400]; D3D12_BLEND_DESC blend; UINT64 align8; } inner;
        memcpy(&type, c->bytes + o, sizeof type);
        if (!(size = stream_inner_size(type, &align)) || size > sizeof inner) { free(buf); return NULL; }
        at = (o + sizeof(UINT) + align - 1) & ~(align - 1);
        memcpy(inner.b, c->bytes + at, size);
        if (type == 2 && v < 2) memset(inner.b, 0, size);
        else if (type == 8) { twin_blend(&inner.blend, v); blend = TRUE; }
        else if (type == 10 || type == 27 || type == 28) { twin_raster(inner.b, type, v); raster = TRUE; }
        else if (type == 11 || type == 21 || type == 26) { twin_depth(inner.b, type, v); depth = TRUE; }
        emit(buf, &w, type, inner.b, size, align);
        o = NEXT_SUBOBJECT(at, size);
    }
    if (!blend) {
        D3D12_BLEND_DESC b; memset(&b, 0, sizeof b);
        for (i = 0; i < 8; i++) {
            b.RenderTarget[i].SrcBlend = b.RenderTarget[i].SrcBlendAlpha = D3D12_BLEND_ONE;
            b.RenderTarget[i].DestBlend = b.RenderTarget[i].DestBlendAlpha = D3D12_BLEND_ZERO;
            b.RenderTarget[i].BlendOp = b.RenderTarget[i].BlendOpAlpha = D3D12_BLEND_OP_ADD;
            b.RenderTarget[i].LogicOp = D3D12_LOGIC_OP_NOOP;
        }
        twin_blend(&b, v); emit(buf, &w, D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_BLEND, &b, sizeof b, 4);
    }
    if (!depth) {   // the default is the test LESS, writing (an EQUAL pipeline has its own subobject)
        D3D12_DEPTH_STENCIL_DESC d = { v == 3, D3D12_DEPTH_WRITE_MASK_ZERO, D3D12_COMPARISON_FUNC_LESS, FALSE, 0xff, 0xff, keep, keep };
        emit(buf, &w, D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL, &d, sizeof d, 4);
    }
    if (!raster && (v == 1 || v >= 4)) {
        D3D12_RASTERIZER_DESC r = { D3D12_FILL_MODE_SOLID, D3D12_CULL_MODE_BACK, FALSE, 0, 0.0f, 0.0f, TRUE, FALSE, FALSE, 0, D3D12_CONSERVATIVE_RASTERIZATION_MODE_OFF };
        twin_raster((UINT8 *)&r, 10, v);
        emit(buf, &w, D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER, &r, sizeof r, 4);
    }
    *out_size = w;
    return buf;
}

// ---- pipelines ------------------------------------------------------------------------------------

enum { K_GRAPHICS, K_STREAM, K_COMPUTE };
enum { TW_NONE, TW_QUEUED, TW_READY };
// Per draw: written, nothing written and no twins yet, nothing on screen, culled, discarded, depth test, stencil
enum { C_LIT, C_ZERO, C_EMPTY, C_CULLED, C_DISCARD, C_DEPTH, C_STENCIL, NCAT };
#define NTWINS 8
typedef struct PsoInfo {
    unsigned id; int kind; BOOL watched, ps_uav, equal, emulated;
    ID3D12Device *dev; void *copy;
    volatile LONG tw_state; ID3D12PipelineState *twin[NTWINS];
    volatile LONG sets, draws, indirect;
    // below: the thread that reads the queries only
    LONG sampled, lit, cat[NCAT]; LONG64 samples, tw_samples[NTWINS];
    // EQUAL pipelines: over the draws the depth test emptied, the pixel shader's samples and what each of variants 4-7
    // let through; over all draws with variants, the same and the game's own
    LONG eq_draws; LONG64 eq_ps, eq_rec[4], all_ps, all_real, all_rec[4];
    LONG shown_sets, shown_draws, shown_sampled;
    struct PsoInfo *next_queued;
} PsoInfo;

#define PMAP_BITS 17
static struct { void *volatile key; PsoInfo *volatile val; } pmap[1 << PMAP_BITS];
static CRITICAL_SECTION pmap_lock;
static PsoInfo **all; static int nall, all_cap;
static LONG investigated, lib_seq, twins_made;
static UINT hash_ptr(const void *p, int bits) { return (UINT)((((UINT64)(UINT_PTR)p >> 4) * 0x9E3779B97F4A7C15ull) >> (64 - bits)); }
static PsoInfo *pso_find(const void *p)
{
    UINT i, k;
    if (!p) return NULL;
    for (i = hash_ptr(p, PMAP_BITS), k = 0; k < 256; k++, i = (i + 1) & ((1 << PMAP_BITS) - 1)) {
        void *key = pmap[i].key;
        if (key == p) return pmap[i].val;
        if (!key) return NULL;
    }
    return NULL;
}
static void pso_add(void *p, PsoInfo *v)
{
    UINT i, k;
    EnterCriticalSection(&pmap_lock);
    if (nall == all_cap) {
        PsoInfo **grown = realloc(all, (all_cap ? all_cap * 2 : 4096) * sizeof *grown);
        if (grown) { all = grown; all_cap = all_cap ? all_cap * 2 : 4096; }
    }
    if (nall < all_cap) all[nall++] = v;
    if (p) for (i = hash_ptr(p, PMAP_BITS), k = 0; k < 256; k++, i = (i + 1) & ((1 << PMAP_BITS) - 1)) {
        if (pmap[i].key == p) { pmap[i].val = v; break; }
        if (!pmap[i].key) { pmap[i].val = v; MemoryBarrier(); pmap[i].key = p; break; }
    }
    LeaveCriticalSection(&pmap_lock);
}
static void *canonical_pso(void *obj)
{
    IUnknown *u = obj; void *p = NULL;
    if (!u || FAILED(u->lpVtbl->QueryInterface(u, &IID_ID3D12PipelineState, &p)) || !p) return obj;
    ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p);
    return p;
}

typedef struct {
    D3D12_SHADER_BYTECODE sh[7];   // VS PS DS HS GS AS MS
    BOOL depth_on, depth_write, stencil_on, a2c; int depth_func, cull; UINT targets, rt0, dsv, samples, ok;
} Shape;
static void shape_graphics(Shape *s, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *d)
{
    memset(s, 0, sizeof *s);
    s->sh[0] = d->VS; s->sh[1] = d->PS; s->sh[2] = d->DS; s->sh[3] = d->HS; s->sh[4] = d->GS;
    s->depth_on = d->DepthStencilState.DepthEnable; s->depth_write = d->DepthStencilState.DepthWriteMask != D3D12_DEPTH_WRITE_MASK_ZERO;
    s->depth_func = d->DepthStencilState.DepthFunc; s->stencil_on = d->DepthStencilState.StencilEnable;
    s->cull = d->RasterizerState.CullMode; s->a2c = d->BlendState.AlphaToCoverageEnable;
    s->targets = d->NumRenderTargets; s->rt0 = d->RTVFormats[0]; s->dsv = d->DSVFormat; s->samples = d->SampleDesc.Count; s->ok = 1;
}
static void shape_stream(Shape *s, const D3D12_PIPELINE_STATE_STREAM_DESC *in)
{
    const UINT8 *b; SIZE_T o = 0;
    memset(s, 0, sizeof *s);
    s->depth_on = TRUE; s->depth_write = TRUE; s->depth_func = D3D12_COMPARISON_FUNC_LESS; s->cull = D3D12_CULL_MODE_BACK; s->samples = 1;
    if (!in || !(b = in->pPipelineStateSubobjectStream)) return;
    while (o + sizeof(UINT) <= in->SizeInBytes) {
        UINT type, v[4]; SIZE_T align, size, at;
        memcpy(&type, b + o, sizeof type);
        if (!(size = stream_inner_size(type, &align))) return;
        at = (o + sizeof(UINT) + align - 1) & ~(align - 1);
        if (at + size > in->SizeInBytes) return;
        if (type >= 1 && type <= 5) memcpy(&s->sh[type - 1], b + at, sizeof(D3D12_SHADER_BYTECODE));
        else if (type == 24 || type == 25) memcpy(&s->sh[type - 19], b + at, sizeof(D3D12_SHADER_BYTECODE));
        else if (type == 8) { memcpy(v, b + at, 4); s->a2c = v[0]; }
        else if (type == 10 || type == 27 || type == 28) { memcpy(v, b + at, 8); s->cull = v[1]; }
        else if (type == 11 || type == 21 || type == 26) { memcpy(v, b + at, 16); s->depth_on = v[0]; s->depth_write = v[1] != 0; s->depth_func = v[2]; s->stencil_on = v[3]; }
        else if (type == 15) { struct D3D12_RT_FORMAT_ARRAY f; memcpy(&f, b + at, sizeof f); s->targets = f.NumRenderTargets; s->rt0 = f.RTFormats[0]; }
        else if (type == 16) memcpy(&s->dsv, b + at, 4);
        else if (type == 17) memcpy(&s->samples, b + at, 4);
        o = NEXT_SUBOBJECT(at, size);
    }
    s->ok = 1;
}
static void log_pipeline(PsoInfo *p, const char *kind, HRESULT hr, const Shape *game, const Shape *fixed)
{
    static const char *names[7] = { "vs", "ps", "ds", "hs", "gs", "as", "ms" };
    char tags[7][160], line[1400] = ""; int i, n = 0;
    for (i = 0; i < 7; i++) {
        if (!game->sh[i].pShaderBytecode) continue;
        shader_tag(game->sh[i], tags[i], sizeof tags[i]);
        n += snprintf(line + n, sizeof line - n, " %s=%s", names[i], tags[i]);
        if (n >= (int)sizeof line) n = sizeof line - 1;
        if (name_watched(tags[i])) p->watched = TRUE;
    }
    ilog_line("pso %u %s hr 0x%08lx depth %d %d %d stencil %d cull %d rt %u %u dsv %u samples %u a2c %d uav %d copy %d watch %d%s",
              p->id, kind, (unsigned long)hr, fixed->depth_on, fixed->depth_write, fixed->depth_func, fixed->stencil_on, fixed->cull,
              fixed->targets, fixed->rt0, fixed->dsv, fixed->samples, fixed->a2c, p->ps_uav, p->copy != NULL, p->watched, line);
}
static PsoInfo *new_info(unsigned seq, int kind, ID3D12Device *dev)
{
    PsoInfo *p = calloc(1, sizeof *p);
    last_pso_ms = (LONG64)GetTickCount64();
    if (!p) return NULL;
    p->id = seq != ~0u ? seq : 0x40000000u + (unsigned)InterlockedIncrement(&lib_seq);
    p->kind = kind; p->dev = dev;
    return p;
}
void inspect_graphics(void *pso, unsigned seq, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *game, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *fixed, ID3D12Device *dev, HRESULT hr)
{
    Shape g, f; PsoInfo *p;
    if (!game || !fixed || !(p = new_info(seq, K_GRAPHICS, dev))) return;
    shape_graphics(&g, game); shape_graphics(&f, fixed);
    p->ps_uav = fixed->PS.pShaderBytecode && shader_has_uav(fixed->PS);
    p->equal = f.depth_on && !f.depth_write && f.depth_func == D3D12_COMPARISON_FUNC_EQUAL;
    p->emulated = f.sh[2].pShaderBytecode || f.sh[3].pShaderBytecode || f.sh[4].pShaderBytecode;
    if (SUCCEEDED(hr) && pso && !p->emulated) p->copy = copy_graphics(fixed);
    log_pipeline(p, seq != ~0u ? "graphics" : "library", hr, &g, &f);
    pso_add(SUCCEEDED(hr) ? canonical_pso(pso) : NULL, p);
}
void inspect_stream(void *pso, unsigned seq, const D3D12_PIPELINE_STATE_STREAM_DESC *game, const D3D12_PIPELINE_STATE_STREAM_DESC *fixed, ID3D12Device *dev, HRESULT hr)
{
    Shape g, f; PsoInfo *p;
    if (!game || !fixed) return;
    shape_stream(&g, game); shape_stream(&f, fixed);
    if (!g.sh[0].pShaderBytecode && !g.sh[6].pShaderBytecode && !g.sh[1].pShaderBytecode) {   // a compute stream
        if (!(p = new_info(seq, K_COMPUTE, dev))) return;
        ilog_line("pso %u compute-stream hr 0x%08lx", p->id, (unsigned long)hr);
        pso_add(SUCCEEDED(hr) ? canonical_pso(pso) : NULL, p);
        return;
    }
    if (!(p = new_info(seq, K_STREAM, dev))) return;
    p->ps_uav = f.sh[1].pShaderBytecode && shader_has_uav(f.sh[1]);
    p->equal = f.depth_on && !f.depth_write && f.depth_func == D3D12_COMPARISON_FUNC_EQUAL;
    p->emulated = f.sh[2].pShaderBytecode || f.sh[3].pShaderBytecode || f.sh[4].pShaderBytecode || f.sh[5].pShaderBytecode || f.sh[6].pShaderBytecode;
    if (SUCCEEDED(hr) && pso && f.ok && !p->emulated) p->copy = copy_stream(fixed);
    log_pipeline(p, seq != ~0u ? "stream" : "library-stream", hr, &g, &f);
    pso_add(SUCCEEDED(hr) ? canonical_pso(pso) : NULL, p);
}
void inspect_compute(void *pso, unsigned seq, const D3D12_COMPUTE_PIPELINE_STATE_DESC *d, HRESULT hr)
{
    PsoInfo *p; char tag[160];
    if (!d || !(p = new_info(seq, K_COMPUTE, NULL))) return;
    shader_tag(d->CS, tag, sizeof tag);
    ilog_line("pso %u compute hr 0x%08lx cs=%s", p->id, (unsigned long)hr, tag);
    pso_add(SUCCEEDED(hr) ? canonical_pso(pso) : NULL, p);
}

// The worker that makes twins, one pipeline at a time, numbered as D3DMetal numbers them.
static PsoInfo *twin_head;
static CRITICAL_SECTION twin_lock;
static HANDLE twin_event;
static void make_twins(PsoInfo *p)
{
    int v;
    for (v = 0; v < NTWINS; v++) {
        ID3D12PipelineState *t = NULL; HRESULT hr = E_FAIL; unsigned seq = ~0u;
        if ((v >= 2 && p->ps_uav) || (v >= 4 && !p->equal)) continue;
        if (inspect_serial) EnterCriticalSection(&pso_lock);
        if (p->kind == K_GRAPHICS && real_CreateGraphicsPipelineState) {
            D3D12_GRAPHICS_PIPELINE_STATE_DESC d; twin_graphics(&d, p->copy, v);
            hr = real_CreateGraphicsPipelineState(p->dev, &d, &IID_ID3D12PipelineState, (void **)&t);
            seq = inspect_serial ? pso_seq++ : inspect_next_id();
        } else if (p->kind == K_STREAM && real_CreatePipelineState) {
            ID3D12Device2 *dev2 = NULL; SIZE_T size; UINT8 *buf = twin_stream(p->copy, v, &size);
            if (buf && SUCCEEDED(p->dev->lpVtbl->QueryInterface(p->dev, &IID_ID3D12Device2, (void **)&dev2)) && dev2) {
                D3D12_PIPELINE_STATE_STREAM_DESC sd = { size, buf };
                hr = real_CreatePipelineState(dev2, &sd, &IID_ID3D12PipelineState, (void **)&t);
                seq = inspect_serial ? pso_seq++ : inspect_next_id();
                dev2->lpVtbl->Release(dev2);
            }
            free(buf);
        }
        if (inspect_serial) LeaveCriticalSection(&pso_lock);
        if (FAILED(hr)) t = NULL;
        p->twin[v] = t;
        InterlockedIncrement(&twins_made);
        ilog_line("twin %d of %u variant %d hr 0x%08lx", (int)seq, p->id, v, (unsigned long)hr);
    }
    MemoryBarrier();
    p->tw_state = TW_READY;
}
static DWORD WINAPI twin_worker(void *arg)
{
    for (;;) {
        PsoInfo *p;
        WaitForSingleObject(twin_event, INFINITE);
        for (;;) {
            EnterCriticalSection(&twin_lock);
            if ((p = twin_head)) twin_head = p->next_queued;
            LeaveCriticalSection(&twin_lock);
            if (!p) break;
            while (!quiet((LONG64)GetTickCount64())) Sleep(500);
            make_twins(p);
        }
    }
    return 0;
}
static void investigate(PsoInfo *p, const char *why)
{
    if (p->tw_state != TW_NONE || !p->copy || !p->dev || p->kind == K_COMPUTE || investigated >= max_investigated) return;
    p->tw_state = TW_QUEUED; investigated++;
    ilog_line("investigate %u %s", p->id, why);
    EnterCriticalSection(&twin_lock); p->next_queued = twin_head; twin_head = p; LeaveCriticalSection(&twin_lock);
    SetEvent(twin_event);
}

// ---- the queries -------------------------------------------------------------------------------------

#define HEAP_SLOTS 16384
#define CHUNK 256
#define NCHUNKS (HEAP_SLOTS / CHUNK)
#define NOSLOT (~0u)
// A draw takes one slot per query, in a row: its twins' (bits 0-7 of mask) then its own (bit 8).
#define REAL (1u << NTWINS)
typedef struct Chunk { UINT base, used; struct Chunk *next; PsoInfo *pso[CHUNK]; UINT16 mask[CHUNK]; } Chunk;
typedef struct Batch { ID3D12Fence *fence; UINT64 value; Chunk *chunks; struct Batch *next; } Batch;
static Chunk chunks[NCHUNKS], *free_chunks;
static Batch *batches;
static CRITICAL_SECTION chunk_lock, proc_lock;
static struct { ID3D12CommandQueue *queue; ID3D12Fence *fence; UINT64 value; } qfences[32];
static int nqfences;
static ID3D12Device *idev;
static ID3D12QueryHeap *iheap;
static ID3D12Resource *ireadback;
static const UINT64 *ivalues;
static volatile LONG64 burst_end, burst_next;
static volatile LONG n_lists, n_sampled_lists, n_sampled_draws, n_noslot, n_gamequery, n_bursts, n_unknown_draws, n_lost, n_bundles, n_tiles;
static UINT64 next_summary;

typedef struct ListState {
    ID3D12Device *dev; BOOL direct, sampling, closed; int game_queries;
    PsoInfo *cur; ID3D12PipelineState *cur_pso;
    Chunk *chunks;
} ListState;
#define LMAP_BITS 13
static struct { void *volatile key; ListState *volatile val; } lmap[1 << LMAP_BITS];
static CRITICAL_SECTION lmap_lock;
static ListState *list_find(const void *l)
{
    UINT i, k;
    for (i = hash_ptr(l, LMAP_BITS), k = 0; k < 128; k++, i = (i + 1) & ((1 << LMAP_BITS) - 1)) {
        void *key = lmap[i].key;
        if (key == l) return lmap[i].val;
        if (!key) return NULL;
    }
    return NULL;
}
static ListState *list_state(ID3D12GraphicsCommandList *l)
{
    ListState *st = list_find(l); UINT i, k;
    if (st || !l) return st;
    if (!(st = calloc(1, sizeof *st))) return NULL;
    {
        ID3D12Device *dev = NULL;
        if (SUCCEEDED(l->lpVtbl->GetDevice(l, &IID_ID3D12Device, (void **)&dev)) && dev) { st->dev = dev; dev->lpVtbl->Release(dev); }
        st->direct = l->lpVtbl->GetType(l) == D3D12_COMMAND_LIST_TYPE_DIRECT;
    }
    EnterCriticalSection(&lmap_lock);
    for (i = hash_ptr(l, LMAP_BITS), k = 0; k < 128; k++, i = (i + 1) & ((1 << LMAP_BITS) - 1)) {
        if (lmap[i].key == l) { free(st); st = lmap[i].val; break; }
        if (!lmap[i].key) { lmap[i].val = st; MemoryBarrier(); lmap[i].key = l; break; }
    }
    if (k == 128) { free(st); st = NULL; }
    LeaveCriticalSection(&lmap_lock);
    return st;
}
static void give_back(Chunk *c)
{
    Chunk *next;
    EnterCriticalSection(&chunk_lock);
    for (; c; c = next) { next = c->next; c->next = free_chunks; free_chunks = c; }
    LeaveCriticalSection(&chunk_lock);
}
static BOOL burst_now(void)
{
    LONG64 now = (LONG64)GetTickCount64();
    if (!quiet(now) || nall < after_psos) return FALSE;
    if (now >= burst_next) { burst_next = now + (LONG64)period; burst_end = now + (LONG64)window; InterlockedIncrement(&n_bursts); }
    return now < burst_end;
}
// A list starts recording: its earlier queries were never submitted (or were taken at submission).
static void list_begins(ListState *st, ID3D12PipelineState *pso)
{
    give_back(st->chunks); st->chunks = NULL;
    st->closed = FALSE; st->game_queries = 0; st->cur_pso = pso; st->cur = pso_find(pso);
    st->sampling = st->direct && iheap && st->dev == idev && burst_now();
    if (st->sampling) InterlockedIncrement(&n_sampled_lists);
}
static UINT take_slots(ListState *st, PsoInfo *p, UINT mask, UINT n)
{
    Chunk *c = st->chunks; UINT at, i;
    if (!c || c->used + n > CHUNK) {
        EnterCriticalSection(&chunk_lock);
        if ((c = free_chunks)) free_chunks = c->next;
        LeaveCriticalSection(&chunk_lock);
        if (!c) return NOSLOT;
        c->used = 0; c->next = st->chunks; st->chunks = c;
    }
    at = c->used;
    c->pso[at] = p; c->mask[at] = (UINT16)mask;
    for (i = 1; i < n; i++) { c->pso[at + i] = p; c->mask[at + i] = 0; }
    c->used += n;
    return c->base + at;
}
static int popcount(UINT m) { int n = 0; for (; m; m &= m - 1) n++; return n; }

static void account(PsoInfo *p, UINT mask, const UINT64 *val)
{
    BOOL has[NTWINS + 1]; UINT64 real = val[NTWINS]; int v, c;
    for (v = 0; v <= NTWINS; v++) has[v] = (mask >> v) & 1;
    p->sampled++;
    for (v = 0; v < NTWINS; v++) if (has[v]) p->tw_samples[v] += (LONG64)val[v];
    if (has[2] && has[4]) {
        p->all_ps += (LONG64)val[2]; p->all_real += (LONG64)real;
        for (v = 0; v < 4; v++) p->all_rec[v] += (LONG64)val[4 + v];
        if (!real && val[2] && has[3] && !val[3]) {
            p->eq_draws++; p->eq_ps += (LONG64)val[2];
            for (v = 0; v < 4; v++) p->eq_rec[v] += (LONG64)val[4 + v];
        }
    }
    if (real) { p->lit++; p->samples += (LONG64)real; c = C_LIT; }
    else if (!(mask & (REAL - 1))) c = C_ZERO;
    else if (has[1] ? !val[1] : (has[0] && !val[0])) c = C_EMPTY;
    else if (has[0] && !val[0]) c = C_CULLED;
    else if (has[2] && !val[2]) c = C_DISCARD;
    else if (has[3] && !val[3]) c = C_DEPTH;
    else if (has[3]) c = C_STENCIL;
    else c = C_ZERO;
    p->cat[c]++;
    if (p->watched) investigate(p, "watch");
    else if (p->sampled >= 4 && !p->lit) investigate(p, "nothing-written");
}
static void process_chunk(Chunk *c)
{
    UINT i = 0;
    while (i < c->used) {
        UINT mask = c->mask[i], v, k = 0; UINT64 val[NTWINS + 1] = { 0 };
        if (!mask) { i++; continue; }
        for (v = 0; v <= NTWINS; v++) if (mask & (1u << v)) val[v] = ivalues[c->base + i + k++];
        account(c->pso[i], mask, val);
        i += k;
    }
}

// ---- counts of what was created -------------------------------------------------------------------

typedef struct { const char *name; volatile LONG ok, fail; } Counter;
static Counter c_committed = { "committed" }, c_placed = { "placed" }, c_reserved = { "reserved" }, c_heap = { "heap" },
               c_rootsig = { "rootsig" }, c_cmdsig = { "cmdsig" }, c_descheap = { "descheap" }, c_cmdlist = { "cmdlist" };
static void counted(Counter *c, HRESULT hr, const char *details)
{
    LONG n;
    if (SUCCEEDED(hr)) { InterlockedIncrement(&c->ok); return; }
    n = InterlockedIncrement(&c->fail);
    if (n <= 200) { ilog_line("fail %s hr 0x%08lx %s", c->name, (unsigned long)hr, details ? details : ""); ilog_flush(); }
}
static const char *res_details(char *buf, size_t n, const D3D12_RESOURCE_DESC *d, D3D12_HEAP_TYPE heap)
{
    if (!d) return "desc NULL";
    snprintf(buf, n, "dim %d format %u size %llux%ux%u mips %u samples %u flags 0x%x layout %d heaptype %d", (int)d->Dimension, (unsigned)d->Format,
             (unsigned long long)d->Width, (unsigned)d->Height, (unsigned)d->DepthOrArraySize, (unsigned)d->MipLevels, (unsigned)d->SampleDesc.Count,
             (unsigned)d->Flags, (int)d->Layout, (int)heap);
    return buf;
}

static void summary(BOOL ask_device)
{
    int i;
    ilog_line("tick lists %ld sampledlists %ld sampleddraws %ld unknowndraws %ld noslot %ld gamequery %ld lost %ld bursts %ld bundles %ld psos %d investigated %ld twins %ld shadermb %lu",
              (long)n_lists, (long)n_sampled_lists, (long)n_sampled_draws, (long)n_unknown_draws, (long)n_noslot, (long)n_gamequery, (long)n_lost,
              (long)n_bursts, (long)n_bundles, nall, (long)investigated, (long)twins_made, (unsigned long)(stored_bytes >> 20));
    ilog_line("res committed %ld %ld placed %ld %ld reserved %ld %ld heap %ld %ld rootsig %ld %ld cmdsig %ld %ld descheap %ld %ld cmdlist %ld %ld tilemappings %ld",
              (long)c_committed.ok, (long)c_committed.fail, (long)c_placed.ok, (long)c_placed.fail, (long)c_reserved.ok, (long)c_reserved.fail,
              (long)c_heap.ok, (long)c_heap.fail, (long)c_rootsig.ok, (long)c_rootsig.fail, (long)c_cmdsig.ok, (long)c_cmdsig.fail,
              (long)c_descheap.ok, (long)c_descheap.fail, (long)c_cmdlist.ok, (long)c_cmdlist.fail, (long)n_tiles);
    EnterCriticalSection(&pmap_lock);
    for (i = 0; i < nall; i++) {
        PsoInfo *p = all[i];
        if (p->sets == p->shown_sets && p->draws == p->shown_draws && p->sampled == p->shown_sampled) continue;
        p->shown_sets = p->sets; p->shown_draws = p->draws; p->shown_sampled = p->sampled;
        ilog_line("stat %u sets %ld draws %ld indirect %ld sampled %ld lit %ld samples %lld cat %ld %ld %ld %ld %ld %ld %ld tw %lld %lld %lld %lld twins %d",
                  p->id, (long)p->sets, (long)p->draws, (long)p->indirect, (long)p->sampled, (long)p->lit, (long long)p->samples,
                  (long)p->cat[0], (long)p->cat[1], (long)p->cat[2], (long)p->cat[3], (long)p->cat[4], (long)p->cat[5], (long)p->cat[6],
                  (long long)p->tw_samples[0], (long long)p->tw_samples[1], (long long)p->tw_samples[2], (long long)p->tw_samples[3], (int)p->tw_state);
        if (p->all_ps || p->eq_draws)
            ilog_line("equal %u failed %ld ps %lld rec %lld %lld %lld %lld all ps %lld real %lld rec %lld %lld %lld %lld", p->id, (long)p->eq_draws,
                      (long long)p->eq_ps, (long long)p->eq_rec[0], (long long)p->eq_rec[1], (long long)p->eq_rec[2], (long long)p->eq_rec[3],
                      (long long)p->all_ps, (long long)p->all_real, (long long)p->all_rec[0], (long long)p->all_rec[1], (long long)p->all_rec[2], (long long)p->all_rec[3]);
    }
    LeaveCriticalSection(&pmap_lock);
    if (idev && ask_device) {
        static LONG told;
        HRESULT hr = idev->lpVtbl->GetDeviceRemovedReason(idev);
        if (hr != S_OK && !InterlockedExchange(&told, 1)) ilog_line("removed hr 0x%08lx", (unsigned long)hr);
    }
    ilog_flush();
}
static void poll(BOOL force)
{
    Batch *b, *next, *keep = NULL, *done = NULL; UINT64 now;
    if (!TryEnterCriticalSection(&proc_lock)) return;
    EnterCriticalSection(&chunk_lock); b = batches; batches = NULL; LeaveCriticalSection(&chunk_lock);
    for (; b; b = next) {
        next = b->next;
        if (b->fence->lpVtbl->GetCompletedValue(b->fence) >= b->value) { b->next = done; done = b; }
        else { b->next = keep; keep = b; }
    }
    if (keep) {
        Batch *t = keep; while (t->next) t = t->next;
        EnterCriticalSection(&chunk_lock); t->next = batches; batches = keep; LeaveCriticalSection(&chunk_lock);
    }
    for (b = done; b; b = next) {
        Chunk *c, *cn;
        next = b->next;
        for (c = b->chunks; c; c = cn) { cn = c->next; c->next = NULL; process_chunk(c); give_back(c); }
        free(b);
    }
    now = GetTickCount64();
    if (force || now >= next_summary) { summary(TRUE); next_summary = now + 10000; }
    LeaveCriticalSection(&proc_lock);
}
static void submit(ID3D12CommandQueue *q, Chunk *got)
{
    Batch *b = malloc(sizeof *b); int i; BOOL ok = FALSE;
    EnterCriticalSection(&chunk_lock);   // held over Signal, so a queue's values reach it in order
    for (i = 0; i < nqfences && qfences[i].queue != q; i++);
    if (i == nqfences && nqfences < 32
        && SUCCEEDED(idev->lpVtbl->CreateFence(idev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&qfences[i].fence))) {
        qfences[i].queue = q; qfences[i].value = 0; nqfences++;
    }
    if (b && i < nqfences && SUCCEEDED(q->lpVtbl->Signal(q, qfences[i].fence, qfences[i].value + 1))) {
        b->fence = qfences[i].fence; b->value = ++qfences[i].value; b->chunks = got; b->next = batches; batches = b; ok = TRUE;
    }
    LeaveCriticalSection(&chunk_lock);
    if (!ok) { free(b); give_back(got); InterlockedIncrement(&n_lost); }
}

// ---- command list hooks ---------------------------------------------------------------------------------

static void (STDMETHODCALLTYPE *real_SetPipelineState)(ID3D12GraphicsCommandList *, ID3D12PipelineState *);
static void (STDMETHODCALLTYPE *real_DrawInstanced)(ID3D12GraphicsCommandList *, UINT, UINT, UINT, UINT);
static void (STDMETHODCALLTYPE *real_DrawIndexedInstanced)(ID3D12GraphicsCommandList *, UINT, UINT, UINT, INT, UINT);
static void (STDMETHODCALLTYPE *real_Dispatch)(ID3D12GraphicsCommandList *, UINT, UINT, UINT);
static void (STDMETHODCALLTYPE *real_ExecuteIndirect)(ID3D12GraphicsCommandList *, ID3D12CommandSignature *, UINT, ID3D12Resource *, UINT64, ID3D12Resource *, UINT64);
static void (STDMETHODCALLTYPE *real_ExecuteBundle)(ID3D12GraphicsCommandList *, ID3D12GraphicsCommandList *);
static HRESULT (STDMETHODCALLTYPE *real_Reset)(ID3D12GraphicsCommandList *, ID3D12CommandAllocator *, ID3D12PipelineState *);
static HRESULT (STDMETHODCALLTYPE *real_Close)(ID3D12GraphicsCommandList *);
static void (STDMETHODCALLTYPE *real_ClearState)(ID3D12GraphicsCommandList *, ID3D12PipelineState *);

// Command signatures that draw (their last argument is a draw), so ExecuteIndirect with them can be measured.
#define SMAP_BITS 12
static void *volatile draw_sigs[1 << SMAP_BITS];
static BOOL sig_draws(const void *s)
{
    UINT i, k;
    for (i = hash_ptr(s, SMAP_BITS), k = 0; k < 64; k++, i = (i + 1) & ((1 << SMAP_BITS) - 1)) {
        if (draw_sigs[i] == s) return TRUE;
        if (!draw_sigs[i]) return FALSE;
    }
    return FALSE;
}

typedef struct { int type; UINT a, b, c, d; INT e; ID3D12CommandSignature *sig; ID3D12Resource *args, *count; UINT64 args_off, count_off; } DrawCall;
static void issue(ID3D12GraphicsCommandList *l, const DrawCall *d)
{
    if (d->type == 0) real_DrawInstanced(l, d->a, d->b, d->c, d->d);
    else if (d->type == 1) real_DrawIndexedInstanced(l, d->a, d->b, d->c, d->e, d->d);
    else real_ExecuteIndirect(l, d->sig, d->a, d->args, d->args_off, d->count, d->count_off);
}
static void draw(ID3D12GraphicsCommandList *l, const DrawCall *d)
{
    ListState *st = list_find(l); PsoInfo *p = st ? st->cur : NULL; UINT mask = REAL, slot, v, k = 0;
    if (!p) { InterlockedIncrement(&n_unknown_draws); issue(l, d); return; }
    if (d->type == 2) InterlockedIncrement(&p->indirect); else InterlockedIncrement(&p->draws);
    if (!st->sampling || p->kind == K_COMPUTE) { issue(l, d); return; }
    if (st->game_queries) { InterlockedIncrement(&n_gamequery); issue(l, d); return; }
    if (p->tw_state == TW_READY) for (v = 0; v < NTWINS; v++) if (p->twin[v]) mask |= 1u << v;
    if ((slot = take_slots(st, p, mask, popcount(mask))) == NOSLOT) { InterlockedIncrement(&n_noslot); issue(l, d); return; }
    if (mask & (REAL - 1)) {
        for (v = 0; v < NTWINS; v++) {
            if (!(mask & (1u << v))) continue;
            real_SetPipelineState(l, p->twin[v]);
            l->lpVtbl->BeginQuery(l, iheap, D3D12_QUERY_TYPE_OCCLUSION, slot + k);
            issue(l, d);
            l->lpVtbl->EndQuery(l, iheap, D3D12_QUERY_TYPE_OCCLUSION, slot + k);
            k++;
        }
        real_SetPipelineState(l, st->cur_pso);
    }
    l->lpVtbl->BeginQuery(l, iheap, D3D12_QUERY_TYPE_OCCLUSION, slot + k);
    issue(l, d);
    l->lpVtbl->EndQuery(l, iheap, D3D12_QUERY_TYPE_OCCLUSION, slot + k);
    InterlockedIncrement(&n_sampled_draws);
}
static void STDMETHODCALLTYPE hook_DrawInstanced(ID3D12GraphicsCommandList *l, UINT vc, UINT ic, UINT sv, UINT si)
{
    DrawCall d = { 0, vc, ic, sv, si };
    draw(l, &d);
}
static void STDMETHODCALLTYPE hook_DrawIndexedInstanced(ID3D12GraphicsCommandList *l, UINT idx, UINT ic, UINT si, INT bv, UINT sinst)
{
    DrawCall d = { 1, idx, ic, si, sinst, bv };
    draw(l, &d);
}
static void STDMETHODCALLTYPE hook_ExecuteIndirect(ID3D12GraphicsCommandList *l, ID3D12CommandSignature *sig, UINT max, ID3D12Resource *args, UINT64 args_off, ID3D12Resource *count, UINT64 count_off)
{
    DrawCall d = { 2, max }; ListState *st;
    if (!sig_draws(sig)) {
        if ((st = list_find(l)) && st->cur) InterlockedIncrement(&st->cur->indirect);
        real_ExecuteIndirect(l, sig, max, args, args_off, count, count_off);
        return;
    }
    d.sig = sig; d.args = args; d.args_off = args_off; d.count = count; d.count_off = count_off;
    draw(l, &d);
}
static void STDMETHODCALLTYPE hook_Dispatch(ID3D12GraphicsCommandList *l, UINT x, UINT y, UINT z)
{
    ListState *st = list_find(l);
    if (st && st->cur) InterlockedIncrement(&st->cur->draws);
    real_Dispatch(l, x, y, z);
}
static void STDMETHODCALLTYPE hook_SetPipelineState(ID3D12GraphicsCommandList *l, ID3D12PipelineState *pso)
{
    ListState *st = list_find(l);
    if (st) { st->cur_pso = pso; if ((st->cur = pso_find(pso))) InterlockedIncrement(&st->cur->sets); }
    real_SetPipelineState(l, pso);
}
static void STDMETHODCALLTYPE hook_ClearState(ID3D12GraphicsCommandList *l, ID3D12PipelineState *pso)
{
    ListState *st = list_find(l);
    if (st) { st->cur_pso = pso; st->cur = pso_find(pso); }
    real_ClearState(l, pso);
}
static void STDMETHODCALLTYPE hook_ExecuteBundle(ID3D12GraphicsCommandList *l, ID3D12GraphicsCommandList *bundle)
{
    InterlockedIncrement(&n_bundles);
    real_ExecuteBundle(l, bundle);
}
static HRESULT STDMETHODCALLTYPE hook_Reset(ID3D12GraphicsCommandList *l, ID3D12CommandAllocator *a, ID3D12PipelineState *pso)
{
    ListState *st = list_state(l);
    if (st) list_begins(st, pso);
    return real_Reset(l, a, pso);
}
static HRESULT STDMETHODCALLTYPE hook_Close(ID3D12GraphicsCommandList *l)
{
    ListState *st = list_find(l); Chunk *c;
    if (st) {
        for (c = st->chunks; c; c = c->next)
            if (c->used) l->lpVtbl->ResolveQueryData(l, iheap, D3D12_QUERY_TYPE_OCCLUSION, c->base, c->used, ireadback, (UINT64)c->base * 8);
        st->closed = TRUE; st->sampling = FALSE;
    }
    return real_Close(l);
}
void inspect_game_query(ID3D12GraphicsCommandList *l, ID3D12QueryHeap *heap, D3D12_QUERY_TYPE type, BOOL begin)
{
    ListState *st;
    if (!inspect_on || heap == iheap || (type != D3D12_QUERY_TYPE_OCCLUSION && type != D3D12_QUERY_TYPE_BINARY_OCCLUSION)) return;
    if (!(st = list_find(l))) return;
    st->game_queries += begin ? 1 : -1;
    if (st->game_queries < 0) st->game_queries = 0;
}
void inspect_patch_list(void *iface)
{
    ID3D12GraphicsCommandListVtbl *vt = *(ID3D12GraphicsCommandListVtbl **)iface;
    if (!inspect_on) return;
    patch_slot((void **)&vt->SetPipelineState, (void *)hook_SetPipelineState, (void **)&real_SetPipelineState);
    patch_slot((void **)&vt->DrawInstanced, (void *)hook_DrawInstanced, (void **)&real_DrawInstanced);
    patch_slot((void **)&vt->DrawIndexedInstanced, (void *)hook_DrawIndexedInstanced, (void **)&real_DrawIndexedInstanced);
    patch_slot((void **)&vt->Dispatch, (void *)hook_Dispatch, (void **)&real_Dispatch);
    patch_slot((void **)&vt->ExecuteIndirect, (void *)hook_ExecuteIndirect, (void **)&real_ExecuteIndirect);
    patch_slot((void **)&vt->ExecuteBundle, (void *)hook_ExecuteBundle, (void **)&real_ExecuteBundle);
    patch_slot((void **)&vt->Reset, (void *)hook_Reset, (void **)&real_Reset);
    patch_slot((void **)&vt->Close, (void *)hook_Close, (void **)&real_Close);
    patch_slot((void **)&vt->ClearState, (void *)hook_ClearState, (void **)&real_ClearState);
}

// ---- queue hooks -----------------------------------------------------------------------------------------

static void (STDMETHODCALLTYPE *real_ExecuteCommandLists)(ID3D12CommandQueue *, UINT, ID3D12CommandList *const *);
static void (STDMETHODCALLTYPE *real_UpdateTileMappings)(ID3D12CommandQueue *, ID3D12Resource *, UINT, const D3D12_TILED_RESOURCE_COORDINATE *,
    const D3D12_TILE_REGION_SIZE *, ID3D12Heap *, UINT, const D3D12_TILE_RANGE_FLAGS *, const UINT *, const UINT *, D3D12_TILE_MAPPING_FLAGS);
static void STDMETHODCALLTYPE hook_ExecuteCommandLists(ID3D12CommandQueue *q, UINT n, ID3D12CommandList *const *lists)
{
    Chunk *got = NULL; UINT i;
    // The queries are taken before the lists go: a list may be reset as soon as ExecuteCommandLists returns.
    for (i = 0; i < n; i++) {
        ListState *st = lists[i] ? list_find(lists[i]) : NULL; Chunk *c;
        if (!st || !st->chunks || !st->closed) continue;
        for (c = st->chunks; c->next; c = c->next);
        c->next = got; got = st->chunks; st->chunks = NULL;
    }
    real_ExecuteCommandLists(q, n, lists);
    InterlockedExchangeAdd(&n_lists, (LONG)n);
    if (got) submit(q, got);
    poll(FALSE);
}
static void STDMETHODCALLTYPE hook_UpdateTileMappings(ID3D12CommandQueue *q, ID3D12Resource *res, UINT nreg, const D3D12_TILED_RESOURCE_COORDINATE *coords,
    const D3D12_TILE_REGION_SIZE *sizes, ID3D12Heap *heap, UINT nranges, const D3D12_TILE_RANGE_FLAGS *flags, const UINT *offsets, const UINT *counts, D3D12_TILE_MAPPING_FLAGS f)
{
    InterlockedIncrement(&n_tiles);
    real_UpdateTileMappings(q, res, nreg, coords, sizes, heap, nranges, flags, offsets, counts, f);
}
void inspect_patch_queue(void *iface)
{
    ID3D12CommandQueueVtbl *vt = *(ID3D12CommandQueueVtbl **)iface;
    if (!inspect_on) return;
    patch_slot((void **)&vt->ExecuteCommandLists, (void *)hook_ExecuteCommandLists, (void **)&real_ExecuteCommandLists);
    patch_slot((void **)&vt->UpdateTileMappings, (void *)hook_UpdateTileMappings, (void **)&real_UpdateTileMappings);
}

// ---- device hooks: creation counts ---------------------------------------------------------------------

static HRESULT (STDMETHODCALLTYPE *real_CreateCommittedResource)(ID3D12Device *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreatePlacedResource)(ID3D12Device *, ID3D12Heap *, UINT64, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateReservedResource)(ID3D12Device *, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateHeap)(ID3D12Device *, const D3D12_HEAP_DESC *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateRootSignature)(ID3D12Device *, UINT, const void *, SIZE_T, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateCommandSignature)(ID3D12Device *, const D3D12_COMMAND_SIGNATURE_DESC *, ID3D12RootSignature *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateDescriptorHeap)(ID3D12Device *, const D3D12_DESCRIPTOR_HEAP_DESC *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateCommandList)(ID3D12Device *, UINT, D3D12_COMMAND_LIST_TYPE, ID3D12CommandAllocator *, ID3D12PipelineState *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateCommittedResource1)(ID3D12Device4 *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, ID3D12ProtectedResourceSession *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateHeap1)(ID3D12Device4 *, const D3D12_HEAP_DESC *, ID3D12ProtectedResourceSession *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateReservedResource1)(ID3D12Device4 *, const D3D12_RESOURCE_DESC *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, ID3D12ProtectedResourceSession *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateCommittedResource2)(ID3D12Device8 *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS, const D3D12_RESOURCE_DESC1 *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, ID3D12ProtectedResourceSession *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreatePlacedResource1)(ID3D12Device8 *, ID3D12Heap *, UINT64, const D3D12_RESOURCE_DESC1 *, D3D12_RESOURCE_STATES, const D3D12_CLEAR_VALUE *, REFIID, void **);

static HRESULT (STDMETHODCALLTYPE *real_CreateCommittedResource3)(ID3D12Device10 *, const D3D12_HEAP_PROPERTIES *, D3D12_HEAP_FLAGS, const D3D12_RESOURCE_DESC1 *, D3D12_BARRIER_LAYOUT, const D3D12_CLEAR_VALUE *, ID3D12ProtectedResourceSession *, UINT32, DXGI_FORMAT *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreatePlacedResource2)(ID3D12Device10 *, ID3D12Heap *, UINT64, const D3D12_RESOURCE_DESC1 *, D3D12_BARRIER_LAYOUT, const D3D12_CLEAR_VALUE *, UINT32, DXGI_FORMAT *, REFIID, void **);
static HRESULT (STDMETHODCALLTYPE *real_CreateReservedResource2)(ID3D12Device10 *, const D3D12_RESOURCE_DESC *, D3D12_BARRIER_LAYOUT, const D3D12_CLEAR_VALUE *, ID3D12ProtectedResourceSession *, UINT32, DXGI_FORMAT *, REFIID, void **);
static D3D12_HEAP_TYPE heap_type(const D3D12_HEAP_PROPERTIES *hp) { return hp ? hp->Type : (D3D12_HEAP_TYPE)0; }
static HRESULT STDMETHODCALLTYPE hook_CreateCommittedResource(ID3D12Device *dev, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_STATES s, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out)
{
    HRESULT hr = real_CreateCommittedResource(dev, hp, hf, d, s, cv, riid, out); char b[200];
    counted(&c_committed, hr, FAILED(hr) ? res_details(b, sizeof b, d, heap_type(hp)) : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreatePlacedResource(ID3D12Device *dev, ID3D12Heap *heap, UINT64 off, const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_STATES s, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out)
{
    HRESULT hr = real_CreatePlacedResource(dev, heap, off, d, s, cv, riid, out); char b[200];
    counted(&c_placed, hr, FAILED(hr) ? res_details(b, sizeof b, d, 0) : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateReservedResource(ID3D12Device *dev, const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_STATES s, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out)
{
    HRESULT hr = real_CreateReservedResource(dev, d, s, cv, riid, out); char b[200];
    counted(&c_reserved, hr, FAILED(hr) ? res_details(b, sizeof b, d, 0) : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateHeap(ID3D12Device *dev, const D3D12_HEAP_DESC *d, REFIID riid, void **out)
{
    HRESULT hr = real_CreateHeap(dev, d, riid, out); char b[160] = "";
    if (FAILED(hr) && d) snprintf(b, sizeof b, "size %llu type %d flags 0x%x", (unsigned long long)d->SizeInBytes, (int)d->Properties.Type, (unsigned)d->Flags);
    counted(&c_heap, hr, FAILED(hr) ? b : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateRootSignature(ID3D12Device *dev, UINT mask, const void *blob, SIZE_T len, REFIID riid, void **out)
{
    HRESULT hr = real_CreateRootSignature(dev, mask, blob, len, riid, out); char b[64];
    snprintf(b, sizeof b, "%lu bytes", (unsigned long)len);
    counted(&c_rootsig, hr, b);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateCommandSignature(ID3D12Device *dev, const D3D12_COMMAND_SIGNATURE_DESC *d, ID3D12RootSignature *rs, REFIID riid, void **out)
{
    HRESULT hr = real_CreateCommandSignature(dev, d, rs, riid, out); char b[96] = "";
    D3D12_INDIRECT_ARGUMENT_TYPE last = d && d->NumArgumentDescs && d->pArgumentDescs ? d->pArgumentDescs[d->NumArgumentDescs - 1].Type : (D3D12_INDIRECT_ARGUMENT_TYPE)-1;
    if (d) snprintf(b, sizeof b, "%u arguments, last %d, stride %u", d->NumArgumentDescs, (int)last, d->ByteStride);
    counted(&c_cmdsig, hr, FAILED(hr) ? b : NULL);
    if (SUCCEEDED(hr) && out && *out && (last == D3D12_INDIRECT_ARGUMENT_TYPE_DRAW || last == D3D12_INDIRECT_ARGUMENT_TYPE_DRAW_INDEXED)) {
        void *s = NULL; IUnknown *u = *out; UINT i, k;
        if (FAILED(u->lpVtbl->QueryInterface(u, &IID_ID3D12CommandSignature, &s)) || !s) s = *out; else u->lpVtbl->Release((IUnknown *)s);
        EnterCriticalSection(&lmap_lock);
        for (i = hash_ptr(s, SMAP_BITS), k = 0; k < 64; k++, i = (i + 1) & ((1 << SMAP_BITS) - 1))
            if (draw_sigs[i] == s || !draw_sigs[i]) { draw_sigs[i] = s; break; }
        LeaveCriticalSection(&lmap_lock);
        ilog_line("cmdsig draws: %s", b);
    }
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateDescriptorHeap(ID3D12Device *dev, const D3D12_DESCRIPTOR_HEAP_DESC *d, REFIID riid, void **out)
{
    HRESULT hr = real_CreateDescriptorHeap(dev, d, riid, out); char b[96] = "";
    if (d) snprintf(b, sizeof b, "type %d count %u flags 0x%x", (int)d->Type, d->NumDescriptors, (unsigned)d->Flags);
    counted(&c_descheap, hr, FAILED(hr) ? b : NULL);
    return hr;
}
static void new_list(void **out, ID3D12Device *dev, D3D12_COMMAND_LIST_TYPE type, ID3D12PipelineState *pso, BOOL open)
{
    IUnknown *u; ID3D12GraphicsCommandList *l = NULL; ListState *st;
    if (!out || !(u = *out) || FAILED(u->lpVtbl->QueryInterface(u, &IID_ID3D12GraphicsCommandList, (void **)&l)) || !l) return;
    if ((st = list_state(l))) {
        st->dev = dev; st->direct = type == D3D12_COMMAND_LIST_TYPE_DIRECT;
        if (open) list_begins(st, pso);
        else { give_back(st->chunks); st->chunks = NULL; st->closed = TRUE; st->sampling = FALSE; }
    }
    l->lpVtbl->Release(l);
}
static HRESULT STDMETHODCALLTYPE hook_CreateCommandList(ID3D12Device *dev, UINT mask, D3D12_COMMAND_LIST_TYPE type, ID3D12CommandAllocator *a, ID3D12PipelineState *pso, REFIID riid, void **out)
{
    HRESULT hr = real_CreateCommandList(dev, mask, type, a, pso, riid, out);
    counted(&c_cmdlist, hr, NULL);
    if (SUCCEEDED(hr)) new_list(out, dev, type, pso, TRUE);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateCommittedResource1(ID3D12Device4 *dev, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_STATES s, const D3D12_CLEAR_VALUE *cv, ID3D12ProtectedResourceSession *ps, REFIID riid, void **out)
{
    HRESULT hr = real_CreateCommittedResource1(dev, hp, hf, d, s, cv, ps, riid, out); char b[200];
    counted(&c_committed, hr, FAILED(hr) ? res_details(b, sizeof b, d, heap_type(hp)) : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateHeap1(ID3D12Device4 *dev, const D3D12_HEAP_DESC *d, ID3D12ProtectedResourceSession *ps, REFIID riid, void **out)
{
    HRESULT hr = real_CreateHeap1(dev, d, ps, riid, out);
    counted(&c_heap, hr, NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateReservedResource1(ID3D12Device4 *dev, const D3D12_RESOURCE_DESC *d, D3D12_RESOURCE_STATES s, const D3D12_CLEAR_VALUE *cv, ID3D12ProtectedResourceSession *ps, REFIID riid, void **out)
{
    HRESULT hr = real_CreateReservedResource1(dev, d, s, cv, ps, riid, out); char b[200];
    counted(&c_reserved, hr, FAILED(hr) ? res_details(b, sizeof b, d, 0) : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateCommittedResource2(ID3D12Device8 *dev, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC1 *d, D3D12_RESOURCE_STATES s, const D3D12_CLEAR_VALUE *cv, ID3D12ProtectedResourceSession *ps, REFIID riid, void **out)
{
    HRESULT hr = real_CreateCommittedResource2(dev, hp, hf, d, s, cv, ps, riid, out); char b[200];
    counted(&c_committed, hr, FAILED(hr) ? res_details(b, sizeof b, (const D3D12_RESOURCE_DESC *)d, heap_type(hp)) : NULL);   // DESC1 starts as DESC
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreatePlacedResource1(ID3D12Device8 *dev, ID3D12Heap *heap, UINT64 off, const D3D12_RESOURCE_DESC1 *d, D3D12_RESOURCE_STATES s, const D3D12_CLEAR_VALUE *cv, REFIID riid, void **out)
{
    HRESULT hr = real_CreatePlacedResource1(dev, heap, off, d, s, cv, riid, out); char b[200];
    counted(&c_placed, hr, FAILED(hr) ? res_details(b, sizeof b, (const D3D12_RESOURCE_DESC *)d, 0) : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateCommittedResource3(ID3D12Device10 *dev, const D3D12_HEAP_PROPERTIES *hp, D3D12_HEAP_FLAGS hf, const D3D12_RESOURCE_DESC1 *d, D3D12_BARRIER_LAYOUT lay, const D3D12_CLEAR_VALUE *cv, ID3D12ProtectedResourceSession *ps, UINT32 nf, DXGI_FORMAT *f, REFIID riid, void **out)
{
    HRESULT hr = real_CreateCommittedResource3(dev, hp, hf, d, lay, cv, ps, nf, f, riid, out); char b[200];
    counted(&c_committed, hr, FAILED(hr) ? res_details(b, sizeof b, (const D3D12_RESOURCE_DESC *)d, heap_type(hp)) : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreatePlacedResource2(ID3D12Device10 *dev, ID3D12Heap *heap, UINT64 off, const D3D12_RESOURCE_DESC1 *d, D3D12_BARRIER_LAYOUT lay, const D3D12_CLEAR_VALUE *cv, UINT32 nf, DXGI_FORMAT *f, REFIID riid, void **out)
{
    HRESULT hr = real_CreatePlacedResource2(dev, heap, off, d, lay, cv, nf, f, riid, out); char b[200];
    counted(&c_placed, hr, FAILED(hr) ? res_details(b, sizeof b, (const D3D12_RESOURCE_DESC *)d, 0) : NULL);
    return hr;
}
static HRESULT STDMETHODCALLTYPE hook_CreateReservedResource2(ID3D12Device10 *dev, const D3D12_RESOURCE_DESC *d, D3D12_BARRIER_LAYOUT lay, const D3D12_CLEAR_VALUE *cv, ID3D12ProtectedResourceSession *ps, UINT32 nf, DXGI_FORMAT *f, REFIID riid, void **out)
{
    HRESULT hr = real_CreateReservedResource2(dev, d, lay, cv, ps, nf, f, riid, out); char b[200];
    counted(&c_reserved, hr, FAILED(hr) ? res_details(b, sizeof b, d, 0) : NULL);
    return hr;
}
void inspect_patch_device(void *iface)
{
    ID3D12DeviceVtbl *vt = *(ID3D12DeviceVtbl **)iface; IUnknown *u = iface; void *p = NULL;
    if (!inspect_on) return;
    patch_slot((void **)&vt->CreateCommittedResource, (void *)hook_CreateCommittedResource, (void **)&real_CreateCommittedResource);
    patch_slot((void **)&vt->CreatePlacedResource, (void *)hook_CreatePlacedResource, (void **)&real_CreatePlacedResource);
    patch_slot((void **)&vt->CreateReservedResource, (void *)hook_CreateReservedResource, (void **)&real_CreateReservedResource);
    patch_slot((void **)&vt->CreateHeap, (void *)hook_CreateHeap, (void **)&real_CreateHeap);
    patch_slot((void **)&vt->CreateRootSignature, (void *)hook_CreateRootSignature, (void **)&real_CreateRootSignature);
    patch_slot((void **)&vt->CreateCommandSignature, (void *)hook_CreateCommandSignature, (void **)&real_CreateCommandSignature);
    patch_slot((void **)&vt->CreateDescriptorHeap, (void *)hook_CreateDescriptorHeap, (void **)&real_CreateDescriptorHeap);
    patch_slot((void **)&vt->CreateCommandList, (void *)hook_CreateCommandList, (void **)&real_CreateCommandList);
    if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12Device4, &p)) && p) {
        ID3D12Device4Vtbl *v4 = *(ID3D12Device4Vtbl **)p;
        patch_slot((void **)&v4->CreateCommittedResource1, (void *)hook_CreateCommittedResource1, (void **)&real_CreateCommittedResource1);
        patch_slot((void **)&v4->CreateHeap1, (void *)hook_CreateHeap1, (void **)&real_CreateHeap1);
        patch_slot((void **)&v4->CreateReservedResource1, (void *)hook_CreateReservedResource1, (void **)&real_CreateReservedResource1);
        ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p); p = NULL;
    }
    if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12Device8, &p)) && p) {
        ID3D12Device8Vtbl *v8 = *(ID3D12Device8Vtbl **)p;
        patch_slot((void **)&v8->CreateCommittedResource2, (void *)hook_CreateCommittedResource2, (void **)&real_CreateCommittedResource2);
        patch_slot((void **)&v8->CreatePlacedResource1, (void *)hook_CreatePlacedResource1, (void **)&real_CreatePlacedResource1);
        ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p); p = NULL;
    }
    if (SUCCEEDED(u->lpVtbl->QueryInterface(u, &IID_ID3D12Device10, &p)) && p) {
        ID3D12Device10Vtbl *v10 = *(ID3D12Device10Vtbl **)p;
        patch_slot((void **)&v10->CreateCommittedResource3, (void *)hook_CreateCommittedResource3, (void **)&real_CreateCommittedResource3);
        patch_slot((void **)&v10->CreatePlacedResource2, (void *)hook_CreatePlacedResource2, (void **)&real_CreatePlacedResource2);
        patch_slot((void **)&v10->CreateReservedResource2, (void *)hook_CreateReservedResource2, (void **)&real_CreateReservedResource2);
        ((IUnknown *)p)->lpVtbl->Release((IUnknown *)p);
    }
}

// The first device gets the query heap, the buffer its results are resolved into, and the twin worker.
void inspect_device(ID3D12Device *dev)
{
    D3D12_QUERY_HEAP_DESC qd = { D3D12_QUERY_HEAP_TYPE_OCCLUSION, HEAP_SLOTS, 0 };
    D3D12_HEAP_PROPERTIES hp = { D3D12_HEAP_TYPE_READBACK, D3D12_CPU_PAGE_PROPERTY_UNKNOWN, D3D12_MEMORY_POOL_UNKNOWN, 0, 0 };
    D3D12_RESOURCE_DESC rd = { D3D12_RESOURCE_DIMENSION_BUFFER, 0, HEAP_SLOTS * 8, 1, 1, 1, DXGI_FORMAT_UNKNOWN, { 1, 0 }, D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE };
    HRESULT h1, h2 = E_FAIL, h3 = E_FAIL; void *map = NULL; int i;
    if (!inspect_on || idev) return;
    idev = dev; dev->lpVtbl->AddRef(dev);
    h1 = dev->lpVtbl->CreateQueryHeap(dev, &qd, &IID_ID3D12QueryHeap, (void **)&iheap);
    if (SUCCEEDED(h1)) h2 = dev->lpVtbl->CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_COPY_DEST, NULL, &IID_ID3D12Resource, (void **)&ireadback);
    if (SUCCEEDED(h2)) h3 = ireadback->lpVtbl->Map(ireadback, 0, NULL, &map);
    if (FAILED(h1) || FAILED(h2) || FAILED(h3) || !map) { iheap = NULL; ireadback = NULL; }
    else {
        ivalues = map;
        for (i = NCHUNKS - 1; i >= 0; i--) { chunks[i].base = i * CHUNK; chunks[i].next = free_chunks; free_chunks = &chunks[i]; }
        CreateThread(NULL, 0, twin_worker, NULL, 0, NULL);
    }
    ilog_line("device %p occlusion heap of %u hr 0x%08lx, readback hr 0x%08lx, map hr 0x%08lx", (void *)dev, HEAP_SLOTS,
              (unsigned long)h1, (unsigned long)h2, (unsigned long)h3);
    ilog_flush();
}

void inspect_init(void)
{
    char v[256], path[MAX_PATH]; DWORD n;
    if (!(n = GetEnvironmentVariableA("HB_TSSHIM_INSPECT", v, sizeof v)) || n >= sizeof v || v[0] != '1') return;
    inspect_on = 1;
    t_start = GetTickCount64();
    InitializeCriticalSection(&ilog_lock); InitializeCriticalSection(&store_lock); InitializeCriticalSection(&pmap_lock);
    InitializeCriticalSection(&twin_lock); InitializeCriticalSection(&chunk_lock); InitializeCriticalSection(&proc_lock);
    InitializeCriticalSection(&lmap_lock);
    twin_event = CreateEventA(NULL, FALSE, FALSE, NULL);
    if ((n = GetEnvironmentVariableA("HB_TSSHIM_INSPECT_PERIOD", v, sizeof v)) && n < sizeof v && atoi(v) > 0) period = (UINT64)atoi(v);
    if ((n = GetEnvironmentVariableA("HB_TSSHIM_INSPECT_WINDOW", v, sizeof v)) && n < sizeof v && atoi(v) > 0) window = (UINT64)atoi(v);
    if ((n = GetEnvironmentVariableA("HB_TSSHIM_INSPECT_MAX", v, sizeof v)) && n < sizeof v) max_investigated = atoi(v);
    inspect_serial = GetEnvironmentVariableA("HB_TSSHIM_INSPECT_SERIAL", v, sizeof v) == 1 && v[0] == '1';
    if ((n = GetEnvironmentVariableA("HB_TSSHIM_INSPECT_AFTER", v, sizeof v)) && n < sizeof v) after_psos = atoi(v);
    if ((n = GetEnvironmentVariableA("HB_TSSHIM_INSPECT_WATCH", v, sizeof v)) && n < sizeof v) {
        size_t i; for (i = 0; v[i] && i + 1 < sizeof watch; i++) watch[i] = (char)tolower((unsigned char)v[i]);
        watch[i] = 0;
    }
    CreateDirectoryA("C:\\highball", NULL); CreateDirectoryA("C:\\highball\\logs", NULL);
    snprintf(path, sizeof path, "C:\\highball\\logs\\inspect-%lu.log", (unsigned long)GetCurrentProcessId());
    if ((ilog = fopen(path, "w"))) setvbuf(ilog, NULL, _IOFBF, 1 << 16);
    ilog_line("start period %llu window %llu max %ld serial %d after %ld watch %s", (unsigned long long)period, (unsigned long long)window,
              (long)max_investigated, inspect_serial, (long)after_psos, watch[0] ? watch : "-");
    ilog_flush();
}
// At exit the other threads are gone: a lock one of them held stays taken, so nothing is written then.
void inspect_finish(void)
{
    if (!inspect_on || !ilog) return;
    if (!TryEnterCriticalSection(&ilog_lock)) return;
    LeaveCriticalSection(&ilog_lock);
    if (!TryEnterCriticalSection(&pmap_lock)) return;
    LeaveCriticalSection(&pmap_lock);
    summary(FALSE);
    ilog_line("end");
    ilog_flush();
}
