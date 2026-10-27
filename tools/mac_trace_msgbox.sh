#!/bin/bash
# Adds the FH6 message-box diagnostic to user32.dll, rebuilds and installs it (backup first).
# Undo: tools/mac_trace_msgbox.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
ENGINE="$WORK/crossover-source/out-x64/engine"
BUILD="$WORK/crossover-source/build-x64-cross"
F="$SRC/dlls/user32/msgbox.c"
INSTALLED="$ENGINE/lib/wine/x86_64-windows/user32.dll"
if [ "${1:-}" = "--undo" ]; then
    cp "$F.pre-fh6-msgbox.bak" "$F" && cp "$INSTALLED.pre-fh6-msgbox.bak" "$INSTALLED" && echo "restored"; exit 0
fi
[ -f "$F.pre-fh6-msgbox.bak" ] || cp "$F" "$F.pre-fh6-msgbox.bak"
[ -f "$INSTALLED.pre-fh6-msgbox.bak" ] || cp "$INSTALLED" "$INSTALLED.pre-fh6-msgbox.bak"
python3 "$REPO/tools/mac_trace_msgbox.py" "$F" || exit 1
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    CC=$(find "$WORK" /opt/homebrew /usr/local /opt -maxdepth 6 \( -name x86_64-w64-mingw32-gcc -o -name x86_64-w64-mingw32-clang \) \( -type f -o -type l \) 2>/dev/null | head -1)
    [ -n "$CC" ] || { echo "STOP: no mingw cross compiler found"; exit 1; }
    mkdir -p "$REPO/out/cross-bin"; ln -sf "$CC" "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc"
    export PATH="$REPO/out/cross-bin:$(dirname "$CC"):$PATH"
fi
make -C "$BUILD" dlls/user32/x86_64-windows/user32.dll >/dev/null || { echo "STOP: build failed"; make -C "$BUILD" dlls/user32/x86_64-windows/user32.dll 2>&1 | grep -m5 error; exit 1; }
cp "$BUILD/dlls/user32/x86_64-windows/user32.dll" "$INSTALLED" && echo "user32.dll installed, done"
