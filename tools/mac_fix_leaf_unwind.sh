#!/bin/bash
# Leaf-unwind fix in the PE ntdll (see mac_fix_leaf_unwind.py), then rebuild/install ntdll.dll.
# Undo: tools/mac_fix_leaf_unwind.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
F=$(grep -l "calling personality routine in system library\|fh6: leaf unwind" "$SRC"/dlls/ntdll/signal_x86_64.c "$SRC"/dlls/ntdll/unwind.c 2>/dev/null | head -1)
[ -n "$F" ] || { echo "STOP: message not found in PE ntdll"; grep -rln "calling personality routine in system library" "$SRC/dlls/ntdll"; exit 1; }
if [ "${1:-}" = "--undo" ]; then cp "$F.pre-fh6-leaf.bak" "$F" && echo "restored $F"; exit 0; fi
[ -f "$F.pre-fh6-leaf.bak" ] || cp "$F" "$F.pre-fh6-leaf.bak"
python3 "$REPO/tools/mac_fix_leaf_unwind.py" "$F" || {
    n=$(grep -n "calling personality routine in system library" "$F" | head -1 | cut -d: -f1)
    sed -n "$((n-40)),$((n+10))p" "$F"; exit 1; }
bash "$REPO/tools/mac_fix_vectored_trace.sh"
