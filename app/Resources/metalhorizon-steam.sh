#!/bin/bash
# MetalHorizon and the Steam edition of Forza Horizon 6. One prefix holds Steam and the game, as on Windows: the
# game needs the Steam client running beside it in the same prefix (without it, Highball measured, it closes after
# about 12 s). Highball's recipe, which this follows (gauthierpiarrette/highball, Sources/HighballKit/SteamRestart.swift
# and WineRunner.swift; highball-db recipes/launchers/steam.json):
#   - Steam's own window cannot draw through D3DMetal (it stays black), so it opens with DXMT, and with sync off
#     (its web views hang under msync).
#   - Games run under msync, launched by a silent client: `steam.exe -silent -applaunch <appid>`. A game inherits
#     the client's environment, so a client started for the window is stopped first.
#   - Wine fixes the sync mode when a prefix's wineserver starts, and a process started with another mode dies
#     ("msync_init Failed bootstrap_look_up"): every command joins the running server's mode.
#   - Steam is stopped with its own -shutdown, never with wineserver -k, so it keeps its sign-in and its game.
#   - Background starts use a plain subshell, never nohup: /usr/bin/nohup is protected by SIP, which drops
#     DYLD_LIBRARY_PATH, and the engine then loses its own FreeType (no fonts, then a division by zero in Steam).
#
#   bash metalhorizon-steam.sh prefix|install|open|play|stop|status
# Variables (and the shared ones in metalhorizon-common.sh):
#   MH_ENGINE         Blackwell Engine, Steam variant (32-bit half and renderers/dxmt)
#   MH_PREFIX         the Steam prefix (MetalHorizon's own, ~/Library/Application Support/MetalHorizon/Steam, or a
#                     bottle the player picked, such as a Highball one)
#   MH_D3DMETAL, MH_SHIM   for play
#   MH_STEAM_APPID    default 2483190, Forza Horizon 6
#   MH_LOGS, MH_GAME_LOG   where Steam's output goes (the game's output is Steam's: the game is its child)
#   MH_WAIT_MINUTES   how long play waits for the game to appear (default 30: Steam may update first)
set -u
. "$(dirname "$0")/metalhorizon-common.sh"
ACTION="${1:-status}"
ENGINE="${MH_ENGINE:?}"; PREFIX="${MH_PREFIX:?}"; APPID="${MH_STEAM_APPID:-2483190}"
D3DM="${MH_D3DMETAL:-}"; SHIM="${MH_SHIM:-}"
LOGS="${MH_LOGS:-$HOME/Library/Logs/MetalHorizon}"
GAME_LOG="${MH_GAME_LOG:-$LOGS/steam-client.log}"
STEAM_DIR="$PREFIX/drive_c/Program Files (x86)/Steam"
STEAM_EXE="$STEAM_DIR/steam.exe"
[ -f "$STEAM_EXE" ] || [ ! -f "$STEAM_DIR/Steam.exe" ] || STEAM_EXE="$STEAM_DIR/Steam.exe"   # case-sensitive volumes
STEAM_WIN='C:\Program Files (x86)\Steam\steam.exe'
DXMT="$ENGINE/renderers/dxmt/wine"
SETUP="$HOME/Library/Application Support/MetalHorizon/Downloads/SteamSetup.exe"
# Valve's own hosts for the same installer. cdn.steampowered.com is not among them: on some networks it lands on a
# generic Akamai edge with the wrong certificate and the store's HTML (MetalHorizon issue, macOS 27.2, M4 Pro).
MIRRORS=(
    "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
    "https://media.steampowered.com/client/installer/SteamSetup.exe"
    "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"
    "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe"
)

[ -x "$ENGINE/bin/wine" ] || mh_fail "Blackwell Engine (Steam variant) is not installed ($ENGINE)"
case "$ACTION" in status) ;; *)
    [ -f "$ENGINE/lib/wine/i386-windows/ntdll.dll" ] \
        || mh_fail "this engine has no 32-bit half, and Steam is a 32-bit program: install Blackwell Engine Steam 1.1 or later" ;;
esac
mh_engine_env
export WINEPREFIX="$PREFIX"
mkdir -p "$LOGS" 2>/dev/null

