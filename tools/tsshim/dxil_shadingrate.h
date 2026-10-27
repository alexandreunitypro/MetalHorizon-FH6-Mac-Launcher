/* See dxil_shadingrate.c. */
#ifndef DXIL_SHADINGRATE_H
#define DXIL_SHADINGRATE_H
#include <stddef.h>
/* Returns 1 when the shader was changed, 0 when it has nothing to change (untouched), -1 when it cannot be
 * changed safely: the buffer may then be half-changed, so callers work on a copy and drop it.
 * why receives a short explanation. */
int dxil_fix_shadingrate_input(unsigned char *container, size_t size, char *why, size_t why_size);
/* 1 when the container's pixel shader input signature (ISG1) has an SV_ShadingRate element. Reads only. */
int dxil_reads_shadingrate(const unsigned char *container, size_t size);
/* The DXBC/DXIL container digest over container[20..size), as stored at container[4..20). */
void dxil_container_digest(const unsigned char *container, size_t size, unsigned char digest[16]);
#endif
