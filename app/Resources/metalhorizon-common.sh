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
#   MH_ROUTE=native   the native Apple silicon engine instead of D3DMetal (Blackwell Engine Native, MH_NATIVE)
#   MH_NATIVE         the native bundle: engine/ (Wine 11.18 arm64 + FEX), frameworks/, renderers/ (vkd3d, kosmickrisp)

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
    # msync, unless the Autopilot switched to Wine's plain synchronization after msync failed to start (MH_SYNC=plain)
    if [ "${MH_SYNC:-msync}" = plain ]; then export WINEMSYNC=0 WINEESYNC=0; else export WINEMSYNC=1 WINEESYNC=0; fi
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

# The native engine (MH_ROUTE=native): what every Wine process gets. Highball's arm64 line (engine manifest
# arm64-kk-wine11.18-r4, baseEnv): the frameworks folder holds GStreamer and the host libraries the Unix side links
# (the signed loader allows DYLD variables), and Vulkan is KosmicKrisp, Mesa's driver on Metal 4, through the Khronos
# loader the engine ships as libMoltenVK.dylib.
mh_native_engine_env() {
    NATIVE="${MH_NATIVE:?}"
    ENGINE="$NATIVE/engine"
    export WINEDEBUG="${MH_WINEDEBUG:--all}"
    export DYLD_FALLBACK_LIBRARY_PATH="$NATIVE/frameworks"
    export GST_PLUGIN_PATH="$NATIVE/frameworks/GStreamer.framework/Versions/1.0/lib/gstreamer-1.0"
    export VK_DRIVER_FILES="$NATIVE/renderers/kosmickrisp/kosmickrisp_icd.json" VK_LOADER_LAYERS_DISABLE='~implicit~'
    export MESA_SHADER_CACHE_MAX_SIZE=4G DXVK_RELAX_FEATURES=1
    unset WINEMSYNC WINEESYNC CX_ROOT CX_GRAPHICS_BACKEND
    export WINEDLLOVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
}

# The game on the native engine: Highball's Forza Horizon 6 route (highball-db recipes/games/forza-horizon-6.json,
# previewRoute, measured on an M4 at an even 30 frames a second with no hitch over 150 ms). Direct3D 12 through
# vkd3d-proton with DXVK's DXGI, both from the renderers overlay; FEX's switches for a program whose copy protection
# keeps rewriting its code (that rewriting is the hitch under Rosetta); the GPU the game is told it has.
mh_native_game_env() {
    [ -d "$NATIVE/renderers/vkd3d/wine" ] || mh_fail "the native engine's vkd3d-proton is missing ($NATIVE/renderers/vkd3d)"
    [ -f "$NATIVE/renderers/kosmickrisp/kosmickrisp_icd.json" ] || mh_fail "the native engine's Vulkan driver is missing ($NATIVE/renderers/kosmickrisp)"
    export WINEDLLPATH_PREPEND="$NATIVE/renderers/vkd3d/wine"
    export WINEDLLOVERRIDES="dxgi,d3d11,d3d10core,d3d12,d3d12core=n,b;concrt140,msvcp140,msvcp140_1,msvcp140_2,msvcp140_atomic_wait,msvcp140_codecvt_ids,vccorlib140,vcomp140,vcruntime140,vcruntime140_1=n,b;gameoverlayrenderer64,gameoverlayrenderer=d;$WINEDLLOVERRIDES"
    export VKD3D_RELAX_DEVICE_CAPS=1 VKD3D_FEATURE_LEVEL=12_1 VKD3D_SHADER_MODEL=6_6 VKD3D_CONFIG=no_staggered_submit
    export VKD3D_DEBUG=err DXVK_LOG_LEVEL=warn HB_KK_NO_UBO_ROBUST=1
    # vkd3d-proton's pipeline cache, in the prefix: the folder must exist or every start compiles everything again
    # ("Failed to open stream archive"). One folder per engine build, as Highball does.
    export VKD3D_SHADER_CACHE_PATH='C:\metalhorizon\cache\vkd3d\native-1'
    mkdir -p "$PREFIX/drive_c/metalhorizon/cache/vkd3d/native-1" "$PREFIX/.mesa-cache" 2>/dev/null
    export MESA_SHADER_CACHE_DIR="$PREFIX/.mesa-cache"
    # FEX: keep the translations of code the protection rewrites (Highball's FEX 0020, 0023, 0033, 0034)
    export HB_FEX_FAST_LEGACY_UD=1 HB_FEX_FAST_PREFIX_UD=1 HB_FEX_DIRECT_SIGILL=1 HB_FEX_SMC_GRAVE_SETS=16384
    export HB_FEX_SMC_INLINE=1 HB_FEX_SMC_INLINE_MS=10000 HB_FEX_SMC_INLINE_RETIRE_PROT=1 HB_FEX_SMC_INLINE_RETIRE_FREE=1
    export HB_FEX_SMC_INLINE_RETIRE_UNMAP=1 HB_FEX_SMC_INLINE_KEEP_READ=1 HB_FEX_SMC_INLINE_BLOCK_REMOVE=1
    export HB_FEX_PRIVATE_CHURN=20000 HB_DIRECT_CONTINUE=1 HB_FEX_MAPJIT=1 HB_FEX_SMC_RETIRE=1 HB_FEX_SMC_REINSTATE=1
    export HB_FEX_SMC_RETIRE_FAULTS=1 HB_FEX_CALLRET_EPOCH=1 HB_FEX_SMC_CACHE_FILTER=1 HB_FEX_SMC_REPLAY=0
    export FEX_SMCCHECKS=mtrack FEX_DISKCACHE=0
    # The GPU the game sees through DXGI, and DXVK's memory budget (three eighths of the Mac's memory).
    local mem_mb=$(( $(sysctl -n hw.memsize) / 1048576 ))
    export DXVK_CONFIG="dxgi.maxVideoMemoryBudget=$(( mem_mb * 3 / 8 ));dxgi.maxDeviceMemory=8192;dxgi.maxSharedMemory=8192;dxgi.customVendorId=8086;dxgi.customDeviceId=56a1;dxgi.customDeviceDesc=\"Intel(R) Arc(TM) A750 Graphics\""
    # The frame cap: the route's 30 unless the player chose one. Metal holds each frame for its vsync slot when the cap
    # divides 60 and 120 Hz (Highball's present pacing), which is what makes 30 even rather than 30 on average.
    local cap="${MH_MAX_FPS:-0}"; [ "$cap" -gt 0 ] 2>/dev/null || cap=30
    export DXVK_FRAME_RATE="$cap" VKD3D_FRAME_RATE="$cap"
    [ $(( 60 % cap )) -eq 0 ] && export HB_PRESENT_PACE_FPS="$cap"
    [ "${MH_HUD:-1}" != "0" ] && export MTL_HUD_ENABLED=1
    [ "${MH_GAMEINPUT:-0}" = "1" ] && export WINE_GAMEINPUT=1
    return 0
}

