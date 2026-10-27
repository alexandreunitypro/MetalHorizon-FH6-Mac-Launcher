#!/bin/bash
# Runs tools/fontprobe with the game's Wine and prefix (no game), plus the +font trace, to see why
# dialogs get 0x0 base units (message boxes drawn as a thin pill). Changes nothing.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
export CX_ROOT="$ENGINE" WINEPREFIX="$HOME/FH6/.blackwell-wine" WINEDEBUG="err+all,warn+font,+font"
export DYLD_LIBRARY_PATH="$ENGINE/lib:/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64"
"$ENGINE/bin/wineserver" -k 2>/dev/null
"$ENGINE/bin/wine" "$REPO/tools/fontprobe/fontprobe.exe" > "$REPO/out/fontprobe.log" 2>&1
grep -v ":font:\|FHTRACE" "$REPO/out/fontprobe.log" | grep -v "^[0-9a-f]*:fixme" | head -30
echo "== font trace (errors, FreeType, directories)"
grep -i "freetype\|err:font\|load_directory\|data_dir\|warn:font" "$REPO/out/fontprobe.log" | awk '!s[$0]++' | head -15
echo "== font lib: $(ls "$ENGINE"/lib/libfreetype* /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64/libfreetype* 2>/dev/null | head -3 | tr '\n' ' ')"
"$ENGINE/bin/wineserver" -k 2>/dev/null
echo "== is FreeType compiled into win32u.so?"
strings "$ENGINE/lib/wine/x86_64-unix/win32u.so" | grep -i "freetype" | head -3
strings /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/win32u.so | grep -i "freetype" | head -3 | sed 's/^/CrossOver: /'
grep -i "^ *#define SONAME_LIBFREETYPE\|HAVE_FT2BUILD" /Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/build-x64-cross/include/config.h
