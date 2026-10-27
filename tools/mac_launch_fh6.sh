#!/bin/bash
# Launch FH6 Store through xodus on Blackwell Engine with a targeted log, and print a summary when the game ends.
# No CrossOver.app: the engine, Apple's D3DMetal and the DirectX 12 shim are the ones the MetalHorizon app installs in
# ~/Library/Application Support/MetalHorizon (open the app once). FH6_ENGINE=<engine folder> tries another engine.
# Usage: bash tools/mac_launch_fh6.sh [max-seconds, default 900]
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
MH="$HOME/Library/Application Support/MetalHorizon"
ENGINE="${FH6_ENGINE:-$MH/Blackwell Engine}"
D3DM="$MH/D3DMetal"; GPTK="$D3DM/external"; SHIM="$MH/Shim/wine"
for f in "$ENGINE/bin/wine" "$ENGINE/lib/libgnutls.30.dylib" "$GPTK/libd3dshared.dylib" "$SHIM/x86_64-windows/apd12.dll"; do
    [ -e "$f" ] || { echo "STOP: $f is missing: open MetalHorizon once, it installs Blackwell Engine and D3DMetal"; exit 1; }
done
PREFIX="$HOME/FH6/.blackwell-wine"
SOURCE="$ROOT/work/audit/gamefarm-audit"
MAX="${1:-900}"
mkdir -p "$REPO/out"
LOG="$REPO/out/fh6-after.log"

export CX_ROOT="$ENGINE"
export CX_GRAPHICS_BACKEND=d3dmetal
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$GPTK/libd3dshared.dylib"
export WINEPREFIX="$PREFIX"
export D3DM_MTL4=1
# Opt-in speed experiment (community-documented, NOT yet measured on FH6; compare the in-game counter with and without):
#   FH6_AVX=1     CRASHES FH6 (user test, 2026-10-22): do not use. Rosetta announces AVX/AVX2/FMA/BMI2 to the game (off by default: tools/mac_cpuid_probe.sh showed AVX: no without it)
[ -n "${FH6_AVX:-}" ] && export ROSETTA_ADVERTISE_AVX=1 && echo "experiment: ROSETTA_ADVERTISE_AVX=1"
# Apple's Metal Performance HUD (FPS, frame pacing, memory, thermal state; with D3DMetal also GPTK metrics) is ON BY DEFAULT
# (user request, 2026-10-22). It costs a little speed itself; FH6_HUD=0 turns it off. Not yet checked to show up with FH6 under this Wine.
[ "${FH6_HUD:-1}" != "0" ] && export MTL_HUD_ENABLED=1 && echo "Metal HUD: on (MTL_HUD_ENABLED=1; FH6_HUD=0 to turn off)"
# FH6_METAL_DEBUG=1: Metal API + shader validation (MTL_DEBUG_LAYER, MTL_SHADER_VALIDATION). HEAVY: crash hunting only, never for playing.
[ -n "${FH6_METAL_DEBUG:-}" ] && export MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 && echo "Metal validation: on (slow)"
# FH6_METAL_CAPTURE=1: lets Xcode / xctrace take GPU captures (MTL_CAPTURE_ENABLED must be set when the process starts).
[ -n "${FH6_METAL_CAPTURE:-}" ] && export MTL_CAPTURE_ENABLED=1 && echo "Metal capture: enabled"
# GPU reported to the game. D3DMetal is AMD by default; FH6 then takes an AMD-only path and crashes
# (FHE21). Highball's recipe reports an NVIDIA RTX 4070 (and so unlocks Reflex/DLSS); an Intel Arc
# A750 also works. FH6_GPU=nvidia (default) | amd | intel.
case "${FH6_GPU:-nvidia}" in
    intel) export D3DM_VENDOR_ID=32902 D3DM_DEVICE_ID=22177 D3DM_DEVICE_DESCRIPTION="Intel(R) Arc(TM) A750 Graphics" ;;
    amd)   export D3DM_VENDOR_ID=4098 D3DM_DEVICE_ID=29631 D3DM_DEVICE_DESCRIPTION="AMD Radeon RX 6800 XT" ;;
    *)     export D3DM_VENDOR_ID=4318 D3DM_DEVICE_ID=10118 D3DM_DEVICE_DESCRIPTION="NVIDIA GeForce RTX 4070" ;;