# --- processes of this prefix -------------------------------------------------------------------------------------
# A Wine process works in a folder of its prefix (drive_c/windows, the Steam folder, the game's folder): that is how
# it is told apart, as Highball's ProcessTable does. Its environment cannot be read: Wine writes the Windows command
# line over it. So the mode a client was started in (window or game, and the sync that goes with it) is written down
# when MetalHorizon starts it.
PREFIX_REAL="$(cd "$PREFIX" 2>/dev/null && pwd -P || echo "$PREFIX")"
MARKER="$PREFIX/.metalhorizon-steam-mode"
prefix_pids() {
    lsof -a -d cwd -u "$(id -u)" -Fpn 2>/dev/null | awk -v root="$PREFIX_REAL/" '
        /^p/ { pid = substr($0, 2) }
        /^n/ { if (index(substr($0, 2) "/", root) == 1) print pid }'
}
prefix_processes() {   # pid<TAB>command, for the Wine processes of this prefix
    local pid
    for pid in $(prefix_pids); do printf '%s\t%s\n' "$pid" "$(ps -ww -o command= -p "$pid" 2>/dev/null)"; done
}
client_pids() { prefix_processes | awk -F'\t' 'tolower($2) ~ /(^|[\\\/])steam\.exe/ {print $1}'; }
helper_pids() { prefix_processes | awk -F'\t' 'tolower($2) ~ /(steam\.exe|steamwebhelper|steamservice|steamerrorreporter|gameoverlayui)/ {print $1}'; }
game_pids() { prefix_processes | awk -F'\t' 'tolower($2) ~ /forzahorizon6\.exe/ {print $1}'; }
client_mode() {   # game (msync + D3DMetal: started by play) or window (started by open), empty when none runs
    [ -n "$(client_pids)" ] || return 0
    case "$(cut -d' ' -f1 "$MARKER" 2>/dev/null)" in game|direct) echo game ;; *) echo window ;; esac
}
live_sync() {   # msync or none: the mode of the server running in the prefix; empty when nothing runs
    [ -n "$(prefix_pids)" ] || return 0
    if [ "$(cut -d' ' -f2 "$MARKER" 2>/dev/null)" = msync ]; then echo msync; else echo none; fi
}
mark() { echo "$1 $2" > "$MARKER"; }   # mark <window|game> <msync|none>, when a client is started
# A new process must use the sync mode of the server already running in the prefix, or it dies at start.
join_live_sync() {
    case "$(live_sync)" in
        msync) export WINEMSYNC=1 WINEESYNC=0 ;;
        none) export WINEMSYNC=0 WINEESYNC=0 ;;
    esac
}
# end_leftovers <mode>: programs left in the prefix (no Steam client, no game) with another sync mode than <mode>
# are ended, so the next start is not refused by their server.
end_leftovers() {
    [ -n "$(prefix_pids)" ] && [ -z "$(client_pids)" ] && [ -z "$(game_pids)" ] || return 0
    [ "$(live_sync)" = "$1" ] && return 0
    echo "  ending programs left in the Steam prefix with another sync mode"
    "$ENGINE/bin/wineserver" -k 2>/dev/null; sleep 1
}
window_env() {   # Steam's window: DXMT, sync off, no D3DMetal
    export WINEMSYNC=0 WINEESYNC=0
    unset CX_GRAPHICS_BACKEND D3DM_MTL4 MTL_HUD_ENABLED
    if [ -d "$DXMT/x86_64-windows" ]; then
        # Steam's browser draws in a GPU process into a window of another process: Highball's DXMT build does that
        # behind this switch, with engine patch 0011 (winemac's cross-process swap chains).
        export WINEDLLPATH_PREPEND="$DXMT" DXMT_ALLOW_CROSS_PROCESS_SWAPCHAIN=1
    else
        echo "WARN: no DXMT in this engine ($DXMT): Steam's window may stay black"
    fi
}

# --- steps ---------------------------------------------------------------------------------------------------------
stop_client() {
    local pids n
    [ -n "$(client_pids)" ] || return 0
    echo "== stopping Steam (steam.exe -shutdown)"
    ( join_live_sync; "$ENGINE/bin/wine" "$STEAM_WIN" -shutdown >> "$LOGS/steam-shutdown.log" 2>&1 & )
    for n in $(seq 60); do [ -z "$(client_pids)" ] && break; sleep 0.5; done
    # its web helpers close a few seconds after steam.exe itself
    for n in $(seq 20); do [ -z "$(helper_pids)" ] && break; sleep 0.5; done
    pids="$(helper_pids)"
    if [ -n "$pids" ]; then
        echo "  Steam did not close by itself: ending its processes (the game, if any, is left alone)"
        kill $pids 2>/dev/null; sleep 3
        pids="$(helper_pids)"; [ -n "$pids" ] && kill -9 $pids 2>/dev/null
    fi
    # an idle prefix: let its wineserver go, so the next start picks its own sync mode
    if [ -z "$(game_pids)" ]; then
        "$ENGINE/bin/wineserver" -w >/dev/null 2>&1 & local w=$!
        for n in $(seq 20); do kill -0 "$w" 2>/dev/null || break; sleep 0.5; done
        { kill "$w" && wait "$w"; } 2>/dev/null
        [ -z "$(prefix_pids)" ] && "$ENGINE/bin/wineserver" -k 2>/dev/null
    fi
    return 0
}

