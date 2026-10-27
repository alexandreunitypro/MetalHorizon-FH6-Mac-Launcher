#!/bin/bash
# Adds the FH6 null-call diagnostic to the unix ntdll.so, rebuilds and installs it (backup first).
# Undo: tools/mac_trace_null_call.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
ENGINE="$WORK/crossover-source/out-x64/engine"
BUILD="$WORK/crossover-source/build-x64-cross"
F="$SRC/dlls/ntdll/unix/signal_x86_64.c"
INSTALLED="$ENGINE/lib/wine/x86_64-unix/ntdll.so"
if [ "${1:-}" = "--undo" ]; then
    cp "$F.pre-fh6-nullcall.bak" "$F" && cp "$INSTALLED.pre-fh6-nullcall.bak" "$INSTALLED" && echo "restored"; exit 0
fi
[ -f "$F.pre-fh6-nullcall.bak" ] || cp "$F" "$F.pre-fh6-nullcall.bak"
[ -f "$INSTALLED.pre-fh6-nullcall.bak" ] || cp "$INSTALLED" "$INSTALLED.pre-fh6-nullcall.bak"
python3 "$REPO/tools/mac_trace_null_call.py" "$F" || exit 1
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
make -C "$BUILD" dlls/ntdll/ntdll.so >/dev/null || { echo "STOP: build failed"; make -C "$BUILD" dlls/ntdll/ntdll.so 2>&1 | grep -m5 error; exit 1; }
cp "$BUILD/dlls/ntdll/ntdll.so" "$INSTALLED" && echo "ntdll.so installed, done"
