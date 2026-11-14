#!/bin/bash
# MetalHorizon's Play button for the Xbox / Microsoft Store edition: starts Forza Horizon 6 on Blackwell Engine, with
# no CrossOver.app. Shared settings (GPU identity, msync, Highball's DirectX 12 shim, D3DMetal 4, options) live in
# metalhorizon-common.sh. Besides its variables:
#   MH_GAME           the game folder: a real folder (xodus resolves symlinks) with a short path
#   MH_XODUS_CLI, MH_XODUS_SERVICE   the xodus binaries bundled in the app
#   MH_LOGS           folder for the xodus-service log (default ~/Library/Logs/MetalHorizon)
#   MH_GAME_LOG       file for the game's own output (default <MH_LOGS>/game.log); the app gives each run its own
#   MH_PREFIX         another Wine prefix (tests); default <game>/.blackwell-wine, else <game>/.metalhorizon-wine
set -u
. "$(dirname "$0")/metalhorizon-common.sh"
ROUTE="${MH_ROUTE:-d3dmetal}"
if [ "$ROUTE" = native ]; then
    ENGINE="${MH_NATIVE:?}/engine"; D3DM=""; SHIM=""
else
    ENGINE="${MH_ENGINE:?}"; D3DM="${MH_D3DMETAL:?}"; SHIM="${MH_SHIM:?}"
fi
SOURCE="${MH_GAME:?}"
XCLI="${MH_XODUS_CLI:?}"; XSERVICE="${MH_XODUS_SERVICE:?}"
LOGS="${MH_LOGS:-$HOME/Library/Logs/MetalHorizon}"
GAME_LOG="${MH_GAME_LOG:-$LOGS/game.log}"

if [ "$ROUTE" = native ]; then
    [ -e "$ENGINE/bin/wine" ] || mh_fail "the native engine's loader is not linked ($ENGINE/bin/wine): MetalHorizon repairs it before Play"
    [ -x "$ENGINE/bin/wine" ] || mh_fail "the native engine's signed loader is missing (WineLoader.app)"
fi
[ -x "$ENGINE/bin/wine" ] || mh_fail "Blackwell Engine is not installed ($ENGINE)"
[ -f "$ENGINE/lib/libgnutls.30.dylib" ] || mh_fail "this engine has no GnuTLS of its own ($ENGINE/lib)"
[ -e "$SOURCE" ] || mh_fail "the game folder is not there any more: $SOURCE (moved or renamed: MetalHorizon looks for it by itself)"
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || mh_fail "the game folder must be a real folder, not a link: $SOURCE"
if [ -L "$SOURCE/forzahorizon6.exe" ] && [ ! -e "$SOURCE/forzahorizon6.exe" ]; then
    mh_fail "forzahorizon6.exe in $SOURCE is a link to $(readlink "$SOURCE/forzahorizon6.exe"), which is gone: choose the folder the game is really in"
fi
[ -e "$SOURCE/forzahorizon6.exe" ] || mh_fail "no forzahorizon6.exe in $SOURCE: download the game first"
# xodus reads the game from its package; the files beside it are not enough (a game folder moved without it fails
# with a bare "No such file or directory" panic in xodus-cli)
[ -e "$SOURCE/.xodus-streaming.msixvc" ] || mh_fail "the game's package .xodus-streaming.msixvc is not in $SOURCE: it was not moved with the game files. Move it into this folder, or Download the Game again"
PREFIX="$SOURCE/.blackwell-wine"                    # the prefix the working setup already has
[ -d "$PREFIX" ] || PREFIX="$SOURCE/.metalhorizon-wine"
[ "$ROUTE" = native ] && PREFIX="$SOURCE/.metalhorizon-native"   # the native engine's own prefix
PREFIX="${MH_PREFIX:-$PREFIX}"                      # tests: another prefix

if [ "$ROUTE" = native ]; then
    mh_native_engine_env
    export WINEPREFIX="$PREFIX"
    mh_native_game_env
else
    mh_engine_env
    export WINEPREFIX="$PREFIX"
    mh_game_env
fi
export MH_ROUTE="$ROUTE"
export XODUS_RUNTIME_DIR=/private/tmp/xodus-runtime-test

if [ -n "${MH_DRY_RUN:-}" ]; then
    # bash's own list: /usr/bin/env is protected by SIP and would not show the DYLD_ variables
    export -p | sed -n 's/^declare -x //p' | grep -E '^(CX_|WINE|D3DM_|MTL_|HB_|XODUS_|DYLD_|MVK_|VKD3D_|DXVK_|VK_|FEX_|MESA_|GST_|MH_ROUTE)' | sort
    echo "run: $XCLI run $SOURCE $ENGINE/bin/wine --exe forzahorizon6.exe"
    exit 0
fi