esac
echo "GPU reported to the game: $D3DM_DEVICE_DESCRIPTION"
export WINEMSYNC=1
# Apple's d3d12/dxgi halves behind Highball's shim, as the app assembles them (app/Resources/metalhorizon-play.sh)
export WINEDLLPATH_PREPEND="$SHIM:$D3DM/wine"
export HB_D3D12_REAL="Z:$SHIM/x86_64-windows/apd12.dll"
export WINEDEBUG="${FH6_DEBUG:-+timestamp,+loaddll,warn+process,err+all}"
export WINEDLLOVERRIDES="concrt140,msvcp140,msvcp140_atomic_wait,vcruntime140,vcruntime140_1=n,b"
export DYLD_LIBRARY_PATH="$ENGINE/lib:$GPTK"   # the engine's own GnuTLS, FreeType, MoltenVK, then D3DMetal
export DYLD_FRAMEWORK_PATH="$GPTK"
export XODUS_RUNTIME_DIR=/private/tmp/xodus-runtime-test
# FH6_NO_TSSHIM=1: test with Apple's own d3d12.dll without the shim (the game then reports FH205/FH206)
if [ -n "${FH6_NO_TSSHIM:-}" ]; then export WINEDLLPATH_PREPEND="$D3DM/wine"; unset HB_D3D12_REAL; echo "tsshim disabled"; fi
# Shader fixes the shim hands D3DMetal in place of the game's (C:\highball\replace\fix, tools/mac_shader_fixes.sh);
# HB_TSSHIM_REPLACE=none turns them off. HB_TSSHIM_INSPECT=1: the shim's inspector (report: bash tools/mac_fh6_inspect.sh).
if [ -z "${FH6_NO_TSSHIM:-}" ] && [ -z "${HB_TSSHIM_REPLACE:-}" ] && [ -d "$PREFIX/drive_c/highball/replace/fix" ]; then export HB_TSSHIM_REPLACE=fix; fi
[ -n "${HB_TSSHIM_REPLACE:-}" ] && echo "shader replacements: $HB_TSSHIM_REPLACE"
[ -n "${HB_TSSHIM_INSPECT:-}" ] && echo "inspector: on (watch: ${HB_TSSHIM_INSPECT_WATCH:-none}); report: bash tools/mac_fh6_inspect.sh"
echo "Blackwell Engine: $ENGINE; D3DMetal $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$GPTK/D3DMetal.framework/Versions/A/Resources/Info.plist" 2>/dev/null)"
# FH6 refuses to run from a long folder ("Installation path is too long", message box seen on the Mac).
# The game folder is renamed to ~/FH6 by tools/mac_move_short.sh (old path kept as a symlink).
# FH6_LONG_PATH=1 keeps the old long path.
if [ -z "${FH6_LONG_PATH:-}" ]; then
    # xodus resolves symlinks, so the folder itself must have the short name: tools/mac_move_short.sh
    if [ -d "$HOME/FH6" ] && [ ! -L "$HOME/FH6" ]; then SOURCE="$HOME/FH6"; else
        echo "STOP: run tools/mac_move_short.sh first (game folder must be ~/FH6)"; exit 1; fi
    echo "game path: $SOURCE"
fi
# FH6_QUICK=1 (tools/jouer.sh): just play. No traces, no log, no checks, no summary; everything above (GPU identity,
# shim, D3DMetal, short path) still applies, and so does the Xbox service (sign-in and cloud saves need it).
if [ -n "${FH6_QUICK:-}" ]; then
    export WINEDEBUG=-all
    mkdir -p "$PREFIX/drive_c/highball/logs" 2>/dev/null
    if [ -z "${FH6_NO_XODUS_SERVICE:-}" ]; then bash "$REPO/tools/mac_xodus_service.sh" start >/dev/null 2>&1 || echo "WARN: xodus-service did not start; no Xbox sign-in"; fi
    WINEPREFIX="$PREFIX" "$ENGINE/bin/wineserver" -k 2>/dev/null || true
    cd "$SOURCE" || exit 1
    echo "== jeu lance, sans journal. Ferme-le par son menu, puis attends 30 s (envoi de la sauvegarde). Pas de Ctrl+C."
    "$ROOT/work/xodus/target/release/xodus-cli" run "$SOURCE" "$ENGINE/bin/wine" --exe forzahorizon6.exe >/dev/null 2>&1
    WINEPREFIX="$PREFIX" "$ENGINE/bin/wineserver" -k 2>/dev/null || true
    echo "== jeu ferme"
    exit 0
