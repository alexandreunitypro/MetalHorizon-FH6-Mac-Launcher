#!/bin/bash
# Opens one of Wine's own tools in the edition's prefix, from MetalHorizon's Tools menu:
#   joycpl    Wine's Game Controllers panel (each pad, its buttons and axes, live): what the game will see
#   winecfg   Wine's configuration
#   bash metalhorizon-tool.sh joycpl|winecfg     (MH_ENGINE, MH_PREFIX and the variables of metalhorizon-common.sh)
# It joins the sync mode of whatever already runs in the prefix: a process started with another mode dies at once.
set -u
. "$(dirname "$0")/metalhorizon-common.sh"
TOOL="${1:-joycpl}"
ENGINE="${MH_ENGINE:?}"; PREFIX="${MH_PREFIX:?}"
[ -x "$ENGINE/bin/wine" ] || mh_fail "Blackwell Engine is not installed ($ENGINE)"
[ -f "$PREFIX/system.reg" ] || mh_fail "no Wine prefix yet in $PREFIX: Play once (Xbox) or Install Steam first"
mh_engine_env
export WINEPREFIX="$PREFIX" WINEMSYNC=0 WINEESYNC=0
REAL="$(cd "$PREFIX" && pwd -P)"
if lsof -a -d cwd -u "$(id -u)" -Fn 2>/dev/null | grep -q "^n$REAL/"; then
    # MetalHorizon starts the game with msync; Steam's window runs without it (metalhorizon-steam.sh writes which)
    if [ "$(cut -d' ' -f2 "$PREFIX/.metalhorizon-steam-mode" 2>/dev/null)" = msync ] || { [ ! -f "$PREFIX/.metalhorizon-steam-mode" ] && pgrep -qf 'forzahorizon6\.exe'; }; then
        export WINEMSYNC=1
    fi
fi
[ "${MH_GAMEINPUT:-0}" = "1" ] && export WINE_GAMEINPUT=1
case "$TOOL" in
    joycpl) exec "$ENGINE/bin/wine" control joy.cpl ;;
    winecfg) exec "$ENGINE/bin/wine" winecfg ;;
    *) mh_fail "unknown tool $TOOL (joycpl, winecfg)" ;;
esac
