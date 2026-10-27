// HB_TSSHIM_INSPECT (inspect.c): what the game creates through D3D12, and where the pixels of each draw go.
#ifndef TSSHIM_INSPECT_H
#define TSSHIM_INSPECT_H
#include <windows.h>
#include <d3d12.h>

extern int inspect_on;
// HB_TSSHIM_INSPECT_SERIAL=1: pipelines are created one at a time and numbered as D3DMetal numbers them ("PSO(N)" in its
// errors). Off by default: the inspector numbers them itself (inspect_next_id) and creation runs as without it.
extern int inspect_serial;
unsigned inspect_next_id(void);
void inspect_init(void);
void inspect_finish(void);
void inspect_device(ID3D12Device *dev);
void inspect_patch_device(void *iface);
void inspect_patch_list(void *iface);
void inspect_patch_queue(void *iface);
void inspect_game_query(ID3D12GraphicsCommandList *list, ID3D12QueryHeap *heap, D3D12_QUERY_TYPE type, BOOL begin);
// A pipeline as the game described it (game) and as it went to D3DMetal (fixed); seq is D3DMetal's number for it,
// ~0u for one loaded from a pipeline library. Called after creation, while both descriptions are still valid.
void inspect_graphics(void *pso, unsigned seq, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *game,
                      const D3D12_GRAPHICS_PIPELINE_STATE_DESC *fixed, ID3D12Device *dev, HRESULT hr);
void inspect_stream(void *pso, unsigned seq, const D3D12_PIPELINE_STATE_STREAM_DESC *game,
                    const D3D12_PIPELINE_STATE_STREAM_DESC *fixed, ID3D12Device *dev, HRESULT hr);
void inspect_compute(void *pso, unsigned seq, const D3D12_COMPUTE_PIPELINE_STATE_DESC *d, HRESULT hr);

// from d3d12.c
void patch_slot(void **slot, void *hook, void **saved);
SIZE_T stream_inner_size(UINT type, SIZE_T *inner_align);
extern CRITICAL_SECTION pso_lock;
extern unsigned pso_seq;
extern HRESULT (STDMETHODCALLTYPE *real_CreateGraphicsPipelineState)(ID3D12Device *, const D3D12_GRAPHICS_PIPELINE_STATE_DESC *, REFIID, void **);
extern HRESULT (STDMETHODCALLTYPE *real_CreatePipelineState)(ID3D12Device2 *, const D3D12_PIPELINE_STATE_STREAM_DESC *, REFIID, void **);
#endif