# The route's graphics settings for the game's first start on the native engine (1920x1080, Very Low, FSR Quality),
# the ones it was measured on. Written once: what the player changes in the game afterwards stays.
mh_native_first_settings() {
    local src="${MH_NATIVE_SETTINGS:-}" user dest
    [ -f "$src" ] || return 0
    for user in "$PREFIX"/drive_c/users/*/; do
        case "$(basename "$user")" in Public|public) continue ;; esac
        dest="${user}AppData/Local/ForzaHorizon6/LocalStorage_Shared/ForzaUserConfigSelections/UserConfigSelections"
        [ -f "$dest" ] && continue
        mkdir -p "$(dirname "$dest")" && cp "$src" "$dest" && echo "== the native engine's graphics settings for the first start (1080p, Very Low, FSR Quality): change them in the game"
    done
    return 0
}

# mh_keychain_watch <game log> [xodus pid pattern]: while xodus asks for the game's licence, two things can hold it:
# - macOS's Keychain dialog ("xodus wants to use your confidential information stored in Xodus Service"), after a
#   new sign-in or when the binary changed; it can open behind other windows. Said once (the app shows NOTE lines),
#   and waited for: it is the player's to answer.
# - nothing at all: the network or the Xbox licence servers do not answer. Said after 45 s; after 3 minutes the
#   request is stopped with a line the diagnosis knows, so the run ends instead of waiting for ever (the Autopilot
#   then restarts the Xbox service and tries once more).
mh_keychain_watch() {
    local log="$1" pattern="${2:-xodus-(cli|login) run}" said_dialog=0 said_slow=0 waited=0 before=0
    local step="${MH_WATCH_STEP:-3}" slow="${MH_LICENCE_SLOW:-45}" limit="${MH_LICENCE_TIMEOUT:-180}"
    while sleep "$step"; do
        if ! tail -n 1 "$log" 2>/dev/null | grep -q "Requesting the Forza Horizon 6 package license"; then
            [ $waited -gt 0 ] && return 0              # the request was answered: the game goes on
            before=$((before + step)); [ $before -ge 90 ] && return 0
            continue
        fi
        waited=$((waited + step))
        if pgrep -qx SecurityAgent; then
            if [ $said_dialog = 0 ] && [ $waited -ge $((step * 3)) ]; then
                echo "NOTE: macOS is asking to let xodus use your Xbox sign-in (a Keychain window, maybe behind this one): choose Always Allow. The game starts right after."
                said_dialog=1
            fi
            [ $waited -lt 900 ] && continue      # the player's dialog: up to 15 minutes
        fi
        if [ $said_slow = 0 ] && [ $waited -ge "$slow" ]; then
            echo "NOTE: the Xbox licence servers have not answered for 45 s: check the network. MetalHorizon keeps waiting up to 3 minutes."
            said_slow=1
        fi
        if [ $waited -ge "$limit" ]; then
            echo "STOP: the Xbox licence request did not answer in 3 minutes (network, or the Xbox service): stopping it."
            pkill -f "$pattern" 2>/dev/null
            return 0
        fi
    done
}

# The settings that decide which stack a process got, for the top of every log. An allowlist on purpose: logs end
# up in public GitHub issues and the full environment can hold personal paths or tokens.
mh_print_env() {
    export -p | sed -n 's/^declare -x //p' \
        | grep -E '^(MH_ROUTE|CX_GRAPHICS_BACKEND|WINEMSYNC|WINEESYNC|WINEDEBUG|WINEDLLOVERRIDES|WINE_GAMEINPUT|D3DM_|MTL_HUD|HB_TSSHIM|MVK_CONFIG_LOG_LEVEL|VKD3D_(FEATURE_LEVEL|SHADER_MODEL|CONFIG)|DXVK_FRAME_RATE|HB_PRESENT_PACE_FPS|FEX_SMCCHECKS)=' \
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
        if [ "$attempt" -le "${MH_RETRIES:-2}" ] && [ "$elapsed" -lt 30 ] && mh_ane_failure "$log" "$offset"; then
            echo "== D3DMetal stopped while preparing the Neural Engine (com.apple.appleneuralengine Code=26): relaunching"
            "$ENGINE/bin/wineserver" -k 2>/dev/null
            mh_mark_retried "$log"
            sleep 2
            continue
        fi
        # the game went on past the message: it was not what stopped it
        [ "$elapsed" -ge 30 ] && mh_ane_failure "$log" "$offset" && mh_mark_retried "$log" harmless
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
