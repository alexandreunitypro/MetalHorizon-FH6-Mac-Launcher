#!/bin/bash
# The game loads C:\windows\system32\<dll> from the Wine PREFIX (~/FH6/.blackwell-wine), and the prefix keeps its own
# full copy of some builtin DLLs. A DLL rebuilt into the engine (lib/wine/x86_64-windows) is therefore ignored until
# the prefix copy is replaced. Found with xgameruntime.dll: prefix copy 707535 bytes (old), engine copy 1458176.
#   bash tools/mac_sync_prefix_dll.sh                      report only: same / DIFFERENT for the DLLs we patched
#   bash tools/mac_sync_prefix_dll.sh --apply xgameruntime copy the engine DLL(s) named into the prefix (backup kept)
#   bash tools/mac_sync_prefix_dll.sh --undo               put the backed-up prefix DLLs back
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
ENGINE="$WORK/crossover-source/out-x64/engine/lib/wine/x86_64-windows"
PFX="${FH6_PREFIX:-$HOME/FH6/.blackwell-wine}/drive_c/windows/system32"
NAMES="xgameruntime kernelbase kernel32 advapi32 ntdll mmdevapi bcrypt secur32 crypt32 user32 win32u winemac.drv"
mkdir -p "$REPO/out"; exec > >(tee "$REPO/out/sync-prefix-dll.log") 2>&1
[ -d "$PFX" ] || { echo "STOP: $PFX not found"; exit 1; }

if [ "${1:-}" = "--undo" ]; then
    for f in "$PFX"/*.pre-sync.bak; do [ -f "$f" ] && cp "$f" "${f%.pre-sync.bak}" && echo "restored $(basename "${f%.pre-sync.bak}")"; done
    exit 0
fi

echo "== prefix: $PFX"
for n in $NAMES; do
    f="${n%.drv}"; case "$n" in *.drv) f="$n";; *) f="$n.dll";; esac
    e="$ENGINE/$f"; p="$PFX/$f"
    [ -f "$e" ] || { echo "$f: no engine copy"; continue; }
    [ -f "$p" ] || { echo "$f: not in the prefix (loaded from the engine)"; continue; }
    if cmp -s "$e" "$p"; then echo "$f: same"; else echo "$f: DIFFERENT (prefix $(stat -f %z "$p") bytes, engine $(stat -f %z "$e") bytes)"; fi
done

if [ "${1:-}" = "--apply" ]; then
    shift
    [ $# -gt 0 ] || { echo "STOP: name the DLLs to copy, e.g. --apply xgameruntime"; exit 1; }
    echo "== apply"
    for n in "$@"; do
        case "$n" in *.drv|*.dll) f="$n";; *) f="$n.dll";; esac
        [ -f "$ENGINE/$f" ] && [ -f "$PFX/$f" ] || { echo "$f: skipped (missing)"; continue; }
        [ -f "$PFX/$f.pre-sync.bak" ] || cp "$PFX/$f" "$PFX/$f.pre-sync.bak"
        cp "$ENGINE/$f" "$PFX/$f" && echo "$f: copied (backup $f.pre-sync.bak)"
    done
fi
