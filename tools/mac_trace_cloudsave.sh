#!/bin/bash
# Make the "Game Saves / Cloud save synchronization failed" box say WHY. In dlls/xgameruntime/pfxgamesave.c,
# ui_failed() receives the sync state and an HRESULT from the game's PlayFab save engine but shows the box
# without logging either. This adds one WARN line (debug channel gdkc) and rebuilds only xgameruntime.dll.
# Log line to look for:  "cloud save sync failed: state N, hr 0x..."   (run with warn+gdkc)
# Backups: pfxgamesave.c.pre-cloudtrace.bak and the installed xgameruntime.dll.pre-cloudtrace.bak
# Undo:   tools/mac_trace_cloudsave.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
BUILD="$WORK/crossover-source/build-x64-cross"
ENGINE="$WORK/crossover-source/out-x64/engine"
F="$SRC/dlls/xgameruntime/pfxgamesave.c"
INST="$ENGINE/lib/wine/x86_64-windows/xgameruntime.dll"
mkdir -p "$REPO/out"; exec > >(tee "$REPO/out/trace-cloudsave.log") 2>&1

if [ "${1:-}" = "--undo" ]; then
    for f in "$F" "$INST"; do [ -f "$f.pre-cloudtrace.bak" ] && cp "$f.pre-cloudtrace.bak" "$f" && echo "restored $(basename "$f")"; done
    exit 0
fi

[ -f "$F" ] || { echo "STOP: $F not found"; exit 1; }
if grep -q "cloud save sync failed" "$F"; then echo "already patched in the source"; else
    for f in "$F" "$INST"; do [ -f "$f" ] && { [ -f "$f.pre-cloudtrace.bak" ] || cp "$f" "$f.pre-cloudtrace.bak"; echo "saved $(basename "$f")"; }; done
    python3 - "$F" <<'PY' || { echo "STOP: edit failed"; exit 1; }
import sys
p = sys.argv[1]
s = open(p).read()
old = "    int response;\n    if (!c) { api.response[1](user, 0); return; }\n"
new = ("    int response;\n"
       "    WARN(\"cloud save sync failed: state %u, hr %#lx, known config %d.\\n\", (unsigned)state, (long)error, c != NULL);\n"
       "    if (!c) { api.response[1](user, 0); return; }\n")
assert s.count(old) == 1, "ui_failed text not found exactly once"
open(p, "w").write(s.replace(old, new))
PY
fi
grep -n "cloud save sync failed" "$F" || { echo "STOP: patch missing"; exit 1; }

export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    CC=$(find "$WORK" /opt/homebrew /usr/local /opt -maxdepth 6 \( -name x86_64-w64-mingw32-gcc -o -name x86_64-w64-mingw32-clang \) \( -type f -o -type l \) 2>/dev/null | head -1)
    [ -n "$CC" ] || { echo "STOP: no mingw cross compiler"; exit 1; }
    mkdir -p "$REPO/out/cross-bin"; ln -sf "$CC" "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc"
    export PATH="$REPO/out/cross-bin:$(dirname "$CC"):$PATH"
fi
echo "== build xgameruntime"
touch "$F"   # the plain "dlls/xgameruntime" target did nothing; name the real file
make -C "$BUILD" dlls/xgameruntime/x86_64-windows/xgameruntime.dll > "$REPO/out/trace-cloudsave-make.log" 2>&1 \
    || { echo "STOP: build failed"; grep -m5 -E "error|Error" "$REPO/out/trace-cloudsave-make.log"; exit 1; }
BUILT="$BUILD/dlls/xgameruntime/x86_64-windows/xgameruntime.dll"
[ -f "$BUILT" ] || BUILT="$(find "$BUILD/dlls/xgameruntime" -name xgameruntime.dll | head -1)"
[ -n "$BUILT" ] && [ -f "$BUILT" ] || { echo "STOP: built xgameruntime.dll not found"; exit 1; }
cp "$BUILT" "$INST" && echo "installed $INST"
strings -a "$INST" | grep -c "cloud save sync failed" | sed 's/^/trace string in installed dll: /'
echo "== done"
