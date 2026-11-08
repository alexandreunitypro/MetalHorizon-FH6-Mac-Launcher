# Blackwell Engine Native

The native Apple silicon engine MetalHorizon 1.0 uses for Forza Horizon 6 (Xbox / Microsoft Store edition).

## What is in it, and where it comes from

- **Wine 11.18** (WineHQ, LGPL-2.1+), built for arm64 (ARM64EC, aarch64 and i386 for WoW64) from
  `https://dl.winehq.org/wine/source/11.x/wine-11.18.tar.xz`, with:
  - Highball's arm64 patch series (`patches-arm64`, branch `arm64-games` of
    https://github.com/gauthierpiarrette/highball-engine, through 0054), by Gauthier Piarrette and the
    contributors named in that folder's README;
  - Blackwell Engine's Xbox patches ported to Wine 11.18 (`engine/patches-arm64-xbox/` in
    https://github.com/alexandreunitypro/MetalHorizon-FH6-Mac-Launcher): the Xbox game runtime
    (xgameruntime, from xodus), Xbox app packages, msixvc images, network, audio and GameInput.
- **From Highball's engine release** `engine-arm64-wine-11.18-20261104T130327Z-arm64-games-0053-0054` (unchanged):
  FEX 2610 with Highball's FEX patches (MIT) as `xtajit64.dll` / `xtajit.dll` and its Darwin helper; GStreamer 1.28.7
  and winegstreamer (LGPL-2.1); the host libraries Wine opens by name (FreeType, GnuTLS, SDL and what they link);
  Wine Mono and Wine Gecko.
- **KosmicKrisp** (Mesa's Vulkan driver on Metal 4, MIT, with steamac's and Highball's patches) and the Khronos
  Vulkan loader (Apache-2.0), from Highball's release `kosmickrisp-arm64-20261104T165852Z-push`.
- **vkd3d-proton** (LGPL-2.1) and **DXVK** (zlib), ARM64EC builds with Highball's patches, from Highball's release
  `renderers-arm64-20261031T230303Z-manual`.

## What is not in it

The loader. A native Wine needs Apple's cross-architecture entitlement on its loader process, which only a signed
app bundle with a provisioning profile can carry. MetalHorizon downloads Highball's official release, takes its
signed `WineLoader.app` (Developer ID team B95M7DARU4, notarized), checks that signature, and links this engine's
`wine` to it.

No game files, no DRM or licence bypass: the Xbox game runs from your own copy, licensed to your Microsoft account.

## Thanks

Gauthier Piarrette and Highball's contributors (ineshd for FEX 0034, steamac for KosmicKrisp), the Wine, FEX,
Mesa, vkd3d-proton, DXVK and GStreamer projects, and xodus.
