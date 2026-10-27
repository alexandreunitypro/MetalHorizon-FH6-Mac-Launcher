# Forza Horizon 6 Wine patches, from Highball (GPL-3.0)

Copied verbatim from https://github.com/gauthierpiarrette/highball-engine/tree/main/patches
(Gauthier Piarrette, GPL-3.0). These are the three the recipe names as "the ones for Forza":

- `0017` GetIntegratedDisplaySize stub (kernelbase): FH6 calls it once its window is up; without the
  export the loader's unimplemented-function thunk aborts the game.
- `0018` commit charge = phys_footprint (ntdll): FH6 read address space (tens of GB under Rosetta) as
  memory used and warned "87 GB / 32 GB".
- `0019` CredEnumerate empty Keychain is not an error (advapi32): the Xbox Live sign-in was asked for
  on every launch because the saved device key was never found.

Also copied (Forza-relevant, best-effort):
- `0020` winemac retina HORZRES not doubled (fullscreen not cropped on a retina Mac).
- `0022` mmdevapi spatial channel order (7.1/7.1.4).
- `0023` winecoreaudio surround on a 2-channel Mac (off-switch `HB_SPATIAL=0`).
- `0024` kernel32/kernelbase app-package lookups answer from the registry instead of hanging forever.
- `0025` ntdll closing async I/O no longer crashes.

Not copied, and why: 0001/0002/0006/0007/0010/0021 are for other games or launchers; 0003/0005/0008/
0009/0011/0012/0013/0014/0016 edit the same ntdll files as the Ferestre/GLOBALROOT patches this Store
build needs, so they would conflict; 0015 is a CS2 audio tweak. None affects Forza Horizon 6.

They apply on CrossOver 26.3 Wine sources, the same base this engine is built from.
