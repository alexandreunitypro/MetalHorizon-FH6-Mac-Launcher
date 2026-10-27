# MetalHorizon – FH6 Mac Launcher

**Run your own Xbox / Microsoft Store copy of Forza Horizon 6 on an Apple Silicon Mac.**
Blackwell Engine (Wine) + xodus + Apple's D3DMetal, open source, no CrossOver, no DRM bypass.

## Download

**[MetalHorizon (latest prototype)](../../releases)**: unzip, move **MetalHorizon** to Applications, then
right-click it → **Open** the first time (it is not notarized yet).

The app does the rest by itself: it installs [Blackwell Engine](https://github.com/alexandreunitypro/blackwell-engine)
and Apple's D3DMetal (after you accept Apple's licence), you sign in with your Microsoft account on Microsoft's own
page, click **Download from Xbox**, then **Play**. No CrossOver, nothing to download by hand.

> **Prototype.** Tested on one Mac so far (M5 Pro, macOS 27). Known: stutter, black near foliage. This is for the
> **Xbox / Microsoft Store** edition (MSIXVC). If you own the **Steam** edition, use
> [Highball](https://github.com/gauthierpiarrette/highball).

Unofficial. Not affiliated with or endorsed by Microsoft, Xbox, Playground Games, Apple, CodeWeavers or NVIDIA.
Forza Horizon and Xbox are trademarks of Microsoft. You need your own copy of the game on your Microsoft account.

## Status (25 October 2026)

Tested on one machine: MacBook Pro 16" M5 Pro (18-core CPU, 20-core GPU, 48 GB), macOS 27.0.1.

| Area | Status |
|---|---|
| Boot, license, Xbox sign-in | ✅ Works. Sign-in uses a code on microsoft.com/link, once. |
| Cloud saves (PlayFab) | ✅ Sync works. |
| Engine sound on Mac speakers | ✅ Fixed (7.1 / 7.1.4 streams were played as front left/right only). |
| Online (Horizon Play matchmaking) | ✅ Connects to the game's dedicated servers (24 October). Crashes still happen in online sessions. |
| Missing objects (pipelines D3DMetal skipped) | ✅ 221 → 0 in game, fixed in the DirectX 12 shim. |
| Black near foliage | ❌ Open. Cause narrowed down (see [Rendering notes](#rendering-notes)). |
| Frame pacing | ❌ About 36 fps average, with 6 freezes of 175–300 ms every 25 s. Top priority. |
| Crash while the map loads | ⚠️ In Apple's Metal driver; so far only with the diagnostic inspector on. |
| Launcher | ✅ MetalHorizon installs everything by itself (prototype, not notarized). |

Known issue: leave the in-game ray tracing options alone; changing them has crashed the game (FHE11).

## What this project does and does not do

- **The game's files are never modified or redistributed.** The executable is not patched.
- **The copy protection, the license check and the anti-cheat are not bypassed.** The game accepts its own
  license. Every fix lives in the compatibility layer: Wine, the DirectX 12 shim, xodus. The protection even
  rejects a diagnostic change in Wine's PE `ntdll.dll` exception path (3 crashes in 3 starts), so that path stays
  stock.
- [xodus](https://github.com/xodus-gaming/xodus) decrypts the MSIXVC package with your own account's license,
  as the Xbox app does on Windows. The game files stay encrypted on disk.
- **Your Microsoft password never goes through this project.** You sign in on Microsoft's own page with a code;
  `xodus-service` keeps the account in the macOS Keychain.
- Like Highball's recipe, the game is shown an NVIDIA GPU ID (RTX 4070) so its hardware check (FH205/FH206) passes.
- Nothing from CrossOver.app is used. Apple's D3DMetal is downloaded by the app, unmodified, only after you accept
  Apple's licence (which allows it to be shared separately for non-commercial use).

This is unofficial software. Nobody can promise Microsoft will never act on an account used this way, especially
online. Use it at your own risk.

## Requirements

- Apple Silicon Mac, **macOS 27** or later. Memory use is high; only 48 GB has been tested so far.
- About 160 GB free, outside iCloud-synced folders (the Desktop is a bad place for the game).
- Forza Horizon 6, Xbox / Microsoft Store edition, on your Microsoft account. Game Pass is untested.
- That's all. The MetalHorizon app downloads **Blackwell Engine** and **D3DMetal 4** by itself, then the game from the
  Xbox servers. No CrossOver, no manual download.

## How it works

```
forzahorizon6.exe          (decrypted in memory by xodus, never written back)
  └─ Blackwell Engine      Wine 11 from CrossOver 26.3's LGPL sources + Ferestre + Highball + this repo's patches,
      │                    with its own GnuTLS, FreeType and MoltenVK (engine/)
      ├─ xgameruntime      Xbox layer: tokens from xodus-service, PlayFab cloud saves
      ├─ d3d12.dll shim    Highball's shim + this repo's shader fixes and inspector
      │   └─ D3DMetal 4    DirectX 12 → Metal (Apple's Game Porting Toolkit redist, unmodified)
      └─ Core Audio        surround mixed down for the Mac's speakers
```

## What gets compiled

Everything below is built on the Mac. Each script keeps a `.bak` of what it replaces and has `--undo`.

| Component | Built with | Script |
|---|---|---|
| **Wine engine**: CrossOver 26.3 sources + [Ferestre](https://github.com/icex/ferestre) 0006/0009/0010/0013 | Xcode Command Line Tools, llvm-mingw 20260908 | your own build, then the scripts below |
| Wine patches from this repo, [`patches/wine/`](patches/wine/): mapped image reopen (0001), WebSocket (0002), `SIO_UDP_NETRESET` (0003), `SendARP` (0004), diagnostic channels (0005), dual-stack IPv4 options (0006) | same | 0001: `tools/mac_apply_wine_fix.sh`; the others: `git apply`, then rebuild the DLL they touch |
| Highball's Forza patches, [`tools/forza-patches/`](tools/forza-patches/): 0017–0020, 0022–0025 | same | `tools/mac_apply_forza_patches.sh`, `tools/mac_fix_audio_surround.sh` |
| Wine fixes: FreeType, GnuTLS, `WinHttpQueryHeaders`, leaf unwind, fonts | same | `tools/mac_enable_freetype.sh`, `tools/mac_enable_gnutls.sh`, `tools/mac_fix_winhttp_headers.sh`, `tools/mac_fix_leaf_unwind.sh`, `tools/mac_fix_fonts.sh` |
| `xgameruntime.dll`: async completions after the call returns, as on Windows | llvm-mingw | `tools/mac_fix_xasync_inline.sh` |
| Unix-side fault report in `ntdll.so` (diagnostic only) | Xcode CLT | `tools/mac_trace_faults.sh` |
| **xodus-cli / xodus-service** + [`patches/xodus-cli/`](patches/xodus-cli/): named decrypted image on macOS (0001), title-authenticated XSTS for online play (0002) | Rust (`cargo build --release`) | `tools/mac_apply_xodus_fix.sh` |
| **DirectX 12 shim** `d3d12.dll`: Highball's [`tsshim`](tools/tsshim/) + `dxil_shadingrate.c` + `inspect.c` | llvm-mingw | `tools/mac_setup_tsshim.sh` |
| Replacement shaders (skid marks) | D3DMetal's own DXC | `tools/mac_shader_fixes.sh` |
| `dxilbench`: native shader bench using D3DMetal's compiler and Metal IR converter | `clang++ -arch x86_64` | `tools/mac_vrs_probe.sh`, `tools/mac_shader_fixes.sh`, `tools/mac_pso_report.sh` |
| Test programs that run without the game: `d3d12probe`, `vrsprobe`, `inspectprobe`, `gpuprobe`, `fontprobe`, `audioprobe`, `httpprobe`, `wsprobe`, `asyncprobe`, `excprobe`, `cpuidprobe`, `selfread`, `winlist` | llvm-mingw | the matching `tools/mac_*_probe.sh` |

An experimental launch on [Mullion](https://github.com/dttdrv/mullion) (a DXMT fork) instead of D3DMetal is in
`tools/mac_launch_fh6_mullion.sh`. No result yet.

## Rendering notes

What was found while fixing the graphics, 24–25 October 2026. Details and evidence: [`docs/PASSATION-IA.md`](docs/PASSATION-IA.md) (French).

**Missing objects: 221 pipelines → 0.** D3DMetal marked 221 pipelines as "no-op" and skipped every draw that used them.

1. **`SV_ShadingRate` (148 pipelines).** D3DMetal already reports no variable-rate shading (tier 0), but some
   pixel shaders still read `SV_ShadingRate`. Metal's converter turns it into an input the vertex shader never
   writes, and Metal refuses the pipeline. The shim relabels that input as `SV_ViewportArrayIndex` in the DXIL
   (Metal provides it; 0 means 1×1, the value without VRS). **Trap:** D3DMetal caches its translations on disk
   under the shader's `HASH` part, not its bytes, so the shim rewrites `HASH` too, or the broken translation comes
   back from the cache.
2. **Dual-source blending without a color target (65 pipelines).** Shadow passes of glass, water, ocean and
   dithered materials keep the material's `SRC1` blend with no color target. D3DMetal then forces dual-source
   blending, which the converter refuses. The shim turns that unused blend off.
3. **Skid marks (8 pipelines).** Real dual-source blending, but the pixel shader writes three outputs and Metal
   wants exactly two. The same shader also serves a three-target decal pass, so only the dual-source pipelines get
   a replacement shader without the third output, built by `tools/mac_shader_fixes.sh`. A game update changes the
   shader hashes: the fix then stops applying, with no other effect.

Result in game (6 minutes with the inspector): 22,875 pipelines, 0 refused, 0 skipped.

**Black near foliage: cause narrowed down, not fixed.** The inspector (`HB_TSSHIM_INSPECT=1`) wraps draws in
occlusion queries and replays them through invisible "twin" pipelines to see where pixels are lost. The near-foliage
color pass uses an `EQUAL` depth test against a depth pre-pass drawn by a different vertex shader. On Metal the two
depths do not match bit for bit, so `EQUAL` rejects the pixels: 569 of 2,521 measured draws produce pixels that the
depth test then throws away. Environment and character skin pipelines show the same pattern. Turning every `EQUAL`
into `GREATER_EQUAL` + bias breaks the full-screen passes that use `EQUAL` to sort pixels (grey blocks), so the
fix has to target only the affected pipelines. Next step: measure which correction restores which pixels.

**Crashes under investigation.** A crash in Apple's AGX driver (libdispatch voucher read through `gs:[0xe0]`)
while the map loads, seen so far only with the inspector on. Two threads using one freed `XAsyncBlock`
(`xgameruntime`), now completed after the call returns, as Windows does. Crashes in the game's network session
code during online play.

## Roadmap

1. Frame pacing: find what the game does during a freeze (`tools/mac_sample_hitch.sh`), fix it in the
   compatibility layer.
2. Black foliage: a per-pipeline depth fix, chosen from measurements.
3. Crashes: map loading, online sessions.
4. ~~A prebuilt engine without CrossOver~~: done, **Blackwell Engine** ([`engine/`](engine/README.md)).
5. The **MetalHorizon app** installs everything by itself (done); next, signed and notarized.
6. Other Xbox-edition games people ask for (Forza Horizon 5 and 4).

## Support the project

Every build is free and public, the same day, for everyone. Sponsors fund the work, not access.
Your support pays for an Apple Developer account (so macOS opens the app without warnings) and support its development, 
plus the time spent fixing stutter and graphics bugs. Thank you!
**[☕ Support it on Buy Me a Coffee](https://buymeacoffee.com/zaidalexandre)** (also the app's Support Me button); details in
[SPONSORS.md](SPONSORS.md).

## Docs

- [`docs/PASSATION-IA.md`](docs/PASSATION-IA.md): full history, evidence, tools, open questions (French)
- [`docs/ANALYSE-FH6-STORE-MACOS.md`](docs/ANALYSE-FH6-STORE-MACOS.md): technical analysis of the Store edition (French)
- [`docs/DEVELOPPEMENT.md`](docs/DEVELOPPEMENT.md): developer notes and test commands (French)

On the author's setup, playing is one line: `bash tools/jouer.sh`.

## Credits

- [Highball](https://github.com/gauthierpiarrette/highball) and
  [highball-engine](https://github.com/gauthierpiarrette/highball-engine), by Gauthier Piarrette (GPL-3.0):
  the DirectX 12 shim, Wine patches 0017–0025, the Forza recipe.
- [Ferestre](https://github.com/icex/ferestre), by icex: Wine patches for the Xbox edition.
- [xodus](https://github.com/xodus-gaming/xodus) (GPL-3.0): MSIXVC packages and Xbox sign-in.
- Wine, and CodeWeavers for the CrossOver sources (LGPL-2.1-or-later).
- Apple's D3DMetal (Game Porting Toolkit).

## License

GPL-3.0: this repository includes GPL-3.0 code from Highball and patches to xodus. The patches to Wine follow
Wine's license, LGPL-2.1-or-later.