echo "== MetalHorizon Play, Xbox edition, $(date '+%Y-%m-%d %H:%M:%S')$([ "$ROUTE" = native ] && echo ', native Apple silicon engine')"
echo "  engine: $("$ENGINE/bin/wine" --version 2>/dev/null) ($(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ENGINE/metalhorizon.json" 2>/dev/null | head -1))"
if [ "$ROUTE" = native ]; then
    echo "  renderer: vkd3d-proton on KosmicKrisp (Metal 4), FEX for x86-64 ($(cat "$MH_NATIVE/VERSION" 2>/dev/null || echo '?'))"
else
    echo "  D3DMetal: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$D3DM/external/D3DMetal.framework/Versions/A/Resources/Info.plist" 2>/dev/null)"
fi
echo "  macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
mh_print_env

pkill -f xodus-cli 2>/dev/null; sleep 1            # left over from an earlier launch
mkdir -p "$PREFIX/drive_c/highball/logs" "$LOGS" "$(dirname "$GAME_LOG")" 2>/dev/null
: > "$GAME_LOG"
# xodus-service holds the Microsoft account and answers the game's Xbox token requests; without it the game
# says "Cloud save synchronization failed". `xodus-cli run` does not start it.
RT="$XODUS_RUNTIME_DIR"
# A service left running by an older MetalHorizon keeps its bugs (the 400 on Xbox user tokens before 1.0.2), and one
# whose log already shows that refusal keeps the refused ticket: either is replaced by a fresh one from this app.
if pgrep -qf xodus-service && ! pgrep -qf 'forzahorizon6\.exe'; then
    if [ "$XSERVICE" -nt "$RT/xodus.sock" ] || grep -q "Failed to authenticate Xbox user" "$LOGS/xodus-service.log" 2>/dev/null; then
        echo "restarting the Xbox service (an older one, or one Xbox had refused, was still running)"
        pkill -f xodus-service 2>/dev/null; sleep 1; rm -f "$RT/xodus.sock"
    fi
fi
if [ -S "$RT/xodus.sock" ] && pgrep -qf xodus-service; then
    echo "xodus-service already running"
else
    mkdir -p "$RT" && chmod 700 "$RT"; rm -f "$RT/xodus.sock"
    echo "starting xodus-service (if macOS asks to let it use the 'Xodus Service' Keychain item, choose Always Allow)"
    ( cd /tmp && XODUS_RUNTIME_DIR="$RT" XODUS_LOG=info nohup "$XSERVICE" > "$LOGS/xodus-service.log" 2>&1 & )
    # The service reads the sign-in from the Keychain before it opens its socket. After an update its program is new
    # to the Keychain, and macOS asks ("xodus-service wants to use your confidential information stored in Xodus
    # Service"), sometimes behind other windows: the service waits on that answer, so Play does too (up to 10 minutes)
    # and says so, instead of starting a game that would have no Xbox account (Initialization Failed).
    waited=0; said=0
    until [ -S "$RT/xodus.sock" ]; do
        sleep 1; waited=$((waited + 1))
        pgrep -qf xodus-service || break
        if pgrep -qx SecurityAgent; then
            [ $said = 0 ] && [ $waited -ge 4 ] && { echo "NOTE: macOS is asking to let xodus-service use your Xbox sign-in (a Keychain window, maybe behind this one): choose Always Allow, for each window it shows. The game starts right after."; said=1; }
            [ $waited -ge 600 ] && break
        else
            [ $waited -ge 60 ] && break
        fi
    done
    if [ ! -S "$RT/xodus.sock" ]; then
        echo "The Xbox service's last lines:"
        tail -15 "$LOGS/xodus-service.log" 2>/dev/null | sed 's/^/  | /'
        pkill -f xodus-service 2>/dev/null
        mh_fail "the Xbox service (xodus-service) did not start, so the game would have no Xbox account. If macOS showed a Keychain window, press Play again and choose Always Allow; otherwise Sign In Again in Settings › General"
    fi
fi
"$ENGINE/bin/wineserver" -k 2>/dev/null || true
if [ "$ROUTE" = native ] && [ ! -f "$PREFIX/system.reg" ]; then
    echo "== first start on the native engine: setting up its prefix (about a minute); the game's first start then spends about 10 minutes on Optimizing for your PC"
    "$ENGINE/bin/wine" wineboot -i >> "$GAME_LOG" 2>&1 || echo "WARN: wineboot did not finish cleanly"
    "$ENGINE/bin/wineserver" -w 2>/dev/null || true
fi
mh_crash_to_log
[ "$ROUTE" = native ] && mh_native_first_settings
cd "$SOURCE" || exit 1
echo "== game started. Quit it from its menu, then wait about 30 s (the cloud save uploads)."
mh_keychain_watch "$GAME_LOG" &
KEYCHAIN_WATCH=$!
mh_run_game "$GAME_LOG" "$XCLI" run "$SOURCE" "$ENGINE/bin/wine" --exe forzahorizon6.exe
CODE=$?
kill "$KEYCHAIN_WATCH" 2>/dev/null; wait "$KEYCHAIN_WATCH" 2>/dev/null
"$ENGINE/bin/wineserver" -k 2>/dev/null || true
echo "== game closed (exit $CODE)"
mh_tail_errors "$GAME_LOG"
exit "$CODE"