cmd_prefix() {
    if [ -f "$PREFIX/system.reg" ]; then echo "prefix ready: $PREFIX"; return 0; fi
    echo "== creating the Steam prefix: $PREFIX"
    mkdir -p "$PREFIX" || mh_fail "cannot create $PREFIX"
    ( export WINEMSYNC=0 WINEESYNC=0; "$ENGINE/bin/wine" wineboot -i >> "$LOGS/steam-prefix.log" 2>&1; "$ENGINE/bin/wineserver" -w )
    [ -f "$PREFIX/system.reg" ] || mh_fail "wineboot did not create the prefix (see $LOGS/steam-prefix.log)"
    [ -f "$PREFIX/drive_c/windows/syswow64/ntdll.dll" ] || echo "WARN: the prefix has no 32-bit system folder"
    echo "prefix ready"
}

download_setup() {
    local url part="$SETUP.part" size
    mkdir -p "$(dirname "$SETUP")"
    for url in "${MIRRORS[@]}"; do
        echo "== downloading Steam's installer: $url"
        rm -f "$part"
        if ! curl -fL --retry 2 --connect-timeout 20 -sS -o "$part" "$url"; then
            echo "  failed, trying the next mirror"; continue
        fi
        size=$(stat -f %z "$part" 2>/dev/null || echo 0)
        if [ "$size" -lt 1000000 ] || [ "$(head -c 2 "$part")" != "MZ" ]; then
            echo "  not an installer ($size bytes$(grep -q -i '<html' "$part" && echo ', a web page')), trying the next mirror"; continue
        fi
        mv "$part" "$SETUP"; echo "  ok, $size bytes"; return 0
    done
    rm -f "$part"
    mh_fail "Steam's installer could not be downloaded from any of Valve's servers. A VPN, a proxy, a captive portal or a DNS filter that answers for Steam's servers gives exactly this; try another network."
}

cmd_install() {
    cmd_prefix
    if [ -f "$STEAM_EXE" ]; then echo "Steam is already installed in this prefix."; return 0; fi
    [ -z "$(prefix_pids)" ] || mh_fail "programs are still running in the Steam prefix; stop them first"
    download_setup
    window_env
    echo "== installing Steam (silent)"
    "$ENGINE/bin/wine" "$SETUP" /S >> "$LOGS/steam-install.log" 2>&1
    for _ in $(seq 120); do [ -f "$STEAM_EXE" ] && break; sleep 1; done
    "$ENGINE/bin/wineserver" -w >/dev/null 2>&1 & sleep 5; kill $! 2>/dev/null
    [ -f "$STEAM_EXE" ] || { mh_tail_errors "$LOGS/steam-install.log"; mh_fail "Steam's installer ended without installing steam.exe (see steam-install.log)"; }
    # the installer may start Steam; the next Open Steam starts it in the right mode
    stop_client >/dev/null 2>&1
    echo "Steam installed. Next: Open Steam. Its first start downloads and unpacks the full client: 15 to 25 minutes"
    echo "under Rosetta that can look frozen. Let it finish, then sign in and install Forza Horizon 6 from your Library."
}

