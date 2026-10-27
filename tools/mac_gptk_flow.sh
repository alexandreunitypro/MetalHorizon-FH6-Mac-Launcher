#!/bin/bash
# Read-only wrapper: disassemble the d3d12.so the game uses and summarize its init flow.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
E="${ENGINE:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine}"
D="$E/lib/wine/x86_64-unix/d3d12.so"; [ -f "$D" ] || D="$E/lib64/apple_gptk/wine/x86_64-unix/d3d12.so"
echo "file: ${D#$E/}"
echo "== exports"; nm -gU "$D" | awk '{print $3}' | grep -v GFXTEventInterface | tr '\n' ' '; echo
otool -tvV "$D" | python3 "$REPO/tools/mac_gptk_flow.py"
