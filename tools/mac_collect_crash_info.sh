#!/bin/bash
# Collects, read-only, the Wine/xodus source and log excerpts needed to analyse the FH6 crash
# (page fault, "forzahorizon6.exe:4" opens, exit 0x12c, double WINE_DLL_FILE_MAP entry).
# Writes out/crash-info.txt. Changes nothing.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
WINE="$WORK/crossover-source/sources/wine"
LOG="$REPO/out/fh6-after.log"
OUT="$REPO/out/crash-info.txt"
mkdir -p "$REPO/out"
{
echo "== wine: open_mapped_image_file / GLOBALROOT / section name"
grep -rn "open_mapped_image_file\|GlobalRoot\|GLOBALROOT\|get_memory_section_name\|WINE_DLL_FILE_MAP" \
    "$WINE/dlls/ntdll/unix/"*.c "$WINE/server/"*.c 2>/dev/null | head -60
for f in "$WINE/dlls/ntdll/unix/file.c" "$WINE/dlls/ntdll/unix/loader.c" "$WINE/dlls/ntdll/unix/virtual.c"; do
    for fn in open_mapped_image_file get_memory_section_name; do
        n=$(grep -n "^[a-zA-Z].*$fn *(" "$f" 2>/dev/null | head -1 | cut -d: -f1)
        [ -n "$n" ] && echo "---- $f:$n $fn" && sed -n "$n,$((n+80))p" "$f"
    done
done
echo "== xodus: WINE_DLL_FILE_MAP construction"
grep -rn -B3 -A12 "WINE_DLL_FILE_MAP" "$WORK/xodus/crates" 2>/dev/null | head -120
echo "== log: key lines"
grep -n "WINE_DLL_FILE_MAP\|page fault\|exe:4\|GLOBALROOT\|0x12c\|c0000098\|section_name\|Exception\|xgameruntime" "$LOG" | cut -c1-400 | head -80
echo "== log: 150 lines before the page fault"
n=$(grep -n "page fault" "$LOG" | head -1 | cut -d: -f1)
[ -n "$n" ] && sed -n "$((n>150?n-150:1)),$((n+40))p" "$LOG" | cut -c1-400
} > "$OUT" 2>&1
# hide user paths' secrets: none expected, but drop anything that looks like a token
sed -i '' -E 's/(gh[pousr]_|github_pat_)[A-Za-z0-9_]+/<token removed>/g' "$OUT"
echo "OK -> $OUT ($(wc -l < "$OUT") lignes)"