fi
echo "== checks"
python3 "$REPO/tools/check_runtime.py" "$ENGINE" | grep -A0 "F_GETPATH\|0009\|0013"
strings "$ROOT/work/xodus/target/release/xodus-cli" | grep -c "xodus-image-" | sed 's/^/xodus-cli named-image fix present: /'
ls "$XODUS_RUNTIME_DIR" 2>/dev/null | head -5 || echo "note: $XODUS_RUNTIME_DIR is empty (xodus service not running?)"

mkdir -p "$PREFIX/drive_c/highball/logs" 2>/dev/null   # HB_TSSHIM_DEBUG writes here
# The shim's log is named after Wine's process id, the same every run: a debug run starts with the old ones moved to
# logs/old, and out/fh6-run.stamp says when the run began and with which shim settings (tools/mac_shader_fixes.sh).
if [ -n "${HB_TSSHIM_DEBUG:-}" ]; then mkdir -p "$PREFIX/drive_c/highball/logs/old"; mv "$PREFIX"/drive_c/highball/logs/tsshim-*.log "$PREFIX/drive_c/highball/logs/old/" 2>/dev/null; fi
printf 'start=%s HB_TSSHIM_DEBUG=%s HB_TSSHIM_DUMP=%s HB_TSSHIM_REPLACE=%s HB_TSSHIM_INSPECT=%s\n' "$(date +%s)" "${HB_TSSHIM_DEBUG:-}" "${HB_TSSHIM_DUMP:-}" "${HB_TSSHIM_REPLACE:-}" "${HB_TSSHIM_INSPECT:-}" > "$REPO/out/fh6-run.stamp"
# xodus-service holds the Microsoft account and answers the game's Xbox token requests on $XODUS_RUNTIME_DIR/xodus.sock.
# `xodus-cli run` does not start it, and without it the game says "Cloud save synchronization failed".
# FH6_NO_XODUS_SERVICE=1 skips it.
if [ -z "${FH6_NO_XODUS_SERVICE:-}" ]; then bash "$REPO/tools/mac_xodus_service.sh" start || echo "WARN: xodus-service did not start; no Xbox sign-in"; fi
WINEPREFIX="$PREFIX" "$ENGINE/bin/wineserver" -k 2>/dev/null || true
cd "$SOURCE" || exit 1
echo "== launching (up to $MAX s; quit the game or press Ctrl+C to stop)"
"$ROOT/work/xodus/target/release/xodus-cli" run "$SOURCE" "$ENGINE/bin/wine" --exe forzahorizon6.exe >"$LOG" 2>&1 &
PID=$!
trap 'kill -INT $PID 2>/dev/null' INT
for i in $(seq "$MAX"); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -INT "$PID" 2>/dev/null; sleep 3; kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
WINEPREFIX="$PREFIX" "$ENGINE/bin/wineserver" -k 2>/dev/null || true

echo "== summary ($LOG)"
# one pass over the (huge) log: count the traps, keep everything but the per-trap seh/unwind lines
SMALL="$REPO/out/fh6-small.log"
LC_ALL=C awk -v cnt="$REPO/out/fh6-counts.txt" '
    /c000001d/ { ill++ }
    /:seh:|:unwind:/ && !/FH6 null call|no module for rip|start_debugger|personality routine|Unhandled|NtRaiseException/ { next }
    { print }
    END { print NR, ill + 0 > cnt }' "$LOG" > "$SMALL"
read TOTAL ILL < "$REPO/out/fh6-counts.txt"
echo "lines: $TOTAL   ran for about ${i}s"
echo "-- fd reopen:";            grep -m3 "cannot be reopened" "$SMALL" || echo "ok (no 'cannot be reopened')"
echo "-- image served:";         grep -c "served from the mapped image descriptor" "$SMALL"
echo "-- xgameruntime:";         grep -m3 -i "xgameruntime" "$SMALL" || echo "NOT loaded"
echo "-- self termination:";     grep -m3 "terminating itself abnormally" "$SMALL" || echo "none"
echo "-- illegal instructions:"; echo "$ILL"
echo "-- last 25 lines:";        tail -25 "$SMALL"
