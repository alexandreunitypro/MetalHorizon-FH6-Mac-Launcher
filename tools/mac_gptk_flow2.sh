#!/bin/bash
# Read-only: control flow of D3DMetal's init in the d3d12.so the game used, plus the unix-call table.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
E="${ENGINE:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine}"
D="$E/lib64/apple_gptk/wine/x86_64-unix/d3d12.so"
otool -tvV "$D" | python3 "$REPO/tools/mac_gptk_flow2.py"
echo "== __wine_unix_call_funcs entries"
dyld_info -fixups "$D" 2>/dev/null | python3 -c '
import sys,re
rows=sys.stdin.read().splitlines()
print("\n".join(r for r in rows if re.search(r"Init|Patch|unix_call", r))[:3000])'