cmd_open() {
    [ -f "$STEAM_EXE" ] || mh_fail "Steam is not installed in this prefix: Install Steam first"
    # MH_STEAM_URL: a steam:// link Steam opens once it is up, such as steam://install/2483190 (Steam's own install
    # window for the game, its licence checked by Steam). Only steam:// links are passed on.
    local url="${MH_STEAM_URL:-}"
    case "$url" in steam://*) ;; *) url="" ;; esac
    case "$(client_mode)" in
        window)
            echo "== Steam is running: ${url:+opening $url, }bringing its window up"
            ( join_live_sync; "$ENGINE/bin/wine" "$STEAM_WIN" "${url:-steam://open/main}" >> "$LOGS/steam-forward.log" 2>&1 & )
            return 0 ;;
        game)
            if [ -n "$(game_pids)" ]; then
                echo "The game is running: Steam's window opens after it (it cannot draw while Steam runs in game mode)."
                return 0
            fi
            stop_client ;;
    esac
    end_leftovers none
    window_env
    echo "== opening Steam (DXMT, sync off). Log: $LOGS/steam-window.log"
    mh_print_env
    mark window none
    ( cd "$STEAM_DIR" && exec "$ENGINE/bin/wine" "$STEAM_WIN" ${url:+"$url"} > "$LOGS/steam-window.log" 2>&1 & )
    sleep 3
    echo "Steam is starting. Its first start updates the client and can look frozen for a while."
}

manifest_value() {   # manifest_value <key>: a value of this game's appmanifest, empty when there is none
    local f
    for f in "$STEAM_DIR/steamapps/appmanifest_$APPID.acf" "$STEAM_DIR/SteamApps/appmanifest_$APPID.acf"; do
        [ -f "$f" ] && { sed -n "s/^[[:space:]]*\"$1\"[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$f" | head -1; return; }
    done
}

STRATEGY_FILE="$PREFIX/.metalhorizon-steam-strategy"

# The Steam client's own errors since <offset> in its output: a Steam client given D3DMetal for its web views aborts
# ("NSViewBackingLayer setDisplaySyncEnabled", a player's M4 on macOS 27.2).
client_aborted() {
    tail -c +$(( ${2:-0} + 1 )) "$1" 2>/dev/null | grep -q -E 'setDisplaySyncEnabled|Terminating app due to uncaught exception'
}

# wait_for_game <log> <offset> <minutes>: 0 when the game runs, 1 when the client aborted or vanished, 2 on timeout.
wait_for_game() {
    local log="$1" offset="$2" limit=$(( $3 * 60 )) waited=0 gone=0
    until [ -n "$(game_pids)" ]; do
        sleep 2; waited=$((waited + 2))
        [ $((waited % 60)) -eq 0 ] && echo "  waiting for the game to start ($((waited / 60)) min; Steam may be updating or signing in)"
        client_aborted "$log" "$offset" && { echo "  the Steam client stopped with an error"; return 1; }
        # Steam restarts itself after an update: only a client gone for 20 s in a row counts
        if [ -z "$(client_pids)" ]; then gone=$((gone + 1)); else gone=0; fi
        [ "$gone" -ge 10 ] && [ "$waited" -gt 30 ] && { echo "  the Steam client stopped"; return 1; }
        [ "$waited" -ge "$limit" ] && return 2
    done
    return 0
}

# run_and_watch <offset> <start>: the game's run, the Neural Engine relaunch decision. 0 done, 3 relaunch.
game_finished() {
    local offset="$1" start="$2" attempt="$3" elapsed
    while [ -n "$(game_pids)" ]; do sleep 2; done
    elapsed=$(( $(date +%s) - start ))
    echo "== game closed after ${elapsed}s"
    if [ "$attempt" -le "${MH_RETRIES:-2}" ] && [ "$elapsed" -lt 150 ] && mh_ane_failure "$GAME_LOG" "$offset"; then
        echo "== D3DMetal stopped while preparing the Neural Engine (com.apple.appleneuralengine Code=26): relaunching"
        mh_mark_retried "$GAME_LOG"; sleep 3; return 3
    fi
    [ "$elapsed" -ge 150 ] && mh_ane_failure "$GAME_LOG" "$offset" && mh_mark_retried "$GAME_LOG" harmless
    return 0
}

