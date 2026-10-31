#!/bin/bash
# MetalHorizon's Play button for the Steam edition (experimental: this project has no Steam copy of Forza
# Horizon 6 to test with). Same D3DMetal 4 and DirectX 12 shim settings as the Xbox edition
# (metalhorizon-play.sh), on the Steam-variant engine, with no xodus: Steam handles its own sign-in and
# download. Launches through Steam itself (`steam.exe -applaunch <appid>`), which starts Steam if it is not
# running yet — Highball found Forza Horizon 6 on Steam closes itself after about 12 seconds without the
# Steam client running in the same Wine prefix.
#   MH_ENGINE          Blackwell Engine, Steam variant (bin/wine; lib/ holds its own GnuTLS, FreeType, MoltenVK)
#   MH_D3DMETAL        Apple's D3DMetal: the Game Porting Toolkit's redist/lib (external/ and wine/)
#   MH_SHIM            the DirectX 12 shim the app assembles
#   MH_GAME            the Steam install folder (steamapps/common/Forza Horizon 6), for steam_appid.txt
#   MH_PREFIX          the Steam-only prefix (<game>/.blackwell-wine-steam); Steam itself lives inside it
#   MH_STEAM_APPID     read from MH_GAME/steam_appid.txt by the app; passed through for MH_DRY_RUN
#   MH_HUD=0           Apple's Metal HUD off (on by default)
#   MH_DRY_RUN=1       print the environment and the command, start nothing
#   MH_WINEDEBUG, MH_GAME_LOG   Wine channels and a file for the game's output (debug runs)
set -u
ENGINE="${MH_ENGINE:?}"; D3DM="${MH_D3DMETAL:?}"; SHIM="${MH_SHIM:?}"; SOURCE="${MH_GAME:?}"; PREFIX="${MH_PREFIX:?}"
fail() { echo "STOP: $1"; exit 1; }

[ -x "$ENGINE/bin/wine" ] || fail "Blackwell Engine (Steam variant) is not installed ($ENGINE)"
[ -f "$ENGINE/lib/libgnutls.30.dylib" ] || fail "this engine has no GnuTLS of its own ($ENGINE/lib)"
[ -f "$D3DM/external/libd3dshared.dylib" ] && [ -d "$D3DM/wine" ] || fail "D3DMetal 4 is not installed ($D3DM)"
[ -f "$SHIM/x86_64-windows/apd12.dll" ] && [ -e "$SHIM/x86_64-unix/apd12.so" ] || fail "the DirectX 12 shim is not ready ($SHIM)"
[ -e "$SOURCE/forzahorizon6.exe" ] || fail "no forzahorizon6.exe in $SOURCE"
APPID="${MH_STEAM_APPID:-}"
[ -n "$APPID" ] || APPID="$(tr -d '[:space:]' < "$SOURCE/steam_appid.txt" 2>/dev/null)"
[ -n "$APPID" ] || fail "no steam_appid.txt in $SOURCE: this does not look like a Steam install"
STEAM_EXE="$PREFIX/drive_c/Program Files (x86)/Steam/Steam.exe"
[ -e "$STEAM_EXE" ] || fail "Steam is not installed in this prefix yet ($PREFIX): use Install Steam first"

export CX_ROOT="$ENGINE" CX_GRAPHICS_BACKEND=d3dmetal WINEPREFIX="$PREFIX" D3DM_MTL4=1
[ "${MH_HUD:-1}" != "0" ] && export MTL_HUD_ENABLED=1
export D3DM_VENDOR_ID=4318 D3DM_DEVICE_ID=10118 D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 4070"
export WINEMSYNC=1
export WINEDLLOVERRIDES="concrt140,msvcp140,msvcp140_atomic_wait,vcruntime140,vcruntime140_1=n,b"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$D3DM/external/libd3dshared.dylib"
export DYLD_LIBRARY_PATH="$ENGINE/lib:$D3DM/external" DYLD_FRAMEWORK_PATH="$D3DM/external"
export WINEDLLPATH_PREPEND="$SHIM:$D3DM/wine" HB_D3D12_REAL="Z:$SHIM/x86_64-windows/apd12.dll"
[ -d "$PREFIX/drive_c/highball/replace/fix" ] && export HB_TSSHIM_REPLACE=fix
export WINEDEBUG="${MH_WINEDEBUG:--all}"

if [ -n "${MH_DRY_RUN:-}" ]; then
    export -p | sed -n 's/^declare -x //p' | grep -E '^(CX_|WINE|D3DM_|MTL_|HB_|DYLD_)' | sort
    echo "run: $ENGINE/bin/wine 'C:\\Program Files (x86)\\Steam\\Steam.exe' -applaunch $APPID"
    exit 0
fi

"$ENGINE/bin/wineserver" -k 2>/dev/null || true
cd "$SOURCE" || exit 1
echo "== launching through Steam (appid $APPID). Steam starts itself if needed; sign in there the first time."
"$ENGINE/bin/wine" "C:\\Program Files (x86)\\Steam\\Steam.exe" -applaunch "$APPID" > "${MH_GAME_LOG:-/dev/null}" 2>&1
"$ENGINE/bin/wineserver" -k 2>/dev/null || true
echo "== closed"
