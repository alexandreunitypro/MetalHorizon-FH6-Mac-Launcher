# The two Steam-variant patches, from Highball (LGPL-2.1-or-later)

`0010-kernelbase-per-exe-command-line-append.patch` and `0011-winemac-cross-process-child-swapchains.patch` are
copied verbatim from `https://github.com/gauthierpiarrette/highball-engine/tree/main/patches`
(`0006-kernelbase-per-exe-command-line-append.patch` and `0007-winemac-cross-process-child-swapchains.patch`
there), by Gauthier Piarrette. That repository's patches are **LGPL-2.1-or-later**
(`https://github.com/gauthierpiarrette/highball-engine/blob/main/LICENSE`); these two files keep that license.

What they fix (Highball's own patch headers have the full detail): a launcher's own window — its sign-in page,
and the main window itself — can stay black under Wine's macOS driver when a child window's Direct3D/Metal swap
chain belongs to another process (Wine bug 60263). Steam, Rockstar Games Launcher and Ubisoft Connect all hit
this. `0010` additionally lets a per-exe command line be appended from the registry, for a launcher's own
browser process that never forwards switches to its children.

Only used in the **Steam variant** of Blackwell Engine (`engine/series-steam`), not the default one the Xbox /
Microsoft Store edition uses: verified (2026-10-31) to apply with no conflict on top of this engine's own 9
patches, but not verified in-game, since this project has no Steam copy of Forza Horizon 6 to test with.
