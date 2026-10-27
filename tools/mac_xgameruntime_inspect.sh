#!/bin/bash
# Read-only. What is the Xbox layer ("xgameruntime") this Wine runs, what does it implement for sign-in and
# cloud saves, and what does the game folder ship next to it? Result in out/xgr-inspect.txt and the clipboard.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"; ENGINE="$WORK/crossover-source/out-x64/engine"; GAME="$HOME/FH6"
mkdir -p "$REPO/out"
{
echo "== files named xgameruntime in the engine"
find "$ENGINE" -iname '*xgameruntime*' 2>/dev/null | sed "s#$ENGINE/##"
echo "== in the Wine source tree"
find "$SRC/dlls" -maxdepth 1 -iname '*xgame*' -o -maxdepth 1 -iname '*gaming*' -o -maxdepth 1 -iname '*xbox*' 2>/dev/null | sed "s#$SRC/##"
grep -rl "xgameruntime" "$SRC/dlls" --include=Makefile.in --include=*.spec 2>/dev/null | sed "s#$SRC/##" | head -5
echo "== DLLs the game ships (names only)"
ls "$GAME" 2>/dev/null | grep -iE '\.dll$' | tr '\n' ' '; echo
echo "== Xbox/GDK related files in the game folder"
ls "$GAME" 2>/dev/null | grep -iE 'xcurl|httpclient|xbox|xal|gdk|gaming|xgame|gameinput|microsoft|MicrosoftGame|appxmanifest|\.xml$' | head -20
for f in "$ENGINE"/lib/wine/x86_64-unix/xgameruntime.so "$ENGINE"/lib/wine/x86_64-windows/xgameruntime.dll; do
  [ -f "$f" ] || continue
  echo "== strings in $(basename "$f") ($(wc -c < "$f") bytes): sign-in / cloud save / http related"
  strings -a "$f" | grep -iE 'XUser|XGameSave|XStore|XblContext|ConnectedStorage|CloudSave|xboxlive|login\.live|sisu|device.?code|XSTS|title.?token|user.?token|not implemented|unimplemented|stub|FIXME|TODO' | sort -u | head -60
done
echo "== debug channel name used by the Xbox layer"
grep -rh "WINE_DEFAULT_DEBUG_CHANNEL" "$SRC"/dlls/xgameruntime* 2>/dev/null | head -2
echo "== which Xbox-ish functions the game binary can reach: exports of the builtin"
for f in "$ENGINE"/lib/wine/x86_64-unix/xgameruntime.so; do [ -f "$f" ] && nm -gU "$f" 2>/dev/null | awk '{print $3}' | head -60; done
echo "== what the last game log said about it"
grep -iE "xgameruntime|XUser|XGameSave|xboxlive|sign.?in" "$REPO/out/fh6-small.log" "$REPO/out/fh6-after.log" 2>/dev/null | grep -v FHTRACE | cut -c1-170 | awk '!s[$0]++' | head -15
} > "$REPO/out/xgr-inspect.txt" 2>&1
pbcopy < "$REPO/out/xgr-inspect.txt"; wc -l < "$REPO/out/xgr-inspect.txt" | sed 's/^/lignes: /'; echo "COPIE OK - va dans le chat et fais Cmd+V"
