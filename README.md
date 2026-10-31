# MetalHorizon – FH6 Mac Launcher

**Run your own Xbox / Microsoft Store copy of Forza Horizon 6 on an Apple Silicon Mac AND STEAM!**
Blackwell Engine (Wine) + xodus + Apple's D3DMetal, open source, no CrossOver, no DRM bypass.

## Download

**[MetalHorizon (latest prototype)](../../releases)**: unzip, move **MetalHorizon** to Applications, then
right-click it → **Open** the first time (it is not notarized yet).

The app does the rest by itself: it installs [Blackwell Engine](https://github.com/alexandreunitypro/blackwell-engine)
and Apple's D3DMetal (after you accept Apple's licence), you sign in with your Microsoft account on Microsoft's own
page, click **Download from Xbox**, then **Play**. No CrossOver, nothing to download by hand.

> **Prototype.** Tested on one Mac so far (M5 Pro, macOS 27). Known: stutter, black near foliage. Built and
> tested for the **Xbox / Microsoft Store** edition (MSIXVC). The **Steam edition has been released**, but
> **MetalHorizon Steam support is experimental**: point the game folder at your Steam install and MetalHorizon
> installs a second engine (two of
> [Highball](https://github.com/gauthierpiarrette/highball-engine)'s own patches, see
> [`engine/README.md`](engine/README.md#variante-steam-expérimentale)) and launches through Steam itself. This
> project has no Steam copy to test with — please report back if you try it.

