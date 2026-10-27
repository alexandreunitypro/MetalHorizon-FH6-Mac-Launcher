# D3DMetal timestamp/compat shim (tsshim)

`d3d12.c` and `d3d12.def` are copied verbatim from Highball, by Gauthier Piarrette:
https://github.com/gauthierpiarrette/highball/tree/main/spike/tsshim

Highball is licensed **GPL-3.0**. These files keep that license. See
https://github.com/gauthierpiarrette/highball/blob/main/LICENSE

What the shim does (its own header comment has the details and the measurements):
- Serves DirectX 12 timestamp queries D3DMetal 3.0 lacks.
- `CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL)` with a model D3DMetal doesn't know returns
  `E_INVALIDARG`; the hook asks again with lower values and returns the highest supported. This is
  what clears Forza Horizon 6's "graphics card not supported" (FH205/FH206) after a game update.
- Drops `ResolveSubresource` from a multisampled depth texture (a Metal assertion that froze FH6 at
  character select). `HB_TSSHIM_DEPTHRESOLVE=1` lets it through.
- Writes `D3D12_APPEND_ALIGNED_ELEMENT` input-layout offsets explicitly (FH6, 2026-10-20).
  `HB_TSSHIM_APPEND_OFFSETS=0` turns it off.

`tools/pe_tools.py` (mark-builtin, rename-export) is ported from Highball's `Scripts/mark-builtin.py`
and `Sources/HighballKit/PEExportName.swift` (same GPL-3.0).
