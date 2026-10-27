/* dxil_shadingrate: makes a DXIL pixel shader that reads SV_ShadingRate drawable on D3DMetal.
 *
 * The Metal shader converter inside D3DMetal 4.0b3 has no mapping for SV_ShadingRate ("[metal-shaderconverter]
 * Warning: Unsupported: shadingrate") and turns the pixel shader input into an ordinary varying,
 * user(sv_shadingrate0), which the vertex shader never writes. Metal then refuses the pipeline ("Fragment
 * input(s) `user(sv_shadingrate0)` mismatching vertex shader output type(s) or not written by vertex
 * shader") and D3DMetal draws nothing with it ("marking PSO(N) as no-op"): Forza Horizon 6 lost 148
 * pipelines that way, all built on one vertex shader with 50 pixel shaders.
 *
 * D3DMetal reports VariableShadingRateTier 0, so on Windows such a shader would read
 * D3D12_SHADING_RATE_1X1, which is 0. The input is relabelled SV_ViewportArrayIndex: same type (uint),
 * same packing and interpolation, and Metal hands the fragment its [[viewport_array_index]], 0 when the
 * vertex shader does not write one, without asking the vertex shader for it (tools/dxilbench checks
 * both: the pipeline is accepted and the shader reads 0).
 *
 * Three places name the semantic kind and all three are changed: the signature metadata of the DXIL
 * bitcode (the i8 constant 29 = DXIL::SemanticKind::ShadingRate becomes 5 = ViewPortArrayIndex, rewritten in
 * place with the same bit width, so nothing else in the bitstream moves), the ISG1 part (D3D_NAME_SHADINGRATE
 * 24 -> D3D_NAME_VIEWPORT_ARRAY_INDEX 5) and the PSV0 part. D3DMetal keeps its translations on disk
 * (<cache dir>/d3dm/<exe>/shaders.cache) under the shader hash of the HASH part ("vs=8<hash as two u64>..."
 * in its errors), not under the bytes, so that hash is changed too (a fixed tag mixed in), or the old,
 * refused translation would come back from the cache; then the container digest is computed again.
 * Plain C, no OS calls: built into the shim (PE) and into tools/dxilbench (macOS). */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "dxil_shadingrate.h"

#define KIND_SHADINGRATE 29
#define KIND_NEW 5                      /* DXIL::SemanticKind::ViewPortArrayIndex, same value in PSV0 */
#define D3D_NAME_SHADINGRATE_ 24
#define D3D_NAME_NEW 5                  /* D3D_NAME_VIEWPORT_ARRAY_INDEX */

