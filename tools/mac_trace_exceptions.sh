#!/bin/bash
# Adds the first-chance exception trace (tools/mac_trace_exceptions.py) to ntdll's exception.c, rebuilds the PE
# ntdll.dll and installs it in the engine, with backups. The game loads ntdll.dll from the engine (build_ntdll_module),
# not from the prefix. The trace prints with WINEDEBUG=err+all (FH6_DEBUG="err+all,+loaddll"), on channel fh6exc.
# Undo: tools/mac_trace_exceptions.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
ENGINE="$WORK/crossover-source/out-x64/engine"
BUILD="$WORK/crossover-source/build-x64-cross"
E="$SRC/dlls/ntdll/exception.c"
INSTALLED="$ENGINE/lib/wine/x86_64-windows/ntdll.dll"
BUILT="$BUILD/dlls/ntdll/x86_64-windows/ntdll.dll"
if [ "${1:-}" = "--undo" ]; then
    cp "$E.pre-fh6-exctrace.bak" "$E" && echo "exception.c restored"
    cp "$INSTALLED.pre-fh6-exctrace.bak" "$INSTALLED" && echo "ntdll.dll restored"
    cp "$INSTALLED" "$BUILT"   # the build output matches the installed DLL again, so a later run of this script may rebuild
    touch "$E"; exit 0
fi
cmp -s "$BUILT" "$INSTALLED" || { echo "STOP: the built ntdll.dll is not the installed one; rebuilding would change more than this trace"; exit 1; }
[ -f "$E.pre-fh6-exctrace.bak" ] || cp "$E" "$E.pre-fh6-exctrace.bak"
[ -f "$INSTALLED.pre-fh6-exctrace.bak" ] || cp "$INSTALLED" "$INSTALLED.pre-fh6-exctrace.bak" || { echo "STOP: $INSTALLED missing"; exit 1; }
python3 "$REPO/tools/mac_trace_exceptions.py" "$E" || { echo "STOP"; exit 1; }
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    [ -x "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc" ] || { echo "STOP: no cross compiler (run tools/mac_fix_vectored_trace.sh once)"; exit 1; }
    export PATH="$REPO/out/cross-bin:$PATH"
fi
make -C "$BUILD" dlls/ntdll/x86_64-windows/ntdll.dll > "$REPO/out/trace-exceptions-make.log" 2>&1 \
    || { tail -20 "$REPO/out/trace-exceptions-make.log"; echo "STOP: build failed (exception.c kept patched; --undo restores it)"; exit 1; }
cp "$BUILT" "$INSTALLED" || exit 1
strings -a "$INSTALLED" | grep -c "fh6exc" | sed 's/^/fh6exc strings in the installed ntdll.dll: /'
echo "== done"
