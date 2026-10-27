# MetalHorizon app

The macOS launcher: sign in with your Microsoft account, download Forza Horizon 6 (Xbox / Microsoft Store edition)
from the official Xbox servers, press Play. SwiftUI, macOS 14+, Apple silicon. GPL-3.0, like the rest of the repository.

## What it does

| Button | What runs |
|---|---|
| **Sign in with Microsoft** | `xodus-cli login` inside the bundled *Xodus Login.app*, on Microsoft's own page. The session goes to the macOS Keychain (`Xodus Service` items); the app never sees the password. |
| **Download from Xbox** | `xodus-cli streaming 9nr1r1xwlcnb <game folder>`. xodus only gets a licence, and so the files, for a game your account owns. |
| **Play** | [`Resources/metalhorizon-play.sh`](Resources/metalhorizon-play.sh): exactly what `tools/jouer.sh` does (same environment, same command, checked with `MH_DRY_RUN=1`), with the folders chosen in the app. It starts `xodus-service` if it is not running. |

Logs: `~/Library/Logs/MetalHorizon/` (button *Show Logs in Finder*).

## AI assistant (MCP)

The same binary is an [MCP](https://modelcontextprotocol.io) server when started with `--mcp` (stdio). An assistant such
as Claude can then check the setup, read the logs, explain errors and change MetalHorizon's settings with the user.
*AI Assistant…* in the app shows the lines to copy:

```sh
claude mcp add metalhorizon -- "/Applications/MetalHorizon.app/Contents/MacOS/MetalHorizon" --mcp
```

Claude Desktop (*Settings › Developer › Edit Config*):

```json
{ "mcpServers": { "metalhorizon": { "command": "/Applications/MetalHorizon.app/Contents/MacOS/MetalHorizon", "args": ["--mcp"] } } }
```

| Tool | What it does |
|---|---|
| `check_setup` | Every item Play needs (game folder, Blackwell Engine, D3DMetal 4, DirectX 12 shim, Xbox account, xodus-service, Rosetta, macOS, memory, disk) with a fix for each problem |
| `get_troubleshooting_guide` | Known messages (FH205, FHE21, "Installation path is too long", "Cloud save synchronization failed"…) and their fixes |
| `list_logs`, `read_log` | MetalHorizon's logs and the crash reports of Wine, the game and xodus; crash reports are summarized |
| `show_play_environment` | What Play would run, in dry-run mode |
| `find_engines`, `find_d3dmetal` | Engines and D3DMetal copies on this Mac, and which ones fit |
| `set_setting` | Changes a folder or the HUD setting after checking it (the app must be reopened to show it) |
| `xodus_service` | Status, start or stop of the Xbox sign-in helper |

Prompts: `diagnose` and `setup_assistant`. The server sends the assistant its instructions at connection: start with
`check_setup`, answer in the user's language one step at a time, ask before changing a setting.

What it never does: read the Keychain secrets (only checks that the Xbox session exists), show tokens (logs come with
tokens, e-mail addresses, XUIDs and gamertags removed), start the game or a download, or help with the game's protection.

## What it installs by itself

Everything goes into `~/Library/Application Support/MetalHorizon/`, from the GitHub release listed in
[`components.json`](components.json) (SHA-256 checked):

- **Blackwell Engine**: the Wine engine from [`engine/`](../engine/README.md), with its own GnuTLS, FreeType and MoltenVK.
- **D3DMetal 4**: Apple's Game Porting Toolkit `redist/lib`, unmodified. The app shows Apple's licence first and
  installs nothing if it is declined.
- **The DirectX 12 shim**: Highball's shim (in the engine) in front of a copy of Apple's `d3d12.dll` whose export name
  the app changes to `apd12.dll` on this Mac, as Highball does ([`PEFile.swift`](Sources/MetalHorizon/PEFile.swift)).

No CrossOver.app. The game itself still comes from **Download from Xbox**. A game folder with a short path, such as
`~/FH6`, that is a real folder (not a link) and is not in iCloud Drive.

`MH_COMPONENTS_DIR=<folder>` makes the app take the tarballs from a local folder instead of GitHub (tests, offline).

## Build

```sh
bash app/build-app.sh 0.1.0
```

`app/update-components.sh` first writes `components.json` from the release's tarballs. Output in `app/dist/`:
`MetalHorizon.app`, `MetalHorizon-<version>.zip`, `xodus-source-0.1.0.tar.gz` (the GPL-3.0 source of the
two bundled xodus binaries) and `SHA256SUMS`. The script stops if a D3DMetal, d3d12 or CrossOver file ends up in the app.
The app is signed ad hoc, not notarized: macOS asks for confirmation the first time.

`MH_SNAPSHOT=<file.png> app/dist/MetalHorizon.app/Contents/MacOS/MetalHorizon` draws the window into an image and quits
(`MH_SNAPSHOT_SHEET=1` for the AI assistant sheet).