# First way: Steam starts the game (-applaunch), from a silent client in game mode. Its web views run without the GPU
# (-cef-disable-gpu): with it, they would draw through D3DMetal, which aborts on their windows; only the game, which
# inherits the client's environment, needs D3DMetal. Returns 1 when Steam could not start the game.
play_applaunch() {
    local attempt=0 start offset code minutes=30
    # someone who signed in already does not need 30 minutes: a hidden Steam dialog would wait forever
    [ -f "$STEAM_DIR/config/loginusers.vdf" ] && grep -q '"AccountName"' "$STEAM_DIR/config/loginusers.vdf" && minutes=5
    minutes="${MH_WAIT_MINUTES:-$minutes}"
    # a client kept for the second way runs on DXMT: the game would inherit it
    [ "$(cut -d' ' -f1 "$MARKER" 2>/dev/null)" = direct ] && stop_client && end_leftovers msync
    while :; do
        attempt=$((attempt + 1)); start=$(date +%s)
        : >> "$GAME_LOG"; offset=$(mh_size "$GAME_LOG")
        if [ -n "$(client_pids)" ]; then
            echo "== launch $attempt: asking the running Steam client"
            ( join_live_sync; "$ENGINE/bin/wine" "$STEAM_WIN" -applaunch "$APPID" >> "$LOGS/steam-forward.log" 2>&1 & )
        else
            echo "== launch $attempt: a silent Steam client (web views without GPU) starts the game. Steam output: $GAME_LOG"
            mark game msync
            ( cd "$STEAM_DIR" && exec "$ENGINE/bin/wine" "$STEAM_WIN" -silent -cef-disable-gpu -cef-disable-gpu-compositing \
                -applaunch "$APPID" >> "$GAME_LOG" 2>&1 & )
        fi
        wait_for_game "$GAME_LOG" "$offset" "$minutes"; code=$?
        [ "$code" -eq 0 ] || return 1
        echo "== game started (through Steam). Quit it from its own menu; Steam stays open in the background."
        game_finished "$offset" "$start" "$attempt"
        [ $? -eq 3 ] && continue
        return 0
    done
}

# Second way: Steam runs beside the game, silent, with its web views on DXMT as its window would be, and MetalHorizon
# starts the game itself with D3DMetal. The game gets its Steam ticket from that client: SteamAppId and SteamGameId tell
# its Steam library which game it is, as Steam does for the games it starts. From C:\Program Files (x86)\Steam, so
# the game's path check passes.
play_direct() {
    local dir attempt=0 start offset code waited=0
    dir="$(manifest_value installdir)"
    [ -n "$dir" ] && [ -f "$STEAM_DIR/steamapps/common/$dir/forzahorizon6.exe" ] || mh_fail "the game's files are not in Steam's library folder (steamapps/common/$dir)"
    if [ "$(cut -d' ' -f1 "$MARKER" 2>/dev/null)" != direct ] || [ -z "$(client_pids)" ]; then
        [ -z "$(client_pids)" ] || stop_client
        end_leftovers msync
        echo "== starting Steam beside the game (silent, DXMT, msync)"
        mark direct msync
        ( window_env; export WINEMSYNC=1 WINEESYNC=0; cd "$STEAM_DIR" && exec "$ENGINE/bin/wine" "$STEAM_WIN" -silent >> "$GAME_LOG" 2>&1 & )
        # the client signs in from its saved session; give it the time to be there for the game
        until [ "$waited" -ge 45 ]; do
            sleep 3; waited=$((waited + 3))
            [ -n "$(client_pids)" ] && [ "$waited" -ge 20 ] && break
        done
        [ -n "$(client_pids)" ] || { mh_tail_errors "$GAME_LOG"; mh_fail "the Steam client did not start"; }
    fi
    export SteamAppId="$APPID" SteamGameId="$APPID" SteamOverlayGameId="$APPID"
    while :; do
        attempt=$((attempt + 1)); start=$(date +%s)
        : >> "$GAME_LOG"; offset=$(mh_size "$GAME_LOG")
        echo "== launch $attempt: MetalHorizon starts the game (D3DMetal), Steam beside it"
        ( cd "$STEAM_DIR/steamapps/common/$dir" && exec "$ENGINE/bin/wine" "C:\\Program Files (x86)\\Steam\\steamapps\\common\\$dir\\forzahorizon6.exe" >> "$GAME_LOG" 2>&1 & )
        wait_for_game "$GAME_LOG" "$offset" 2; code=$?
        if [ "$code" -ne 0 ]; then mh_tail_errors "$GAME_LOG"; mh_fail "the game did not start"; fi
        echo "== game started. Quit it from its own menu; Steam stays open in the background."
        game_finished "$offset" "$start" "$attempt"
        [ $? -eq 3 ] && continue
        return 0
    done
}