static uint32_t rd32(const unsigned char *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void wr32(unsigned char *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }
#define FOURCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)

/* ---- container ------------------------------------------------------------------------------ */

static unsigned char *find_part(unsigned char *c, size_t size, uint32_t fourcc, uint32_t *part_size)
{
    uint32_t count, i;
    if (size < 32 || rd32(c) != FOURCC('D', 'X', 'B', 'C') || rd32(c + 24) > size) return NULL;
    count = rd32(c + 28);
    if (count > 64 || 32 + (size_t)count * 4 > size) return NULL;
    for (i = 0; i < count; i++) {
        uint32_t off = rd32(c + 32 + i * 4);
        if ((size_t)off + 8 > size) return NULL;
        if (rd32(c + off) == fourcc) {
            *part_size = rd32(c + off + 4);
            if ((size_t)off + 8 + *part_size > size) return NULL;
            return c + off + 8;
        }
    }
    return NULL;
}

/* ---- the container digest: MD5 with the DXBC padding (vkd3d-shader's checksum.c, VKD3D_MD5_DXBC) ---- */

#define F1(x, y, z) (z ^ (x & (y ^ z)))
#define F2(x, y, z) F1(z, x, y)
#define F3(x, y, z) (x ^ y ^ z)
#define F4(x, y, z) (y ^ (x | ~z))
#define STEP(f, w, x, y, z, data, s) (w += f(x, y, z) + data, w = w << s | w >> (32 - s), w += x)

static void md5_transform(uint32_t buf[4], const unsigned char *block)
{
    uint32_t in[16], a = buf[0], b = buf[1], c = buf[2], d = buf[3]; int i;
    for (i = 0; i < 16; i++) in[i] = rd32(block + i * 4);
    STEP(F1, a, b, c, d, in[0] + 0xd76aa478, 7);   STEP(F1, d, a, b, c, in[1] + 0xe8c7b756, 12);
    STEP(F1, c, d, a, b, in[2] + 0x242070db, 17);  STEP(F1, b, c, d, a, in[3] + 0xc1bdceee, 22);
    STEP(F1, a, b, c, d, in[4] + 0xf57c0faf, 7);   STEP(F1, d, a, b, c, in[5] + 0x4787c62a, 12);
    STEP(F1, c, d, a, b, in[6] + 0xa8304613, 17);  STEP(F1, b, c, d, a, in[7] + 0xfd469501, 22);
    STEP(F1, a, b, c, d, in[8] + 0x698098d8, 7);   STEP(F1, d, a, b, c, in[9] + 0x8b44f7af, 12);
    STEP(F1, c, d, a, b, in[10] + 0xffff5bb1, 17); STEP(F1, b, c, d, a, in[11] + 0x895cd7be, 22);
    STEP(F1, a, b, c, d, in[12] + 0x6b901122, 7);  STEP(F1, d, a, b, c, in[13] + 0xfd987193, 12);
    STEP(F1, c, d, a, b, in[14] + 0xa679438e, 17); STEP(F1, b, c, d, a, in[15] + 0x49b40821, 22);
    STEP(F2, a, b, c, d, in[1] + 0xf61e2562, 5);   STEP(F2, d, a, b, c, in[6] + 0xc040b340, 9);
    STEP(F2, c, d, a, b, in[11] + 0x265e5a51, 14); STEP(F2, b, c, d, a, in[0] + 0xe9b6c7aa, 20);
    STEP(F2, a, b, c, d, in[5] + 0xd62f105d, 5);   STEP(F2, d, a, b, c, in[10] + 0x02441453, 9);
    STEP(F2, c, d, a, b, in[15] + 0xd8a1e681, 14); STEP(F2, b, c, d, a, in[4] + 0xe7d3fbc8, 20);
    STEP(F2, a, b, c, d, in[9] + 0x21e1cde6, 5);   STEP(F2, d, a, b, c, in[14] + 0xc33707d6, 9);
    STEP(F2, c, d, a, b, in[3] + 0xf4d50d87, 14);  STEP(F2, b, c, d, a, in[8] + 0x455a14ed, 20);
    STEP(F2, a, b, c, d, in[13] + 0xa9e3e905, 5);  STEP(F2, d, a, b, c, in[2] + 0xfcefa3f8, 9);
    STEP(F2, c, d, a, b, in[7] + 0x676f02d9, 14);  STEP(F2, b, c, d, a, in[12] + 0x8d2a4c8a, 20);
    STEP(F3, a, b, c, d, in[5] + 0xfffa3942, 4);   STEP(F3, d, a, b, c, in[8] + 0x8771f681, 11);
    STEP(F3, c, d, a, b, in[11] + 0x6d9d6122, 16); STEP(F3, b, c, d, a, in[14] + 0xfde5380c, 23);
    STEP(F3, a, b, c, d, in[1] + 0xa4beea44, 4);   STEP(F3, d, a, b, c, in[4] + 0x4bdecfa9, 11);
    STEP(F3, c, d, a, b, in[7] + 0xf6bb4b60, 16);  STEP(F3, b, c, d, a, in[10] + 0xbebfbc70, 23);
    STEP(F3, a, b, c, d, in[13] + 0x289b7ec6, 4);  STEP(F3, d, a, b, c, in[0] + 0xeaa127fa, 11);
    STEP(F3, c, d, a, b, in[3] + 0xd4ef3085, 16);  STEP(F3, b, c, d, a, in[6] + 0x04881d05, 23);
    STEP(F3, a, b, c, d, in[9] + 0xd9d4d039, 4);   STEP(F3, d, a, b, c, in[12] + 0xe6db99e5, 11);
    STEP(F3, c, d, a, b, in[15] + 0x1fa27cf8, 16); STEP(F3, b, c, d, a, in[2] + 0xc4ac5665, 23);
    STEP(F4, a, b, c, d, in[0] + 0xf4292244, 6);   STEP(F4, d, a, b, c, in[7] + 0x432aff97, 10);
    STEP(F4, c, d, a, b, in[14] + 0xab9423a7, 15); STEP(F4, b, c, d, a, in[5] + 0xfc93a039, 21);
    STEP(F4, a, b, c, d, in[12] + 0x655b59c3, 6);  STEP(F4, d, a, b, c, in[3] + 0x8f0ccc92, 10);
    STEP(F4, c, d, a, b, in[10] + 0xffeff47d, 15); STEP(F4, b, c, d, a, in[1] + 0x85845dd1, 21);
    STEP(F4, a, b, c, d, in[8] + 0x6fa87e4f, 6);   STEP(F4, d, a, b, c, in[15] + 0xfe2ce6e0, 10);
    STEP(F4, c, d, a, b, in[6] + 0xa3014314, 15);  STEP(F4, b, c, d, a, in[13] + 0x4e0811a1, 21);
    STEP(F4, a, b, c, d, in[4] + 0xf7537e82, 6);   STEP(F4, d, a, b, c, in[11] + 0xbd3af235, 10);
    STEP(F4, c, d, a, b, in[2] + 0x2ad7d2bb, 15);  STEP(F4, b, c, d, a, in[9] + 0xeb86d391, 21);
    buf[0] += a; buf[1] += b; buf[2] += c; buf[3] += d;
}

void dxil_container_digest(const unsigned char *c, size_t size, unsigned char digest[16])
{
    uint32_t buf[4] = { 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476 }, bits; unsigned char block[64];
    const unsigned char *p = c + 20; size_t n = size - 20, full = n & ~(size_t)63, left = n - full, i;
    bits = (uint32_t)(n * 8);
    for (i = 0; i < full; i += 64) md5_transform(buf, p + i);
    memset(block, 0, sizeof block);
    if (left + 1 > 56) {                  /* no room for the trailer: pad this block, then a block of zeros */
        memcpy(block, p + full, left); block[left] = 0x80;
        md5_transform(buf, block);
        memset(block, 0, sizeof block);
    } else {                              /* bit count first, then the tail and 0x80 */
        memcpy(block + 4, p + full, left); block[4 + left] = 0x80;
    }
    wr32(block, bits); wr32(block + 60, bits >> 2 | 1);
    md5_transform(buf, block);
    for (i = 0; i < 4; i++) wr32(digest + i * 4, buf[i]);
}

/* ---- LLVM bitstream (DXIL is LLVM 3.7 bitcode): just enough to find one constant ---------------- */

enum { ENC_FIXED = 1, ENC_VBR = 2, ENC_ARRAY = 3, ENC_CHAR6 = 4, ENC_BLOB = 5, ENC_LITERAL = 8 };
typedef struct { uint8_t enc; uint32_t val; } AbbrevOp;
typedef struct { uint8_t nops; AbbrevOp op[16]; } Abbrev;
#define MAX_ABBREVS 64
typedef struct { uint32_t block; Abbrev a; } InfoAbbrev;

typedef struct {
    unsigned char *data; size_t bits; size_t pos; int bad;
    InfoAbbrev info[128]; int ninfo;     /* BLOCKINFO abbreviations, by block id */
} Bits;

static uint64_t fixed(Bits *b, unsigned n)
{
    uint64_t v = 0; unsigned i;
    if (n > 64 || b->pos + n > b->bits) { b->bad = 1; b->pos = b->bits; return 0; }
    for (i = 0; i < n; i++, b->pos++) v |= (uint64_t)((b->data[b->pos >> 3] >> (b->pos & 7)) & 1) << i;
    return v;
}
static uint64_t vbr(Bits *b, unsigned n)
{
    uint64_t v = 0, chunk; unsigned shift = 0;
    if (n < 2) { b->bad = 1; return 0; }
    do {
        chunk = fixed(b, n);
        if (shift < 64) v |= (chunk & ((1u << (n - 1)) - 1)) << shift;
        shift += n - 1;
    } while ((chunk >> (n - 1)) & 1 && !b->bad && shift < 70);
    return v;
}
static void align32(Bits *b) { b->pos = (b->pos + 31) & ~(size_t)31; if (b->pos > b->bits) b->bad = 1; }
static void put_bits(Bits *b, size_t pos, uint64_t v, unsigned n)
{
    unsigned i;
    for (i = 0; i < n; i++, pos++) {
        unsigned char m = 1 << (pos & 7);
        if ((v >> i) & 1) b->data[pos >> 3] |= m; else b->data[pos >> 3] &= ~m;
    }
}

static int read_abbrev(Bits *b, Abbrev *a)
{
    unsigned n = (unsigned)vbr(b, 5), i;
    a->nops = 0;
    for (i = 0; i < n && !b->bad; i++) {
        AbbrevOp op;
        if (fixed(b, 1)) { op.enc = ENC_LITERAL; op.val = (uint32_t)vbr(b, 8); }
        else {
            op.enc = (uint8_t)fixed(b, 3); op.val = 0;
            if (op.enc == ENC_FIXED || op.enc == ENC_VBR) {
                op.val = (uint32_t)vbr(b, 5);
                if (!op.val) { op.enc = ENC_LITERAL; op.val = 0; }   /* Fixed(0)/VBR(0) read as a literal 0 */
            } else if (op.enc != ENC_ARRAY && op.enc != ENC_CHAR6 && op.enc != ENC_BLOB) b->bad = 1;
        }
        if (a->nops >= 16) { b->bad = 1; return 0; }
        a->op[a->nops++] = op;
    }
    return !b->bad;
}

/* Where one scalar operand sits in the stream, and how it is encoded. */
typedef struct { size_t pos; uint8_t enc; uint8_t width; uint8_t chunks; } Field;

static uint64_t read_scalar(Bits *b, const AbbrevOp *op, Field *f)
{
    uint64_t v; size_t start = b->pos;
    if (f) { f->pos = start; f->enc = op->enc; f->width = (uint8_t)op->val; f->chunks = 1; }
    switch (op->enc) {
    case ENC_LITERAL: return op->val;
    case ENC_FIXED: return fixed(b, op->val);
    case ENC_VBR: v = vbr(b, op->val); if (f && op->val) f->chunks = (uint8_t)((b->pos - start) / op->val); return v;
    case ENC_CHAR6: return fixed(b, 6);
    }
    b->bad = 1; return 0;
}

/* Reads one record. ops[] gets up to max operands (code excluded); field0 locates operand 0. */
static int read_record(Bits *b, unsigned id, const Abbrev *abbrevs, int nabbrevs, unsigned *code, uint64_t *ops, unsigned max, unsigned *nops, Field *field0)
{
    unsigned n = 0, i, j;
    if (id == 3) {                                       /* UNABBREV_RECORD: everything VBR6 */
        unsigned cnt; *code = (unsigned)vbr(b, 6); cnt = (unsigned)vbr(b, 6);
        for (i = 0; i < cnt && !b->bad; i++) {
            size_t start = b->pos; uint64_t v = vbr(b, 6);
            if (i == 0 && field0) { field0->pos = start; field0->enc = ENC_VBR; field0->width = 6; field0->chunks = (uint8_t)((b->pos - start) / 6); }
            if (n < max) ops[n] = v;
            n++;
        }
    } else {
        const Abbrev *a; int first = 1;
        if (id < 4 || (int)(id - 4) >= nabbrevs) { b->bad = 1; return 0; }
        a = &abbrevs[id - 4];
        for (i = 0; i < a->nops && !b->bad; i++) {
            const AbbrevOp *op = &a->op[i];
            if (op->enc == ENC_ARRAY) {
                unsigned len = (unsigned)vbr(b, 6);
                if (i + 1 >= a->nops) { b->bad = 1; break; }
                for (j = 0; j < len && !b->bad; j++) { uint64_t v = read_scalar(b, &a->op[i + 1], NULL); if (first) { *code = (unsigned)v; first = 0; } else { if (n < max) ops[n] = v; n++; } }
                i++;
            } else if (op->enc == ENC_BLOB) {
                unsigned len = (unsigned)vbr(b, 6);
                align32(b); b->pos += (size_t)len * 8; align32(b);
                if (b->pos > b->bits) b->bad = 1;
                n++;
            } else {
                Field f; uint64_t v = read_scalar(b, op, &f);
                if (first) { *code = (unsigned)v; first = 0; }
                else { if (n == 0 && field0) *field0 = f; if (n < max) ops[n] = v; n++; }
            }
        }
    }
    *nops = n;
    return !b->bad;
}

static void add_info(Bits *b, uint32_t block, const Abbrev *a)
{
    if (b->ninfo < (int)(sizeof b->info / sizeof *b->info)) { b->info[b->ninfo].block = block; b->info[b->ninfo].a = *a; b->ninfo++; }
    else b->bad = 1;
}

/* Abbreviations a block starts with: those BLOCKINFO gave its id. */
static int block_abbrevs(Bits *b, uint32_t block, Abbrev *out)
{
    int i, n = 0;
    for (i = 0; i < b->ninfo && n < MAX_ABBREVS; i++) if (b->info[i].block == block) out[n++] = b->info[i].a;
    return n;
}

static void parse_blockinfo(Bits *b, unsigned width)
{
    uint32_t cur = ~0u;
    while (!b->bad) {
        unsigned id = (unsigned)fixed(b, width);
        if (id == 0) { align32(b); return; }
        if (id == 1) { b->bad = 1; return; }
        if (id == 2) { Abbrev a; if (read_abbrev(b, &a) && cur != ~0u) add_info(b, cur, &a); else b->bad = 1; continue; }
        {
            unsigned code, nops; uint64_t ops[4];
            if (!read_record(b, id, NULL, 0, &code, ops, 4, &nops, NULL)) return;
            if (code == 1 && nops >= 1) cur = (uint32_t)ops[0];    /* SETBID */
        }
    }
}

static int skip_block(Bits *b)
{
    uint32_t words; vbr(b, 4); align32(b); words = (uint32_t)fixed(b, 32);
    b->pos += (size_t)words * 32;
    if (b->pos > b->bits) b->bad = 1;
    return !b->bad;
}

/* Enters a subblock whose id was just read. */
static unsigned enter_block(Bits *b, size_t *end)
{
    unsigned width = (unsigned)vbr(b, 4); uint32_t words;
    align32(b); words = (uint32_t)fixed(b, 32);
    *end = b->pos + (size_t)words * 32;
    if (*end > b->bits || width < 2 || width > 32) b->bad = 1;
    return width;
}

enum { BLOCKINFO = 0, MODULE = 8, CONSTANTS = 11, TYPES = 17 };

/* In the module-level CONSTANTS_BLOCK, the i8 INTEGER records with value `from` are re-encoded as `to`.
 * Returns how many, -1 on a bitstream this parser does not follow. */
static int patch_i8_constant(unsigned char *bc, size_t size, int64_t from, int64_t to)
{
    Bits b; Abbrev abbrevs[MAX_ABBREVS]; int nab; unsigned width; size_t mod_end;
    int64_t i8_type = -1, type_count = 0, patched = 0;
    memset(&b, 0, sizeof b); b.data = bc; b.bits = size * 8;
    if (size < 8 || bc[0] != 'B' || bc[1] != 'C' || bc[2] != 0xc0 || bc[3] != 0xde) return -1;
    b.pos = 32;
    /* top level: abbreviation width 2, find MODULE_BLOCK */
    for (;;) {
        unsigned id = (unsigned)fixed(&b, 2), block;
        if (b.bad || b.pos >= b.bits) return -1;
        if (id != 1) return -1;
        block = (unsigned)vbr(&b, 8);
        if (block == MODULE) break;
        if (!skip_block(&b)) return -1;
    }
    width = enter_block(&b, &mod_end); nab = 0;
    while (!b.bad && b.pos < mod_end) {
        unsigned id = (unsigned)fixed(&b, width);
        if (id == 0) break;
        if (id == 2) { if (nab >= MAX_ABBREVS || !read_abbrev(&b, &abbrevs[nab])) return -1; nab++; continue; }
        if (id == 1) {
            unsigned block = (unsigned)vbr(&b, 8), w; size_t end; Abbrev sub[MAX_ABBREVS]; int nsub;
            if (block == BLOCKINFO) { w = enter_block(&b, &end); parse_blockinfo(&b, w); if (b.bad || b.pos != end) return -1; continue; }
            if (block != TYPES && block != CONSTANTS) { if (!skip_block(&b)) return -1; continue; }
            w = enter_block(&b, &end); nsub = block_abbrevs(&b, block, sub);
            {
                int64_t cur_type = -1;
                while (!b.bad && b.pos < end) {
                    unsigned sid = (unsigned)fixed(&b, w), code, nops; uint64_t ops[4]; Field f0;
                    if (sid == 0) { align32(&b); break; }
                    if (sid == 1) { vbr(&b, 8); if (!skip_block(&b)) return -1; continue; }
                    if (sid == 2) { if (nsub >= MAX_ABBREVS || !read_abbrev(&b, &sub[nsub])) return -1; nsub++; continue; }
                    memset(&f0, 0, sizeof f0);
                    if (!read_record(&b, sid, sub, nsub, &code, ops, 4, &nops, &f0)) return -1;
                    if (block == TYPES) {
                        if (code == 1 || code == 19) continue;               /* NUMENTRY, STRUCT_NAME define no type */
                        if (code == 7 && nops >= 1 && ops[0] == 8 && i8_type < 0) i8_type = type_count;   /* INTEGER width 8 */
                        type_count++;
                    } else {
                        if (code == 1 && nops >= 1) { cur_type = (int64_t)ops[0]; continue; }   /* SETTYPE */
                        if (code == 4 && nops >= 1 && cur_type == i8_type && i8_type >= 0) {  /* INTEGER, signed VBR */
                            int64_t v = (ops[0] & 1) ? -(int64_t)(ops[0] >> 1) : (int64_t)(ops[0] >> 1);
                            uint64_t enc = to < 0 ? ((uint64_t)(-to) << 1) | 1 : (uint64_t)to << 1;
                            if (v != from) continue;
                            if (f0.enc == ENC_FIXED) {
                                if (f0.width < 64 && enc >> f0.width) return -1;
                                put_bits(&b, f0.pos, enc, f0.width);
                            } else if (f0.enc == ENC_VBR) {
                                unsigned k, dw = f0.width - 1;
                                if ((size_t)f0.chunks * dw < 64 && enc >> (f0.chunks * dw)) return -1;
                                for (k = 0; k < f0.chunks; k++) {           /* same chunk count: nothing after it moves */
                                    uint64_t chunk = (enc >> (k * dw)) & ((1u << dw) - 1);
                                    if (k + 1 < f0.chunks) chunk |= 1u << dw;
                                    put_bits(&b, f0.pos + (size_t)k * f0.width, chunk, f0.width);
                                }
                            } else return -1;
                            patched++;
                        }
                    }
                }
                if (b.bad || b.pos != end) return -1;
            }
            if (block == CONSTANTS) return (int)patched;   /* the module-level constants follow the types */
            continue;
        }
        { unsigned code, nops; uint64_t ops[1]; if (!read_record(&b, id, abbrevs, nab, &code, ops, 1, &nops, NULL)) return -1; }
    }
    return b.bad ? -1 : (int)patched;
}

/* ---- the parts -------------------------------------------------------------------------------- */

/* The bitcode inside a DXIL or ILDB part (DxilProgramHeader). Returns the shader kind (0 = pixel), -1 if malformed. */
static int program_bitcode(unsigned char *part, uint32_t size, unsigned char **bc, uint32_t *bc_size)
{
    uint32_t off, len;
    if (size < 24 || rd32(part + 8) != FOURCC('D', 'X', 'I', 'L')) return -1;
    off = rd32(part + 16); len = rd32(part + 20);
    if ((size_t)8 + off + len > size) return -1;
    *bc = part + 8 + off; *bc_size = len;
    return (int)(rd32(part) >> 16);
}

/* ISG1 elements (DxilProgramSignatureElement, 32 bytes) with SystemValue `from` become `to`. */
static int patch_isg1(unsigned char *part, uint32_t size, uint32_t from, uint32_t to, int apply)
{
    uint32_t count, off, i; int n = 0;
    if (size < 8) return -1;
    count = rd32(part); off = rd32(part + 4);
    if ((size_t)off + (size_t)count * 32 > size) return -1;
    for (i = 0; i < count; i++) {
        unsigned char *e = part + off + i * 32;
        if (rd32(e + 12) == from) { if (apply) wr32(e + 12, to); n++; }
    }
    return n;
}

/* PSV0 input signature elements (PSVSignatureElement0) with SemanticKind `from` become `to`. */
static int patch_psv0(unsigned char *part, uint32_t size, uint8_t from, uint8_t to, int apply)
{
    uint32_t info_size, res_count, at, strings, idx_count, elem_size, i; uint8_t inputs; int n = 0;
    if (size < 4) return -1;
    info_size = rd32(part); at = 4;
    if (info_size < 36 || (size_t)at + info_size + 4 > size) return -1;   /* needs PSVRuntimeInfo1 for the signature */
    inputs = part[at + 28];
    at += info_size;
    res_count = rd32(part + at); at += 4;
    if (res_count) {
        uint32_t res_size;
        if ((size_t)at + 4 > size) return -1;
        res_size = rd32(part + at); at += 4;
        if ((size_t)at + (size_t)res_count * res_size > size) return -1;
        at += res_count * res_size;
    }
    if ((size_t)at + 4 > size) return -1;
    strings = rd32(part + at); at += 4 + strings;
    if ((size_t)at + 4 > size) return -1;
    idx_count = rd32(part + at); at += 4 + idx_count * 4;
    if (!inputs) return 0;
    if ((size_t)at + 4 > size) return -1;
    elem_size = rd32(part + at); at += 4;
    if (elem_size < 16 || (size_t)at + (size_t)inputs * elem_size > size) return -1;
    for (i = 0; i < inputs; i++) {
        unsigned char *e = part + at + i * elem_size;
        if (e[11] == from) { if (apply) e[11] = to; n++; }
    }
    return n;
}

int dxil_reads_shadingrate(const unsigned char *c, size_t size)
{
    unsigned char *isg1; uint32_t isg1_size;
    if (!(isg1 = find_part((unsigned char *)c, size, FOURCC('I', 'S', 'G', '1'), &isg1_size))) return 0;
    return patch_isg1(isg1, isg1_size, D3D_NAME_SHADINGRATE_, D3D_NAME_NEW, 0) > 0;
}

int dxil_fix_shadingrate_input(unsigned char *c, size_t size, char *why, size_t why_size)
{
    unsigned char *isg1, *dxil, *ildb, *psv0, *hash, *bc; uint32_t isg1_size, dxil_size, ildb_size, psv0_size, hash_size, bc_size;
    int kind, n;
    why[0] = 0;
    if (!(isg1 = find_part(c, size, FOURCC('I', 'S', 'G', '1'), &isg1_size))) { snprintf(why, why_size, "no ISG1 part"); return 0; }
    n = patch_isg1(isg1, isg1_size, D3D_NAME_SHADINGRATE_, D3D_NAME_NEW, 0);
    if (n <= 0) { snprintf(why, why_size, n < 0 ? "unreadable ISG1" : "no SV_ShadingRate input"); return n < 0 ? -1 : 0; }
    if (n != 1) { snprintf(why, why_size, "%d SV_ShadingRate inputs", n); return -1; }
    if (!(dxil = find_part(c, size, FOURCC('D', 'X', 'I', 'L'), &dxil_size))) { snprintf(why, why_size, "no DXIL part"); return -1; }
    kind = program_bitcode(dxil, dxil_size, &bc, &bc_size);
    if (kind != 0) { snprintf(why, why_size, kind < 0 ? "unreadable DXIL part" : "not a pixel shader (kind %d)", kind); return kind < 0 ? -1 : 0; }
    n = patch_i8_constant(bc, bc_size, KIND_SHADINGRATE, KIND_NEW);
    if (n != 1) { snprintf(why, why_size, n < 0 ? "bitcode not followed" : "%d i8 %d constants in the bitcode", n, KIND_SHADINGRATE); return -1; }
    patch_isg1(isg1, isg1_size, D3D_NAME_SHADINGRATE_, D3D_NAME_NEW, 1);
    if ((ildb = find_part(c, size, FOURCC('I', 'L', 'D', 'B'), &ildb_size)) && program_bitcode(ildb, ildb_size, &bc, &bc_size) == 0)
        patch_i8_constant(bc, bc_size, KIND_SHADINGRATE, KIND_NEW);
    if ((psv0 = find_part(c, size, FOURCC('P', 'S', 'V', '0'), &psv0_size))) patch_psv0(psv0, psv0_size, KIND_SHADINGRATE, KIND_NEW, 1);
    if ((hash = find_part(c, size, FOURCC('H', 'A', 'S', 'H'), &hash_size)) && hash_size >= 20) {   /* DxilShaderHash: flags, digest */
        static const char tag[16] = "sv_shadingrate=0";
        int i; for (i = 0; i < 16; i++) hash[4 + i] ^= (unsigned char)tag[i];
    }
    dxil_container_digest(c, size, c + 4);
    snprintf(why, why_size, "SV_ShadingRate input read as SV_ViewportArrayIndex (0)");
    return 1;
}
