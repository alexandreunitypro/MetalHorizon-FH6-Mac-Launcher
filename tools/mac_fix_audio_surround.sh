#!/bin/bash
# Engine sound fix. FH6 sends most of its sound (engine, dialogue) through a 7.1 / 7.1.4 float stream; on a 2-channel Mac
# Core Audio plays only front left/right of it and drops the rest. Highball's patches 0022 (mmdevapi) and 0023
# (winecoreaudio, AUSpatialMixer) fix that, and they have been in the source since 2026-10-21, but were never compiled:
# mac_apply_forza_patches.sh ran `make dlls/<dir>` (a directory, always "up to date") and then took the marker in the
# source as proof the DLL had it. This script builds the two real targets, installs them with a backup and runs
# tools/audioprobe (8 tones, one per speaker) before and after.
# Usage: bash tools/mac_fix_audio_surround.sh          build + install + probe
#        bash tools/mac_fix_audio_surround.sh probe    probe only (listen: one tone per speaker)
#        bash tools/mac_fix_audio_surround.sh --undo   put the old files back (.pre-audio.bak)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work"
SRC="$WORK/crossover-source/sources/wine"
BUILD="$WORK/crossover-source/build-x64-cross"
ENGINE="$WORK/crossover-source/out-x64/engine"
PFX="$HOME/FH6/.blackwell-wine"
CXLIB="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64"
# installed file | built file
FILES=(
  "$ENGINE/lib/wine/x86_64-unix/winecoreaudio.so|$BUILD/dlls/winecoreaudio.drv/winecoreaudio.so"
  "$ENGINE/lib/wine/x86_64-windows/mmdevapi.dll|$BUILD/dlls/mmdevapi/x86_64-windows/mmdevapi.dll"
  "$PFX/drive_c/windows/system32/mmdevapi.dll|$BUILD/dlls/mmdevapi/x86_64-windows/mmdevapi.dll"
)
mkdir -p "$REPO/out"

probe() {   # $1 = label; prints the probe's lines and whether the stream went through AUSpatialMixer
    local log="$REPO/out/audioprobe-$1.log" P i
    export CX_ROOT="$ENGINE" WINEPREFIX="$PFX" WINEDEBUG="err+all" DYLD_LIBRARY_PATH="$ENGINE/lib:$CXLIB"
    "$ENGINE/bin/wineserver" -k 2>/dev/null
    echo "-- sonde ($1) : ecoute, 8 bips, un par haut-parleur"
    "$ENGINE/bin/wine" "$REPO/tools/audioprobe/audioprobe.exe" 63f 1 > "$log" 2>&1 &
    P=$!
    for i in $(seq 60); do kill -0 "$P" 2>/dev/null || break; sleep 1; done
    kill "$P" 2>/dev/null; "$ENGINE/bin/wineserver" -k 2>/dev/null
    grep -E "^(device|stream|tone|RESULT)|rendered by AUSpatialMixer|spatial mixer|channel layout" "$log" | sed 's/^/   /'
    if grep -q "rendered by AUSpatialMixer" "$log"; then echo "   VERDICT: flux 7.1 mixe en stereo (AUSpatialMixer) -> les 8 bips doivent s'entendre"
    else echo "   VERDICT: pas de mixage -> seuls les bips 1 et 2 (avant gauche/droite) s'entendent"; fi
}

if [ "${1:-}" = "--undo" ]; then
    for pair in "${FILES[@]}"; do i="${pair%%|*}"; [ -f "$i.pre-audio.bak" ] && cp "$i.pre-audio.bak" "$i" && echo "restored $i"; done
    exit 0
fi
if [ "${1:-}" = "probe" ]; then probe ecoute; exit 0; fi
if pgrep -f "xodus-cli|forzahorizon6" >/dev/null; then echo "STOP: le jeu tourne, ferme-le d'abord"; exit 1; fi

echo "== source"
grep -q "HB_SPATIAL" "$SRC/dlls/winecoreaudio.drv/coreaudio.c" || { echo "STOP: patch 0023 absent du source"; exit 1; }
grep -q "channels follow the speaker bits in ascending order" "$SRC/dlls/mmdevapi/spatialaudio.c" || { echo "STOP: patch 0022 absent du source"; exit 1; }
echo "   0022 et 0023 presents"

echo "== build"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export PATH="$REPO/out/cross-bin:$PATH"
make -C "$BUILD" dlls/winecoreaudio.drv/winecoreaudio.so dlls/mmdevapi/x86_64-windows/mmdevapi.dll > "$REPO/out/audio-fix-make.log" 2>&1 \
    || { echo "STOP: build failed"; grep -m6 -E "error|No rule" "$REPO/out/audio-fix-make.log"; exit 1; }
strings -a "$BUILD/dlls/winecoreaudio.drv/winecoreaudio.so" | grep -q "rendered by AUSpatialMixer" \
    || { echo "STOP: le winecoreaudio.so compile ne contient pas le mixeur"; exit 1; }
echo "   ok"

probe avant

echo "== install (sauvegardes .pre-audio.bak)"
for pair in "${FILES[@]}"; do
    i="${pair%%|*}"; b="${pair#*|}"
    [ -f "$i" ] && { [ -f "$i.pre-audio.bak" ] || cp "$i" "$i.pre-audio.bak"; }
    cp "$b" "$i" && echo "   installe: $i"
done

probe apres
echo "== fini. Retour arriere : bash tools/mac_fix_audio_surround.sh --undo"
