#!/bin/bash
# Turn FreeType on in the self-built Wine so message boxes and every Wine dialog draw their text.
# Cause (proved by tools/fontprobe): config.h has `#undef HAVE_FT2BUILD_H`, so win32u's font engine is not
# compiled in and GDI sees 0 font families (GetDialogBaseUnits = 0, buttons drawn empty).
#
# This Wine is x86_64 (Rosetta). Headers come from FreeType's official source (downloaded, checksum checked, only the include folder is kept in $WORK/freetype-headers); the
# library is CrossOver.app's x86_64 libfreetype in lib64 (Wine dlopens it at run time, SONAME_LIBFREETYPE).
#
# What it does, in order, stopping at the first problem:
#   1. find ft2build.h (Homebrew's if present, else download FreeType 2.13.3's include folder)
#   2. back up include/config.h, Makefile and the installed win32u.so
#   3. edit config.h (HAVE_FT2BUILD_H, SONAME_LIBFREETYPE) and the Makefile (FREETYPE_CFLAGS) in place:
#      re-running configure needs bison 3, and macOS ships 2.3
#   4. check config.h now defines HAVE_FT2BUILD_H and SONAME_LIBFREETYPE
#   5. rebuild dlls/win32u/win32u.so and install it
# Undo:   tools/mac_enable_freetype.sh --undo
# Report: tools/mac_enable_freetype.sh --check   (changes nothing)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
BUILD="$WORK/crossover-source/build-x64-cross"
ENGINE="$WORK/crossover-source/out-x64/engine"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
CFG="$BUILD/include/config.h"
INST="$ENGINE/lib/wine/x86_64-unix/win32u.so"
mkdir -p "$REPO/out"; exec > >(tee "$REPO/out/enable-freetype.log") 2>&1

if [ "${1:-}" = "--undo" ]; then
    for f in "$CFG" "$BUILD/Makefile" "$BUILD/config.status" "$INST"; do
        [ -f "$f.pre-freetype.bak" ] && cp "$f.pre-freetype.bak" "$f" && echo "restored $(basename "$f")"
    done
    exit 0
fi

have_ft() { grep -q "^#define HAVE_FT2BUILD_H 1" "$CFG" 2>/dev/null; }

echo "== state"
if have_ft; then echo "config.h: HAVE_FT2BUILD_H is defined"; else echo "config.h: FreeType NOT enabled"; fi
grep -E "SONAME_LIBFREETYPE" "$CFG" 2>/dev/null || echo "config.h: no SONAME_LIBFREETYPE"

echo "== library (x86_64, for Wine to dlopen)"
FTLIB=$(ls "$CX"/lib64/libfreetype.6.dylib "$CX"/lib/libfreetype.6.dylib 2>/dev/null | head -1)
[ -n "$FTLIB" ] && { echo "$FTLIB"; file "$FTLIB" | sed 's/^[^:]*: //'; } || echo "no libfreetype in CrossOver.app"

