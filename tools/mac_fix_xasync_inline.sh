#!/bin/bash
# Runtime calls in xgameruntime complete after they return, as on Windows, and no completion routine that is not code
# is called (tools/mac_fix_xasync_inline.py). Rebuilds xgameruntime.dll and installs it in the engine AND in the
# prefix (the game loads the prefix copy, see tools/mac_sync_prefix_dll.sh), each with a backup, by rename so a running
# game keeps the copy it loaded. XGR_INLINE_COMPLETIONS=1 at launch restores the old behaviour without reinstalling.
# Undo: tools/mac_fix_xasync_inline.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
BUILD="$WORK/crossover-source/build-x64-cross"
F="$SRC/dlls/xgameruntime/xthreading.c"
BUILT="$BUILD/dlls/xgameruntime/x86_64-windows/xgameruntime.dll"
ENGINE_DLL="$WORK/crossover-source/out-x64/engine/lib/wine/x86_64-windows/xgameruntime.dll"
PREFIX_DLL="$HOME/FH6/.blackwell-wine/drive_c/windows/system32/xgameruntime.dll"
BAK=".pre-fh6-xasyncdefer.bak"
put() { cp "$1" "$2.new" && mv -f "$2.new" "$2"; }
if [ "${1:-}" = "--undo" ]; then
    cp "$F$BAK" "$F" && echo "xthreading.c restored"
    put "$ENGINE_DLL$BAK" "$ENGINE_DLL" && echo "engine xgameruntime.dll restored"
    put "$PREFIX_DLL$BAK" "$PREFIX_DLL" && echo "prefix xgameruntime.dll restored"
    cp "$ENGINE_DLL" "$BUILT"; touch "$F"; exit 0
fi
cmp -s "$BUILT" "$ENGINE_DLL" && cmp -s "$ENGINE_DLL" "$PREFIX_DLL" \
    || { echo "STOP: built, engine and prefix xgameruntime.dll differ; rebuilding would change more than this fix"; exit 1; }
[ -f "$F$BAK" ] || cp "$F" "$F$BAK"
[ -f "$ENGINE_DLL$BAK" ] || cp "$ENGINE_DLL" "$ENGINE_DLL$BAK"
[ -f "$PREFIX_DLL$BAK" ] || cp "$PREFIX_DLL" "$PREFIX_DLL$BAK"
python3 "$REPO/tools/mac_fix_xasync_inline.py" "$F" || { echo "STOP"; exit 1; }
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then export PATH="$REPO/out/cross-bin:$PATH"; fi
make -C "$BUILD" dlls/xgameruntime/x86_64-windows/xgameruntime.dll > "$REPO/out/fix-xasync-make.log" 2>&1 \
    || { grep -m8 "error" "$REPO/out/fix-xasync-make.log"; echo "STOP: build failed (xthreading.c kept patched; --undo restores it)"; exit 1; }
put "$BUILT" "$ENGINE_DLL" && put "$BUILT" "$PREFIX_DLL" || exit 1
strings -a "$PREFIX_DLL" | grep -c "XGR_INLINE_COMPLETIONS" | sed 's/^/marker in the prefix xgameruntime.dll: /'
echo "== done"
