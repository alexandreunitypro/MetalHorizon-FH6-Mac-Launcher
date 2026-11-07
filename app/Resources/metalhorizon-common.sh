#!/bin/bash
# Shared by MetalHorizon's scripts (sourced, not run): the environment every Wine process gets, the game's graphics
# settings, and the retry around a launch. The app passes these variables:
#   MH_ENGINE         Blackwell Engine (bin/wine; lib/ holds its own GnuTLS, FreeType, MoltenVK and SDL2)
#   MH_D3DMETAL       Apple's D3DMetal: the Game Porting Toolkit's redist/lib (external/ and wine/)
#   MH_SHIM           the DirectX 12 shim the app assembles (x86_64-windows/d3d12.dll + apd12.dll, x86_64-unix/apd12.so)
#   MH_HUD=0          Apple's Metal HUD off (on by default)
#   MH_GAMEINPUT=1    controllers through GameInput (engine patch 0012), set when a pad is connected or forced on
#   MH_METALFX=1      D3DMetal's MetalFX upscaling (the game then offers DLSS); off by default
#   MH_MAX_FPS=<n>    a frame cap from D3DMetal (0 or unset: none)
#   MH_RETRIES=<n>    relaunches after D3DMetal's Neural Engine start-up failure (default 2, 0 to turn off)
#   MH_WINEDEBUG      Wine channels for a debug run (default -all)
#   MH_DRY_RUN=1      print the environment and the command, start nothing

mh_fail() { echo "STOP: $1"; exit 1; }

# What every Wine process in a prefix gets. MoltenVK's info dump (150 lines of extensions per process) is cut to
# errors: it buried the useful lines of every log.
mh_engine_env() {
    export CX_ROOT="$ENGINE" WINEDEBUG="${MH_WINEDEBUG:--all}" MVK_CONFIG_LOG_LEVEL=1
    export DYLD_LIBRARY_PATH="$ENGINE/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    # No "install Wine Mono / Gecko?" box on a new prefix: nothing here needs them.
    export WINEDLLOVERRIDES="mscoree,mshtml=${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
}

# The game's graphics stack and identity (Highball's recipe), plus the player's options.
mh_game_env() {
    [ -f "$D3DM/external/libd3dshared.dylib" ] && [ -d "$D3DM/wine" ] || mh_fail "D3DMetal 4 is not installed ($D3DM)"
    [ -f "$SHIM/x86_64-windows/apd12.dll" ] && [ -e "$SHIM/x86_64-unix/apd12.so" ] || mh_fail "the DirectX 12 shim is not ready ($SHIM)"
    export CX_GRAPHICS_BACKEND=d3dmetal D3DM_MTL4=1
    [ "${MH_HUD:-1}" != "0" ] && export MTL_HUD_ENABLED=1
    # GPU reported to the game: D3DMetal says AMD by default and FH6 then crashes in its AMD-only code (FHE21).
    export D3DM_VENDOR_ID=4318 D3DM_DEVICE_ID=10118 D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 4070"
    export WINEMSYNC=1 WINEESYNC=0
    # Microsoft's own C++ runtime: Wine's concrt140 hands out concurrent_vector memory too early (the game's update of
    # 3 November 2026 crashes on it, highball-db), and the Steam overlay's renderer is off.
    export WINEDLLOVERRIDES="concrt140,msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,msvcp140_codecvt_ids,vccorlib140,vcomp140,vcruntime140,vcruntime140_1=n,b;gameoverlayrenderer64,gameoverlayrenderer=d;$WINEDLLOVERRIDES"
    # Apple's d3d12, dxgi and d3d12core halves behind Highball's shim (it clears FH205/FH206); all of Apple's .so files
    # are one library, libd3dshared.dylib. The engine's lib/ comes first: its GnuTLS, FreeType, MoltenVK and SDL2.
    export CX_APPLEGPTK_LIBD3DSHARED_PATH="$D3DM/external/libd3dshared.dylib"
    export DYLD_LIBRARY_PATH="$ENGINE/lib:$D3DM/external" DYLD_FRAMEWORK_PATH="$D3DM/external"
    export WINEDLLPATH_PREPEND="$SHIM:$D3DM/wine" HB_D3D12_REAL="Z:$SHIM/x86_64-windows/apd12.dll"
    [ -d "$PREFIX/drive_c/highball/replace/fix" ] && export HB_TSSHIM_REPLACE=fix
    [ "${MH_GAMEINPUT:-0}" = "1" ] && export WINE_GAMEINPUT=1
    [ "${MH_METALFX:-0}" = "1" ] && export D3DM_ENABLE_METALFX=1
    [ "${MH_MAX_FPS:-0}" -gt 0 ] 2>/dev/null && export D3DM_MAX_FPS="$MH_MAX_FPS"
    return 0
}

