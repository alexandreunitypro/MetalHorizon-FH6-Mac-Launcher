#!/bin/bash
# MetalHorizon's Play button: starts Forza Horizon 6 on Blackwell Engine, with no CrossOver.app. Same settings as
# tools/jouer.sh (GPU identity, msync, Highball's DirectX 12 shim, D3DMetal 4), no log and no trace.
# The app passes the folders:
#   MH_ENGINE         Blackwell Engine (bin/wine; lib/ holds its own GnuTLS, FreeType and MoltenVK)
#   MH_D3DMETAL       Apple's D3DMetal: the Game Porting Toolkit's redist/lib (external/ and wine/)
#   MH_SHIM           the DirectX 12 shim the app assembles (x86_64-windows/d3d12.dll + apd12.dll, x86_64-unix/apd12.so)
#   MH_GAME           the game folder: a real folder (xodus resolves symlinks) with a short path
#   MH_XODUS_CLI, MH_XODUS_SERVICE   the xodus binaries bundled in the app
#   MH_HUD=0          Apple's Metal HUD off (on by default, as in jouer.sh)
#   MH_LOGS           folder for the xodus-service log (default ~/Library/Logs/MetalHorizon)
#   MH_DRY_RUN=1      print the environment and the command, start nothing
#   MH_WINEDEBUG, MH_GAME_LOG   Wine channels and a file for the game's output (debug runs)
#   MH_PREFIX         another Wine prefix (tests); default <game>/.blackwell-wine, else <game>/.metalhorizon-wine
set -u
ENGINE="${MH_ENGINE:?}"; D3DM="${MH_D3DMETAL:?}"; SHIM="${MH_SHIM:?}"; SOURCE="${MH_GAME:?}"
XCLI="${MH_XODUS_CLI:?}"; XSERVICE="${MH_XODUS_SERVICE:?}"
LOGS="${MH_LOGS:-$HOME/Library/Logs/MetalHorizon}"
fail() { echo "STOP: $1"; exit 1; }

[ -x "$ENGINE/bin/wine" ] || fail "Blackwell Engine is not installed ($ENGINE)"
[ -f "$ENGINE/lib/libgnutls.30.dylib" ] || fail "this engine has no GnuTLS of its own ($ENGINE/lib)"
[ -f "$D3DM/external/libd3dshared.dylib" ] && [ -d "$D3DM/wine" ] || fail "D3DMetal 4 is not installed ($D3DM)"
[ -f "$SHIM/x86_64-windows/apd12.dll" ] && [ -e "$SHIM/x86_64-unix/apd12.so" ] || fail "the DirectX 12 shim is not ready ($SHIM)"
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || fail "the game folder must be a real folder, not a link: $SOURCE"
[ -e "$SOURCE/forzahorizon6.exe" ] || fail "no forzahorizon6.exe in $SOURCE: download the game first"
PREFIX="$SOURCE/.blackwell-wine"                    # the prefix the working setup already has
[ -d "$PREFIX" ] || PREFIX="$SOURCE/.metalhorizon-wine"
PREFIX="${MH_PREFIX:-$PREFIX}"                      # tests: another prefix

export CX_ROOT="$ENGINE" CX_GRAPHICS_BACKEND=d3dmetal WINEPREFIX="$PREFIX" D3DM_MTL4=1
[ "${MH_HUD:-1}" != "0" ] && export MTL_HUD_ENABLED=1
# GPU reported to the game (Highball's recipe): D3DMetal says AMD by default and FH6 then crashes (FHE21).
export D3DM_VENDOR_ID=4318 D3DM_DEVICE_ID=10118 D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 4070"
export WINEMSYNC=1
export WINEDLLOVERRIDES="concrt140,msvcp140,msvcp140_atomic_wait,vcruntime140,vcruntime140_1=n,b"
export XODUS_RUNTIME_DIR=/private/tmp/xodus-runtime-test
# Apple's d3d12, dxgi and d3d12core halves behind Highball's shim (it clears FH205/FH206); all of Apple's .so files
# are one library, libd3dshared.dylib. The engine's lib/ comes first: its GnuTLS, FreeType and MoltenVK.
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$D3DM/external/libd3dshared.dylib"
export DYLD_LIBRARY_PATH="$ENGINE/lib:$D3DM/external" DYLD_FRAMEWORK_PATH="$D3DM/external"
export WINEDLLPATH_PREPEND="$SHIM:$D3DM/wine" HB_D3D12_REAL="Z:$SHIM/x86_64-windows/apd12.dll"
[ -d "$PREFIX/drive_c/highball/replace/fix" ] && export HB_TSSHIM_REPLACE=fix
export WINEDEBUG="${MH_WINEDEBUG:--all}"     # MH_WINEDEBUG: Wine channels for a debug run

if [ -n "${MH_DRY_RUN:-}" ]; then
    # bash's own list: /usr/bin/env is protected by SIP and would not show the DYLD_ variables
    export -p | sed -n 's/^declare -x //p' | grep -E '^(CX_|WINE|D3DM_|MTL_|HB_|XODUS_|DYLD_)' | sort
    echo "run: $XCLI run $SOURCE $ENGINE/bin/wine --exe forzahorizon6.exe"
    exit 0
fi

pkill -f xodus-cli 2>/dev/null; sleep 1            # left over from an earlier launch
mkdir -p "$PREFIX/drive_c/highball/logs" "$LOGS" 2>/dev/null
# xodus-service holds the Microsoft account and answers the game's Xbox token requests; without it the game
# says "Cloud save synchronization failed". `xodus-cli run` does not start it.
RT="$XODUS_RUNTIME_DIR"
if [ -S "$RT/xodus.sock" ] && pgrep -qf xodus-service; then
    echo "xodus-service already running"
else
    mkdir -p "$RT" && chmod 700 "$RT"; rm -f "$RT/xodus.sock"
    echo "starting xodus-service (if macOS asks to let it use the 'Xodus Service' Keychain item, choose Always Allow)"
    ( cd /tmp && XODUS_RUNTIME_DIR="$RT" XODUS_LOG=info nohup "$XSERVICE" > "$LOGS/xodus-service.log" 2>&1 & )
    for _ in $(seq 60); do [ -S "$RT/xodus.sock" ] && break; sleep 1; done
    [ -S "$RT/xodus.sock" ] || echo "WARN: xodus-service did not start; no Xbox sign-in"
fi
"$ENGINE/bin/wineserver" -k 2>/dev/null || true
cd "$SOURCE" || exit 1
echo "== game started. Quit it from its menu, then wait about 30 s (the cloud save uploads)."
"$XCLI" run "$SOURCE" "$ENGINE/bin/wine" --exe forzahorizon6.exe > "${MH_GAME_LOG:-/dev/null}" 2>&1
"$ENGINE/bin/wineserver" -k 2>/dev/null || true
echo "== game closed"
