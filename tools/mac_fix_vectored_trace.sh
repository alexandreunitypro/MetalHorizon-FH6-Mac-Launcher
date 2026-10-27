#!/bin/bash
# Makes the local FHTRACE stack dump in ntdll's call_vectored_handlers stay inside the stack,
# rebuilds the PE ntdll.dll, installs it with a backup. Undo: tools/mac_fix_vectored_trace.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
ENGINE="$WORK/crossover-source/out-x64/engine"
BUILD="$WORK/crossover-source/build-x64-cross"
E="$SRC/dlls/ntdll/exception.c"
INSTALLED="$ENGINE/lib/wine/x86_64-windows/ntdll.dll"
if [ "${1:-}" = "--undo" ]; then
    cp "$INSTALLED.pre-fh6-trace.bak" "$INSTALLED" && echo "ntdll.dll restored"
    cp "$E.pre-fh6-trace.bak" "$E" && echo "exception.c restored"; exit 0
fi
[ -f "$E.pre-fh6-trace.bak" ] || cp "$E" "$E.pre-fh6-trace.bak"
[ -f "$INSTALLED.pre-fh6-trace.bak" ] || cp "$INSTALLED" "$INSTALLED.pre-fh6-trace.bak" || { echo "STOP: $INSTALLED missing"; exit 1; }
python3 "$REPO/tools/mac_fix_vectored_trace.py" "$E" || { echo "STOP"; exit 1; }
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
# the PE cross compiler the build was configured with (named x86_64-w64-mingw32-gcc, flags are clang's)
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    CC=$(find "$WORK" /opt/homebrew /usr/local /opt -maxdepth 6 \( -name x86_64-w64-mingw32-gcc -o -name x86_64-w64-mingw32-clang \) \( -type f -o -type l \) 2>/dev/null | head -1)
    [ -n "$CC" ] || { echo "STOP: no mingw cross compiler found"; exit 1; }
    mkdir -p "$REPO/out/cross-bin"; ln -sf "$CC" "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc"
    for t in ar ranlib dlltool strip; do
        f="$(dirname "$CC")/x86_64-w64-mingw32-$t"; [ -e "$f" ] && ln -sf "$f" "$REPO/out/cross-bin/"
        f="$(dirname "$CC")/llvm-$t"; [ -e "$f" ] && ln -sf "$f" "$REPO/out/cross-bin/x86_64-w64-mingw32-$t"
    done
    export PATH="$REPO/out/cross-bin:$(dirname "$CC"):$PATH"; echo "using $CC"
fi
make -C "$BUILD" dlls/ntdll/x86_64-windows/ntdll.dll || { echo "STOP: build failed"; exit 1; }
cp "$BUILD/dlls/ntdll/x86_64-windows/ntdll.dll" "$INSTALLED" || exit 1
shasum -a 256 "$INSTALLED" "$INSTALLED.pre-fh6-trace.bak"
echo "== done"