# The settings that decide which stack a process got, for the top of every log. An allowlist on purpose: logs end
# up in public GitHub issues and the full environment can hold personal paths or tokens.
mh_print_env() {
    export -p | sed -n 's/^declare -x //p' \
        | grep -E '^(CX_GRAPHICS_BACKEND|WINEMSYNC|WINEESYNC|WINEDEBUG|WINEDLLOVERRIDES|WINE_GAMEINPUT|D3DM_|MTL_HUD|HB_TSSHIM|MVK_CONFIG_LOG_LEVEL)=' \
        | sort | sed 's/^/  /'
}

# Apple's D3DMetal can abort at start-up while it compiles a Core ML model for the Neural Engine (its frame
# interpolator): Wine processes have no code-signing identity for it. It depends on timing, so a relaunch usually
# gets through.
mh_ane_failure() {   # mh_ane_failure <log> [byte offset]: the failure in what the log got after the offset
    tail -c +$(( ${2:-0} + 1 )) "$1" 2>/dev/null | grep -v -E '\((retried|harmless)\)' | grep -q -E 'com\.apple\.appleneuralengine.*Code=26|doCompileModel:csIdentity'
}
mh_size() { stat -f %z "$1" 2>/dev/null || echo 0; }
# mh_mark_retried <log> [tag]: marks the Neural Engine message as relaunched ("retried", the default) or as survived
# ("harmless": the game went on), so the diagnosis does not report it as the run's problem.
mh_mark_retried() {
    local tag="${2:-retried}"
    sed -i '' "/(retried)\|(harmless)/!s/com\.apple\.appleneuralengine/($tag) com.apple.appleneuralengine/; /(retried)\|(harmless)/!s/doCompileModel:csIdentity/($tag) doCompileModel:csIdentity/" "$1" 2>/dev/null
}

# mh_run_game <log> <command...>: runs the game, relaunching it after the Neural Engine failure above when it ends
# within two and a half minutes. Prints one line per attempt; returns the last exit code.
mh_run_game() {
    local log="$1" attempt=0 code start elapsed offset; shift
    while :; do
        attempt=$((attempt + 1)); start=$(date +%s); offset=$(mh_size "$log")
        echo "== launch $attempt"
        "$@" >> "$log" 2>&1; code=$?
        elapsed=$(( $(date +%s) - start ))
        echo "== exit $code after ${elapsed}s"
        if [ "$attempt" -le "${MH_RETRIES:-2}" ] && [ "$elapsed" -lt 150 ] && mh_ane_failure "$log" "$offset"; then
            echo "== D3DMetal stopped while preparing the Neural Engine (com.apple.appleneuralengine Code=26): relaunching"
            "$ENGINE/bin/wineserver" -k 2>/dev/null
            mh_mark_retried "$log"
            sleep 2
            continue
        fi
        # the game went on past the message: it was not what stopped it
        [ "$elapsed" -ge 150 ] && mh_ane_failure "$log" "$offset" && mh_mark_retried "$log" harmless
        return "$code"
    done
}

# Wine's crash dialog ("Program Error") off in the prefix: winedbg then prints the exception and the backtrace into
# the game's output, where MetalHorizon's crash report reads them, instead of a box the player would have to copy.
# Runs with the caller's sync mode (the game's), so it must come where the game is about to start in that mode.
mh_crash_to_log() {
    [ -f "$PREFIX/user.reg" ] || return 0
    grep -q '"ShowCrashDialog"=dword:00000000' "$PREFIX/user.reg" 2>/dev/null && return 0
    "$ENGINE/bin/wine" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1
    return 0
}

# mh_tail_errors <log>: the lines worth seeing at the end of a run (Wine errors, D3DMetal, crashes), at most 25.
mh_tail_errors() {
    grep -a -E 'err:|Unhandled|page fault|NSInvalidArgumentException|Terminating app|D3DMetal.*(Error|error)|appleneuralengine|msync_init|ntdll.*c0000135|Installation path|STOP:|panicked' "$1" 2>/dev/null \
        | grep -v -E 'FHTRACE|fh6fault:fh6_fault_report (stack|r[0-9a-z]+ ->|slot)|\((retried|harmless)\)' | tail -25 | sed 's/^/  | /'
}