cmd_play() {
    [ -f "$STEAM_EXE" ] || mh_fail "Steam is not installed in this prefix: Install Steam first"
    local flags; flags="$(manifest_value StateFlags)"
    [ -n "$flags" ] || mh_fail "Forza Horizon 6 is not in this prefix's Steam library: Open Steam, sign in and install it from your Library"
    [ $(( flags & 4 )) -ne 0 ] || mh_fail "Forza Horizon 6 is not fully installed yet (Steam state $flags): let Steam finish the download"
    [ -n "$D3DM" ] && [ -n "$SHIM" ] || mh_fail "MH_D3DMETAL and MH_SHIM are needed to play"
    mh_game_env
    if [ -n "${MH_DRY_RUN:-}" ]; then
        export -p | sed -n 's/^declare -x //p' | grep -E '^(CX_|WINE|D3DM_|MTL_|HB_|DYLD_|MVK_)' | sort
        echo "run: $ENGINE/bin/wine '$STEAM_WIN' -silent -cef-disable-gpu -cef-disable-gpu-compositing -applaunch $APPID"
        echo "fallback: Steam silent on DXMT beside the game, then forzahorizon6.exe with SteamAppId=$APPID (strategy now: $(cat "$STRATEGY_FILE" 2>/dev/null || echo applaunch))"
        exit 0
    fi
    echo "== MetalHorizon Play, Steam edition (appid $APPID, build $(manifest_value buildid)), $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  engine: $("$ENGINE/bin/wine" --version 2>/dev/null); macOS $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
    mh_print_env
    if [ -n "$(game_pids)" ]; then
        echo "Forza Horizon 6 is already running: waiting for it to close."
    else
        if [ "$(client_mode)" = window ]; then stop_client; fi
        end_leftovers msync
        mh_crash_to_log
        local strategy
        strategy="${MH_STEAM_STRATEGY:-$(cat "$STRATEGY_FILE" 2>/dev/null)}"
        [ "$strategy" = direct ] || strategy=applaunch
        if [ "$strategy" = applaunch ]; then
            if play_applaunch; then echo applaunch > "$STRATEGY_FILE"; mh_tail_errors "$GAME_LOG"; return 0; fi
            echo "== Steam could not start the game itself: MetalHorizon starts it, with Steam running beside it"
            stop_client
            end_leftovers msync
        fi
        local direct_from; : >> "$GAME_LOG"; direct_from=$(mh_size "$GAME_LOG")
        play_direct && echo direct > "$STRATEGY_FILE"
        # started directly, the game got no Steam ticket (E:0-0-L-8, "Initialization failed", its own sign-in prompt):
        # this way is not kept; the next Play goes through Steam again (-applaunch), which hands the ticket
        if tail -c +"$((direct_from + 1))" "$GAME_LOG" 2>/dev/null | grep -a -q -E 'E:0-0-L-8|Initialization failed'; then
            echo "== the game started this way got no Steam ticket (E:0-0-L-8): the next Play goes through Steam again"
            rm -f "$STRATEGY_FILE"
        fi
    fi
    while [ -n "$(game_pids)" ]; do sleep 2; done
    mh_tail_errors "$GAME_LOG"
    return 0
}

cmd_status() {
    local flags signed=no mode
    [ -f "$STEAM_DIR/config/loginusers.vdf" ] && grep -q '"AccountName"' "$STEAM_DIR/config/loginusers.vdf" && signed=yes
    flags="$(manifest_value StateFlags)"; mode="$(client_mode)"
    echo "prefix=$([ -f "$PREFIX/system.reg" ] && echo yes || echo no)"
    echo "prefix_32bit=$([ -f "$PREFIX/drive_c/windows/syswow64/ntdll.dll" ] && echo yes || echo no)"
    echo "engine_32bit=$([ -f "$ENGINE/lib/wine/i386-windows/ntdll.dll" ] && echo yes || echo no)"
    echo "engine_dxmt=$([ -d "$DXMT/x86_64-windows" ] && echo yes || echo no)"
    echo "steam_installed=$([ -f "$STEAM_EXE" ] && echo yes || echo no)"
    echo "client_running=$([ -n "$mode" ] && echo yes || echo no)"
    echo "client_mode=${mode:-none}"
    echo "signed_in_once=$signed"
    echo "game_installed=$([ -n "$flags" ] && [ $(( flags & 4 )) -ne 0 ] && echo yes || echo no)"
    echo "game_state_flags=${flags:-none}"
    echo "game_build=$(manifest_value buildid)"
    echo "game_running=$([ -n "$(game_pids)" ] && echo yes || echo no)"
}

case "$ACTION" in
    prefix) cmd_prefix ;;
    install) cmd_install ;;
    open) cmd_open ;;
    play) cmd_play ;;
    stop) stop_client; echo "Steam stopped." ;;
    status) cmd_status ;;
    *) mh_fail "unknown action $ACTION (prefix, install, open, play, stop, status)" ;;
esac
