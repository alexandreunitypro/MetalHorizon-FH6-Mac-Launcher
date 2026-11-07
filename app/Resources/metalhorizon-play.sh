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
ENGINE="${MH_ENGINE:?}"; D3DM="${MH_D3DMETAL:?}"; SHIM="${MH_SHIM:?}"; SOURCE="${MH_GAME:?}"
XCLI="${MH_XODUS_CLI:?}"; XSERVICE="${MH_XODUS_SERVICE:?}"
LOGS="${MH_LOGS:-$HOME/Library/Logs/MetalHorizon}"
GAME_LOG="${MH_GAME_LOG:-$LOGS/game.log}"

[ -x "$ENGINE/bin/wine" ] || mh_fail "Blackwell Engine is not installed ($ENGINE)"
[ -f "$ENGINE/lib/libgnutls.30.dylib" ] || mh_fail "this engine has no GnuTLS of its own ($ENGINE/lib)"
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
PREFIX="${MH_PREFIX:-$PREFIX}"                      # tests: another prefix

mh_engine_env
export WINEPREFIX="$PREFIX"
mh_game_env
export XODUS_RUNTIME_DIR=/private/tmp/xodus-runtime-test

if [ -n "${MH_DRY_RUN:-}" ]; then
    # bash's own list: /usr/bin/env is protected by SIP and would not show the DYLD_ variables
    export -p | sed -n 's/^declare -x //p' | grep -E '^(CX_|WINE|D3DM_|MTL_|HB_|XODUS_|DYLD_|MVK_)' | sort
    echo "run: $XCLI run $SOURCE $ENGINE/bin/wine --exe forzahorizon6.exe"
    exit 0
fi

echo "== MetalHorizon Play, Xbox edition, $(date '+%Y-%m-%d %H:%M:%S')"
echo "  engine: $("$ENGINE/bin/wine" --version 2>/dev/null) ($(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ENGINE/metalhorizon.json" 2>/dev/null | head -1))"
echo "  D3DMetal: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$D3DM/external/D3DMetal.framework/Versions/A/Resources/Info.plist" 2>/dev/null)"
echo "  macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
mh_print_env

pkill -f xodus-cli 2>/dev/null; sleep 1            # left over from an earlier launch
mkdir -p "$PREFIX/drive_c/highball/logs" "$LOGS" "$(dirname "$GAME_LOG")" 2>/dev/null
: > "$GAME_LOG"
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
    if [ ! -S "$RT/xodus.sock" ]; then
        echo "WARN: xodus-service did not start; no Xbox sign-in. Its last lines:"
        tail -15 "$LOGS/xodus-service.log" 2>/dev/null | sed 's/^/  | /'
        pgrep -qf xodus-service || echo "  (it is not running: macOS may have blocked it, see Diagnosis)"
    fi
fi
"$ENGINE/bin/wineserver" -k 2>/dev/null || true
mh_crash_to_log
cd "$SOURCE" || exit 1
echo "== game started. Quit it from its menu, then wait about 30 s (the cloud save uploads)."
mh_run_game "$GAME_LOG" "$XCLI" run "$SOURCE" "$ENGINE/bin/wine" --exe forzahorizon6.exe
CODE=$?
"$ENGINE/bin/wineserver" -k 2>/dev/null || true
echo "== game closed (exit $CODE)"
mh_tail_errors "$GAME_LOG"
exit "$CODE"