echo "== headers (ft2build.h)"
FTINC=""
find_inc() {
    for d in "$WORK"/freetype-headers/*/include /opt/homebrew/include/freetype2 /usr/local/include/freetype2 \
             /opt/local/include/freetype2; do
        [ -f "$d/ft2build.h" ] && { FTINC="$d"; return 0; }
    done
    return 1
}
# Wine only needs the headers (it dlopens CrossOver's libfreetype at run time), so no Homebrew and no
# build: fetch the official FreeType 2.13.3 source, check its SHA-256, and keep only its include folder.
FT_VER=2.13.3
FT_SHA=0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289
fetch_headers() {
    local dst="$WORK/freetype-headers" tgz="$WORK/freetype-headers/freetype-$FT_VER.tar.xz" u
    mkdir -p "$dst"
    for u in "https://download.savannah.gnu.org/releases/freetype/freetype-$FT_VER.tar.xz" \
             "https://sourceforge.net/projects/freetype/files/freetype2/$FT_VER/freetype-$FT_VER.tar.xz/download" \
             "https://download-mirror.savannah.gnu.org/releases/freetype/freetype-$FT_VER.tar.xz"; do
        rm -f "$tgz"
        curl -fsSL --max-time 180 -o "$tgz" "$u" 2>/dev/null || continue
        [ "$(shasum -a 256 "$tgz" | cut -d' ' -f1)" = "$FT_SHA" ] || { echo "bad checksum from $u, trying the next source"; continue; }
        tar -xJf "$tgz" -C "$dst" "freetype-$FT_VER/include" && { echo "headers from $u"; rm -f "$tgz"; return 0; }
    done
    return 1
}
find_inc
if [ -z "$FTINC" ]; then
    if [ "${1:-}" = "--check" ]; then
        echo "no header found; the real run will download FreeType $FT_VER's include folder (about 2.6 MB, checksum verified)"
    else
        echo "no header found; downloading FreeType $FT_VER (checksum verified), keeping only include/"
        fetch_headers && find_inc
    fi
fi
[ -n "$FTINC" ] && echo "$FTINC" || { [ "${1:-}" = "--check" ] && echo "(not yet)" || { echo "STOP: could not get ft2build.h"; exit 1; }; }

[ "${1:-}" = "--check" ] && { echo "== check only: nothing changed"; exit 0; }
# "enabled" means the INSTALLED win32u.so carries FreeType, not just that config.h was edited: an earlier
# run can edit config.h and then fail to build, and that must not count as done.
if strings -a "$INST" | grep -q "libfreetype"; then echo "already enabled: the installed win32u.so loads libfreetype"; exit 0; fi
have_ft && echo "config.h is already edited (earlier run); going straight to the rebuild"
[ -n "$FTLIB" ] || { echo "STOP: no x86_64 libfreetype"; exit 1; }

echo "== backups"
for f in "$CFG" "$BUILD/Makefile" "$BUILD/config.status" "$INST"; do
    [ -f "$f" ] && { [ -f "$f.pre-freetype.bak" ] || cp "$f" "$f.pre-freetype.bak"; echo "saved $(basename "$f")"; }
done

echo "== edit config.h and the Makefile directly (no configure: this Mac's bison is too old for it)"
# These are exactly the three things configure writes when it finds FreeType: HAVE_FT2BUILD_H (+ the
# optional HAVE_FREETYPE_*_H headers), SONAME_LIBFREETYPE, and FREETYPE_CFLAGS in the Makefile.
grep -q "^FREETYPE_CFLAGS" "$BUILD/Makefile" || { echo "STOP: no FREETYPE_CFLAGS line in $BUILD/Makefile"; exit 1; }
grep -q "FREETYPE_CFLAGS" "$SRC/dlls/win32u/Makefile.in" || echo "WARN: win32u/Makefile.in does not mention FREETYPE_CFLAGS"
python3 - "$CFG" "$BUILD/Makefile" "$FTINC" "$(basename "$FTLIB")" <<'PY' || { echo "STOP: edit failed"; exit 1; }
import os, re, sys
cfg, mk, inc, soname = sys.argv[1:5]
c = open(cfg).read()
def define(c, name, value):
    pat = "/* #undef %s */" % name
    return c.replace(pat, "#define %s %s" % (name, value)) if pat in c else c
c = define(c, "HAVE_FT2BUILD_H", "1")
c = define(c, "SONAME_LIBFREETYPE", '"%s"' % soname)
for m in re.findall(r"/\* #undef (HAVE_FREETYPE_(\w+)_H) \*/", c):
    hdr = os.path.join(inc, "freetype", m[1].lower() + ".h")
    if os.path.exists(hdr):
        c = define(c, m[0], "1"); print("  also", m[0])
open(cfg, "w").write(c)
t = open(mk).read()
t2 = re.sub(r"(?m)^FREETYPE_CFLAGS\s*=.*$", "FREETYPE_CFLAGS = -I" + inc, t)
assert t2 != t or ("-I" + inc) in t, "FREETYPE_CFLAGS not changed"
open(mk, "w").write(t2)
PY
echo "== config.h now"
grep -E "HAVE_FT2BUILD_H|SONAME_LIBFREETYPE|HAVE_FREETYPE_" "$CFG"
have_ft || { echo "STOP: HAVE_FT2BUILD_H still not defined"; exit 1; }
grep -E "^FREETYPE_CFLAGS" "$BUILD/Makefile"
touch "$SRC/dlls/win32u/freetype.c"     # force a rebuild even if dependency tracking misses config.h

echo "== rebuild win32u"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"   # math.h and friends live in the SDK
echo "SDKROOT=$SDKROOT"
# The Makefile's FREETYPE_CFLAGS is not on the compile line of win32u/freetype.c in this tree ("ft2build.h
# not found"), so also give the compiler the header folder through CPATH (clang adds it like -I).
export CPATH="$FTINC${CPATH:+:$CPATH}"
echo "CPATH=$CPATH"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    CC=$(find "$WORK" /opt/homebrew /usr/local /opt -maxdepth 6 \( -name x86_64-w64-mingw32-gcc -o -name x86_64-w64-mingw32-clang \) \( -type f -o -type l \) 2>/dev/null | head -1)
    [ -n "$CC" ] && { mkdir -p "$REPO/out/cross-bin"; ln -sf "$CC" "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc"; export PATH="$REPO/out/cross-bin:$(dirname "$CC"):$PATH"; }
fi
make -C "$BUILD" dlls/win32u/win32u.so > "$REPO/out/enable-freetype-make.log" 2>&1 \
    || { echo "STOP: build failed"; grep -m5 -E "error|Error" "$REPO/out/enable-freetype-make.log"; exit 1; }
cp "$BUILD/dlls/win32u/win32u.so" "$INST" && echo "installed $INST"

echo "== is FreeType in the new win32u.so?"
strings -a "$INST" | grep -m3 -i "libfreetype" || echo "(no libfreetype string: FreeType not compiled in)"
echo "== done; test: bash tools/mac_font_probe.sh   (want GetDialogBaseUnits != 0 and families > 0)"
