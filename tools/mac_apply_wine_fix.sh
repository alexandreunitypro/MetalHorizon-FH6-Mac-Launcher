#!/bin/bash
# Applies patches/wine/0001 to the Blackwell CrossOver-based Wine, rebuilds ntdll.so only,
# installs it with a backup, and re-runs the probe. Stops at the first problem.
# Undo: tools/mac_apply_wine_fix.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
ENGINE="$WORK/crossover-source/out-x64/engine"
INSTALLED="$ENGINE/lib/wine/x86_64-unix/ntdll.so"
BACKUP="$INSTALLED.pre-fh6-reopen.bak"
PATCH="$REPO/patches/wine/0001-ntdll-macos-reopen-mapped-image-by-path.patch"
mkdir -p "$REPO/out"
LOG="$REPO/out/apply-wine-fix.log"
exec > >(tee "$LOG") 2>&1

if [ "${1:-}" = "--undo" ]; then
    [ -f "$BACKUP" ] && cp "$BACKUP" "$INSTALLED" && echo "ntdll.so restored"
    L="$SRC/dlls/ntdll/unix/loader.c"
    [ -f "$L.pre-fh6-reopen.bak" ] && cp "$L.pre-fh6-reopen.bak" "$L" && echo "source restored"
    exit 0
fi

echo "== 1. which build directory produced the installed ntdll.so"
INST_SHA=$(shasum -a 256 "$INSTALLED" | cut -d' ' -f1); echo "installed $INST_SHA"
BUILD=""
for b in build-x64-cross build-x64; do
    f="$WORK/crossover-source/$b/dlls/ntdll/ntdll.so"
    [ -f "$f" ] || continue
    s=$(shasum -a 256 "$f" | cut -d' ' -f1); echo "$b $s"
    [ "$s" = "$INST_SHA" ] && BUILD="$WORK/crossover-source/$b"
done
if [ -z "$BUILD" ]; then
    for b in build-x64-cross build-x64; do [ -f "$WORK/crossover-source/$b/Makefile" ] && BUILD="$WORK/crossover-source/$b" && break; done
    echo "no exact match; using $BUILD"
fi
echo "BUILD=$BUILD"

echo "== 2. backup"
[ -f "$BACKUP" ] || cp "$INSTALLED" "$BACKUP"
ls -la "$INSTALLED" "$BACKUP" || exit 1

echo "== 3. patch (replace mapped_fd_to_handle in loader.c)"
L="$SRC/dlls/ntdll/unix/loader.c"
if grep -q "reopen_mapped_fd" "$L"; then
    echo "already applied"
else
    [ -f "$L.pre-fh6-reopen.bak" ] || cp "$L" "$L.pre-fh6-reopen.bak"
    python3 "$REPO/tools/mac_replace_mapped_fd.py" "$L" || { echo "STOP: could not edit loader.c"; exit 1; }
fi

echo "== 4. build ntdll.so"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
echo "SDKROOT=$SDKROOT"
make -C "$BUILD" dlls/ntdll/ntdll.so || { echo "STOP: build failed"; exit 1; }
grep -q "cannot be reopened" "$BUILD/dlls/ntdll/ntdll.so" || { echo "STOP: built ntdll.so lacks the fix"; exit 1; }

echo "== 5. install"
cp "$BUILD/dlls/ntdll/ntdll.so" "$INSTALLED" || exit 1
python3 "$REPO/tools/check_runtime.py" "$ENGINE" | grep -A1 "F_GETPATH"

echo "== 6. probe (named = what fixed xodus will do)"
python3 "$REPO/tools/mapfd_run.py" --wine "$ENGINE/bin/wine" --fd-kind named \
    --log "$REPO/out/probe-after-named.txt" 2>&1 | grep -E "^(PASS|FAIL|RESULT)|cannot be reopened"
echo "== done, log in $LOG"
