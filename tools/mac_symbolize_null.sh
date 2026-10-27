#!/bin/bash
# Names the functions around the NULL call found in out/fh6-after.log ("FH6 null call" lines),
# with atos, and lists what that host library links to. Read-only.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
L="$REPO/out/fh6-small.log"; [ -s "$L" ] || L="$REPO/out/fh6-after.log"
grep "FH6 null call" "$L" | head -12 | while read -r line; do
    addr=$(echo "$line" | sed -E 's/.*stack\[[0-9]+\]=(0x[0-9a-f]+) .*/\1/')
    file=$(echo "$line" | sed -E 's/.*stack\[[0-9]+\]=0x[0-9a-f]+ (.*)\+0x[0-9a-f]+.*/\1/')
    off=$(echo "$line" | sed -E 's/.*\+(0x[0-9a-f]+).*/\1/')
    case "$file" in */apple_gptk/*|*renderers*|*d3d*|*D3D*) ;; *) continue;; esac
    base=$(printf "0x%x" $((addr - off)))
    echo "$(basename "$file") +$off -> $(atos -o "$file" -l "$base" "$addr" 2>/dev/null)"
    echo "$file" >> "$REPO/out/null-libs.txt"
done
f=$(sort -u "$REPO/out/null-libs.txt" 2>/dev/null | head -1); rm -f "$REPO/out/null-libs.txt"
[ -n "$f" ] || { echo "no graphics library in the null-call lines"; exit 0; }
echo "== file: ${f#*/out-x64/engine/}"
echo "== links to:"; otool -L "$f" | tail -n +2 | sed 's/ (.*//'
echo "== names it looks up at run time (dlsym candidates):"
strings -a "$f" | grep -E '^(__wine_|wine_|ntdll_|NtUser|NtGdi|unix_|macdrv_|D3DM|MTL)[A-Za-z0-9_]+$' | sort -u | head -40
