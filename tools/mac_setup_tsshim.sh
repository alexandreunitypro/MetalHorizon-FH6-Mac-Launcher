#!/bin/bash
# Build Highball's D3DMetal shim (tools/tsshim/d3d12.c, GPL-3.0) and lay it out so Wine loads it in
# front of CrossOver's working d3d12. The shim's CheckFeatureSupport(SHADER_MODEL) hook is what clears
# Forza Horizon 6's "graphics card not supported" (FH205/FH206); it also skips the depth-resolve that
# froze character select, fixes APPEND_ALIGNED_ELEMENT offsets, and makes pixel shaders that read
# SV_ShadingRate drawable (tools/tsshim/dxil_shadingrate.c).
# Layout built into $ENGINE/renderers/d3dmetal-tsshim-hb/wine (fresh; not the user's own folder):
#   x86_64-windows/d3d12.dll   the shim (Wine builtin)
#   x86_64-windows/apd12.dll   CrossOver's real d3d12, export name -> apd12.dll (what the shim loads)
#   x86_64-unix/apd12.so       symlink to CrossOver's d3d12.so
# Undo: tools/mac_setup_tsshim.sh --undo   (removes only this folder)
# The shim a rebuild replaces is kept once as $ENGINE/renderers/d3dmetal-tsshim-hb.d3d12.dll.pre-shadingrate.bak;
# tools/mac_setup_tsshim.sh --previous puts that one back. Every rebuild also keeps the shim it replaces as
# $ENGINE/renderers/d3dmetal-tsshim-hb.d3d12.dll.last.bak; tools/mac_setup_tsshim.sh --last puts that one back.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
ENGINE="$WORK/crossover-source/out-x64/engine"
CXWINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/apple_gptk/wine"
SHIM="$ENGINE/renderers/d3dmetal-tsshim-hb/wine"
mkdir -p "$REPO/out"; exec > >(tee "$REPO/out/setup-tsshim.log") 2>&1

BAK="$ENGINE/renderers/d3dmetal-tsshim-hb.d3d12.dll.pre-shadingrate.bak"
LAST="$ENGINE/renderers/d3dmetal-tsshim-hb.d3d12.dll.last.bak"
if [ "${1:-}" = "--undo" ]; then rm -rf "$ENGINE/renderers/d3dmetal-tsshim-hb" && echo "removed d3dmetal-tsshim-hb"; exit 0; fi
if [ "${1:-}" = "--previous" ]; then
    [ -f "$BAK" ] && [ -d "$SHIM/x86_64-windows" ] || { echo "STOP: no $BAK or no shim folder"; exit 1; }
    cp "$BAK" "$SHIM/x86_64-windows/d3d12.dll" && echo "previous shim restored from $BAK"; exit 0
fi
if [ "${1:-}" = "--last" ]; then
    [ -f "$LAST" ] && [ -d "$SHIM/x86_64-windows" ] || { echo "STOP: no $LAST or no shim folder"; exit 1; }
    cp "$LAST" "$SHIM/x86_64-windows/d3d12.dll.new" && mv -f "$SHIM/x86_64-windows/d3d12.dll.new" "$SHIM/x86_64-windows/d3d12.dll" \
        && echo "shim before the last rebuild restored from $LAST"; exit 0
fi

[ -f "$CXWINE/x86_64-windows/d3d12.dll" ] || { echo "STOP: CrossOver d3d12 not found at $CXWINE"; exit 1; }
[ -f "$CXWINE/x86_64-unix/d3d12.so" ]     || { echo "STOP: CrossOver d3d12.so not found at $CXWINE"; exit 1; }

# the PE cross compiler (llvm-mingw, called x86_64-w64-mingw32-gcc; its d3d12.h has the recent symbols)
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    CC=$(find "$WORK" /opt/homebrew /usr/local /opt -maxdepth 6 \( -name x86_64-w64-mingw32-gcc -o -name x86_64-w64-mingw32-clang \) \( -type f -o -type l \) 2>/dev/null | head -1)
    [ -n "$CC" ] || { echo "STOP: no mingw cross compiler found"; exit 1; }
    mkdir -p "$REPO/out/cross-bin"; ln -sf "$CC" "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc"
    export PATH="$REPO/out/cross-bin:$(dirname "$CC"):$PATH"; echo "using $CC"
fi

if [ -f "$SHIM/x86_64-windows/d3d12.dll" ] && [ ! -f "$BAK" ]; then
    cp "$SHIM/x86_64-windows/d3d12.dll" "$BAK" && echo "previous shim kept as $BAK"
fi
if [ -f "$SHIM/x86_64-windows/d3d12.dll" ]; then
    cp "$SHIM/x86_64-windows/d3d12.dll" "$LAST" && echo "shim being replaced kept as $LAST"
fi
rm -rf "$ENGINE/renderers/d3dmetal-tsshim-hb"
mkdir -p "$SHIM/x86_64-windows" "$SHIM/x86_64-unix"

echo "== build the shim"
x86_64-w64-mingw32-gcc -shared -O2 -Wall -static-libgcc -o "$SHIM/x86_64-windows/d3d12.dll" \
    "$REPO/tools/tsshim/d3d12.c" "$REPO/tools/tsshim/dxil_shadingrate.c" "$REPO/tools/tsshim/inspect.c" "$REPO/tools/tsshim/d3d12.def" || { echo "STOP: shim build failed (need a recent d3d12.h: llvm-mingw)"; exit 1; }
python3 "$REPO/tools/pe_tools.py" mark-builtin "$SHIM/x86_64-windows/d3d12.dll"

echo "== apd12 from CrossOver's d3d12 (the one that creates a device)"
cp "$CXWINE/x86_64-windows/d3d12.dll" "$SHIM/x86_64-windows/apd12.dll"
python3 "$REPO/tools/pe_tools.py" rename-export "$SHIM/x86_64-windows/apd12.dll" apd12.dll
python3 "$REPO/tools/pe_tools.py" mark-builtin "$SHIM/x86_64-windows/apd12.dll"
ln -sf "$CXWINE/x86_64-unix/d3d12.so" "$SHIM/x86_64-unix/apd12.so"

echo "== done"
shasum -a 256 "$SHIM/x86_64-windows/d3d12.dll" "$SHIM/x86_64-windows/apd12.dll" | cut -c1-20,65-
ls -l "$SHIM/x86_64-unix/apd12.so"
echo "shim ready; launch with FH6_CX_GPTK=1 FH6_D3DM4=1 (shim is used automatically)"
