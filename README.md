# MetalHorizon X
<img width="4260" height="2840" alt="MacBook Pro with PROLED XDR Display 16-inch Space Black" src="https://github.com/user-attachments/assets/3a770d2c-3601-4eaf-a319-4cc32c3b3553" />
**The most complete way to play Forza Horizon 6 on a Mac: your own copy from the Xbox / Microsoft Store, PC Game
Pass or Steam, on Apple silicon. One app, one button, 60 frames a second on an M5 Pro.**

**[⬇ Download the latest version](../../releases/latest)** · **[☕ Support it on Buy Me a Coffee](https://buymeacoffee.com/zaidalexandre)** · **[Report a problem](../../issues)**

I am committed to patching as many bugs as possible and resolving as many issues as I can: report them in
[Issues](../../issues), and I will release a fix within 24 hours between Friday and the whole week ends only otherwise except a fix by Friday.

Forza Horizon 5, 4, 3, 2 and 1 support is coming very soon, and Forza Motorsport (2023) as a world first.

## 60 fps on an M5 Pro

On a MacBook Pro with an **M5 Pro** (48 GB, macOS 27.2.1), the Xbox edition holds its **60 fps** cap on
**Blackwell Engine Native**, online, with other players around: Metal HUD at 60 fps, GPU at 90 %, over a 35-minute
session (22 November 2026, 1920×1080, the Very High preset MetalHorizon starts the game with).

Blackwell Engine Native is the best engine there is to play Forza on a Mac: Wine for arm64 with FEX, vkd3d-proton
and KosmicKrisp on Metal 4, Highball's native route, plus MetalHorizon's Xbox patches. No Rosetta, so none of the
hitch the game's copy protection causes about once a second under Rosetta. MetalHorizon picks it by itself on a Mac
that can run it (Settings › Graphics to choose).

## Why MetalHorizon X

|  | **MetalHorizon X** | Highball | fh6-mac-fix |
|---|---|---|---|
| Xbox / Microsoft Store copy | ✅ | – | – |
| PC Game Pass | ✅ | – | – |
| Steam copy | ✅ | ✅ | ✅ |
| Downloads the game for you | ✅ from Xbox's servers, resumes after a cut | through Steam | through Steam |
| Your add-ons, VIP and Car Pass in the Xbox copy | ✅ | – | – |
| Native engine, no once-a-second hitch | ✅ Xbox copy (Steam copy on Rosetta for now) | ✅ | ✅ |
| Setting up | one button: the app installs the engine, D3DMetal and Steam | an app, with a recipe for the game | a step-by-step guide in the Terminal |

Highball and fh6-mac-fix as their own pages describe them on 22 November 2026: both run the Steam copy of the game.
They are fine projects, and MetalHorizon is built on Highball's work (see [Credits](#credits)).

**What no other Mac route does:**
- **It plays the copy you already own, wherever you bought it.** An Xbox / Microsoft Store copy, a Game Pass plan
  that includes the game, or Steam. A copy already on the Mac or on an external disk is found by itself.
- **It downloads the Xbox copy itself**, from Xbox's servers with your own licence, as the Xbox app does on Windows:
  a real progress bar (percent, GB, speed, time left), a download that survives network cuts and picks up where it
  stopped, the room checked before it starts, the Mac kept awake.
- **Your Xbox account, all of it:** online play, cloud saves, your add-ons, VIP and Car Pass recognised in the game
  (confirmed by a player, issue #18), your own profile picture.

## Everything inside

**Play**
- **Blackwell Engine Native** on Apple silicon (Xbox edition), **Blackwell Engine 1.4** with Apple's D3DMetal under
  Rosetta (both editions). On Rosetta, the **Blackwell Pacer** cuts the freezes every ten seconds or so, and the
  **Trap Boost** shortens the copy protection's hitch. Both tune themselves: there is nothing to set.
- **Frame generation** from [MetalDuck](https://github.com/Lospi/MetalDuck) (Settings › Graphics): 2×, 3× or 4×
  the frames on screen, through Apple's frame interpolation model.
- A frame cap, Apple's Metal HUD, MetalFX upscaling (the game then offers DLSS).
- The game's 7.1.4 surround sound, mixed for the Mac's speakers and headphones by Apple's spatial mixer.

**Controllers**
- Xbox, PlayStation (on Bluetooth too), Switch Pro, 8BitDo and generic pads, through GameInput as on Windows.

**Looks after itself**
- **The Doctor** knows 44 problems (damaged components, the Xbox service, the network and the clock, a moved game
  folder, a full disk, memory, the Wine prefix...), each with treatments tried in order: automatically when it is
  safe, with one click when it touches your files.
- **The Autopilot** checks before every Play, reads every run, relaunches a failed start once, moves the game to the
  other engine after two failures, turns off an option that crashed it, and shows all it did under *Fixed by
  MetalHorizon*. It never touches your saves, your sign-in or the game's files.
- After each run, 42 known errors are recognised and explained with what to do. **Export Diagnostics** writes a zip,
  secrets removed, for an issue.
- **It updates itself:** each time it opens, it installs a newer version once nothing is running, and the engines
  it needs, keeping your settings, sign-in and game.
- An MCP server (Help › Connect an AI Assistant): 30 tools that let an assistant such as Claude diagnose the last
  runs, explain a pasted error, check the network, Steam, the controllers and the components, and change settings
  with your agreement.

**Made for the Mac**
- A black-glass window with one button that always does the next step.
- In your Mac's language: 34 languages, from Arabic to Vietnamese (Settings › General › Language to choose another).

## Get started

**You need**
- An Apple silicon Mac with **macOS 27** or later. From 24 GB of memory MetalHorizon picks Blackwell Engine Native
  by itself; with less, the game plays on the Rosetta engine.
- About **170 GB** free for the Xbox copy (the game takes 161 GB), outside iCloud Drive.
- Your own Forza Horizon 6: Xbox / Microsoft Store on your Microsoft account, a PC Game Pass plan that includes it,
  or Steam.

Nothing else: MetalHorizon downloads Blackwell Engine and Apple's D3DMetal 4 by itself (once you accept Apple's
licence). No CrossOver, nothing to download by hand.

**First start**: unzip, move **MetalHorizon** to Applications, then right-click it › **Open** the first time (it is
not notarized yet). Say which copy you own, then follow the button:
- **Xbox / Microsoft Store or Game Pass**: Install the Engine, Sign In with Microsoft (on Microsoft's own page, with
  a code), Download the Game, **Play**.
- **Steam**: Install the Engine, Install Steam (in its own Wine prefix), Open Steam and sign in; Steam's install
  window for the game opens by itself. Then **Play**: Steam starts the game, as on Windows. The first time, the game
  asks you to sign in to Xbox with a code at microsoft.com/link, and keeps it after that.

## How it works

```
forzahorizon6.exe        Xbox: decrypted in memory by xodus, never written to disk. Steam: started by Steam.
 └─ Blackwell Engine     Wine 11 from CrossOver 26.3's LGPL sources + Ferestre + Highball + MetalHorizon's patches
     ├─ Native           Apple silicon: Wine 11.18 arm64 + FEX, vkd3d-proton on KosmicKrisp (Metal 4)
     ├─ Rosetta          x86-64: Apple's D3DMetal 4 behind Highball's DirectX 12 shim, the Pacer and the Trap Boost
     ├─ xgameruntime     Xbox edition: sign-in, store, cloud saves through xodus-service (the Steam game brings its own)
     ├─ GameInput        controllers as on Windows, from XInput, SDL2 and macOS's own pads
     └─ Core Audio       the game's surround mixed for the Mac's speakers
```

## What it does and does not do

- **The game's files are never modified or redistributed**, and the executable is not patched.
- **The copy protection, the licence check and the anti-cheat are not bypassed.** The game accepts its own licence;
  every fix lives in the compatibility layer.
- [xodus](https://github.com/xodus-gaming/xodus) decrypts the Xbox package with your own account's licence, as the
  Xbox app does on Windows. The files stay encrypted on disk.
- **Your Microsoft password never goes through MetalHorizon.** You sign in on Microsoft's own page; the account is
  kept in the macOS Keychain.
- As in Highball's recipe, the game is shown an NVIDIA GPU (RTX 4070), so its hardware check passes.
- Nothing from CrossOver.app is used. Apple's D3DMetal is downloaded unmodified, only after you accept Apple's licence.

This is unofficial software. Nobody can promise Microsoft will never act on an account used this way, especially
online. Use it at your own risk.

## Known limits

- The app is ad-hoc signed, not notarized yet: macOS asks you to confirm the first launch.
- The Steam edition plays on the Rosetta engine for now, and is tested by players: this project has no Steam copy of
  the game. Please report back.
- Under Rosetta, the copy protection's short hitch about once a second remains, shorter with the Trap Boost; the
  native engine has none.
- Leave the game's ray tracing options off: changing them has crashed it (FHE11).
- Near foliage can look dark on the D3DMetal route: the cause is narrowed down, not fixed yet.
- The detailed messages (diagnostics, repairs, the Doctor) are in English.

## Support the project

Every build is free and public, the same day, for everyone. Your support pays for an Apple Developer account (so
macOS opens the app without warnings) and for the time spent fixing stutter and graphics bugs. Thank you!

**[☕ Support it on Buy Me a Coffee](https://buymeacoffee.com/zaidalexandre)** (also the app's Support Me button);
details in [SPONSORS.md](SPONSORS.md).

## Docs

- [`engine/README.md`](engine/README.md): Blackwell Engine, its patches and how it is built
- [`docs/XODUS-ROBUSTNESS.md`](docs/XODUS-ROBUSTNESS.md): the 50 changes that make the download and the Xbox sign-in sturdy
- [`docs/PASSATION-IA.md`](docs/PASSATION-IA.md): full history, evidence, tools, open questions (French)
- [`docs/ANALYSE-FH6-STORE-MACOS.md`](docs/ANALYSE-FH6-STORE-MACOS.md): technical analysis of the Store edition (French)
- [`docs/DEVELOPPEMENT.md`](docs/DEVELOPPEMENT.md): developer notes and test commands (French)

## Credits

  [highball-engine](https://github.com/gauthierpiarrette/highball-engine), by Gauthier Piarrette (GPL-3.0): the
  DirectX 12 shim, Wine patches, the native route and the Forza recipe.
- [Ferestre](https://github.com/icex/ferestre), by icex: Wine patches for the Xbox edition.
- Highball's Steam method (the window on DXMT with sync off, a silent client for games, a clean shutdown) and their
  [DXMT build](https://github.com/gauthierpiarrette/dxmt); [DXMT](https://github.com/3Shain/dxmt) by 3Shain (MIT).
- [MetalDuck](https://github.com/Lospi/MetalDuck), by Roberto Camargo (GPL-3.0): frame generation. Its window
  capture, its use of Apple's frame interpolation model and its overlay are adapted in
  [`app/Sources/MetalHorizon/FrameGeneration/`](app/Sources/MetalHorizon/FrameGeneration/).
- prsloan's dual-stack socket fix for online play (highball-engine pull request #40).
- [SDL](https://github.com/libsdl-org/SDL) (zlib) for controllers; [mingw-w64](https://www.mingw-w64.org) for the Steam engine.
- [xodus](https://github.com/xodus-gaming/xodus) (GPL-3.0): Xbox packages and sign-in.
- Wine, and CodeWeavers for the CrossOver sources (LGPL-2.1-or-later).
- Apple's D3DMetal (Game Porting Toolkit).

Unofficial. Not affiliated with or endorsed by Microsoft, Xbox, Valve, Playground Games, Apple, CodeWeavers or
NVIDIA. Forza Horizon and Xbox are trademarks of Microsoft.

## License

GPL-3.0: this repository includes GPL-3.0 code from Highball and patches to xodus. The patches to Wine follow
Wine's license, LGPL-2.1-or-later.
