#!/bin/bash
# Adds the unix-side fault report (tools/mac_trace_faults.py) to ntdll.so, rebuilds it and installs it in the engine
# with a backup. The new file replaces the old one by rename, so a game that is running keeps the copy it loaded.
# The report prints with WINEDEBUG=err+all (FH6_DEBUG="err+all,+loaddll"), on channel fh6fault.
# Undo: tools/mac_trace_faults.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
ENGINE="$WORK/crossover-source/out-x64/engine"
BUILD="$WORK/crossover-source/build-x64-cross"
F="$SRC/dlls/ntdll/unix/signal_x86_64.c"
INSTALLED="$ENGINE/lib/wine/x86_64-unix/ntdll.so"
BUILT="$BUILD/dlls/ntdll/ntdll.so"
install_file() { cp "$1" "$INSTALLED.new" && mv -f "$INSTALLED.new" "$INSTALLED"; }
if [ "${1:-}" = "--undo" ]; then
    cp "$F.pre-fh6-faulttrace.bak" "$F" && echo "signal_x86_64.c restored"
    install_file "$INSTALLED.pre-fh6-faulttrace.bak" && echo "ntdll.so restored"
    cp "$INSTALLED" "$BUILT"; touch "$F"; exit 0
fi
cmp -s "$BUILT" "$INSTALLED" || { echo "STOP: the built ntdll.so is not the installed one; rebuilding would change more than this report"; exit 1; }
[ -f "$F.pre-fh6-faulttrace.bak" ] || cp "$F" "$F.pre-fh6-faulttrace.bak"
[ -f "$INSTALLED.pre-fh6-faulttrace.bak" ] || cp "$INSTALLED" "$INSTALLED.pre-fh6-faulttrace.bak" || { echo "STOP: $INSTALLED missing"; exit 1; }
python3 "$REPO/tools/mac_trace_faults.py" "$F" || { echo "STOP"; exit 1; }
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
make -C "$BUILD" dlls/ntdll/ntdll.so > "$REPO/out/trace-faults-make.log" 2>&1 \
    || { grep -m8 "error" "$REPO/out/trace-faults-make.log"; echo "STOP: build failed (signal_x86_64.c kept patched; --undo restores it)"; exit 1; }
install_file "$BUILT" || exit 1
strings -a "$INSTALLED" | grep -c "fh6fault" | sed 's/^/fh6fault strings in the installed ntdll.so: /'
echo "== done"
