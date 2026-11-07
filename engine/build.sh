#!/bin/bash
# Build Blackwell Engine, MetalHorizon's Wine, from the pinned sources (engine/inputs.json), the patch series
# (engine/series) and its own x86_64 run-time libraries (engine/build-deps.sh) into <work>/out/engine. Nothing from
# CrossOver.app is used. engine/package.sh then adds the DirectX 12 shim and makes the tarball the app installs.
# Everything happens inside the work folder: the engine the game runs on today is not touched.
#   bash engine/build.sh [--variant xbox|steam] [--source-only] [--tarball <crossover-sources-26.3.0.tar.gz>]
#                        [--series <file>] [work folder]
# Work folder: ~/BlackwellEngine-build by default. --source-only stops once the patches are applied
# (engine/verify-series.sh uses it). Files already in <work>/downloads are reused when their SHA-256 matches.
# --variant (inputs.json "variants"): xbox (default) is x86_64 only with llvm-mingw; steam adds the 32-bit half
# Steam's installer and client need, builds the PE side with mingw-w64 gcc as Highball does (llvm-mingw breaks
# Steam's login), and adds DXMT, the renderer Steam's own window draws with. --series overrides the variant's series.
# Use a different work folder for each variant: they do not share $W/out.
# --resume: keep <work>/src and <work>/build (after fixing a source by hand) and go on from make; a release is built
# without it, from scratch.
# Needs: an Apple silicon Mac with Rosetta (the engine is x86_64), Xcode Command Line Tools, Python 3, bison 3,
# pkg-config and cmake (brew install bison pkgconf cmake), and for the steam variant mingw-w64 (brew install mingw-w64).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENG="$REPO/engine"
SOURCE_ONLY=0; TARBALL=""; SERIES_FILE=""; VARIANT="xbox"; RESUME=0
while [ $# -gt 0 ]; do
    case "$1" in
        --source-only) SOURCE_ONLY=1 ;;
        --tarball) TARBALL="$2"; shift ;;
        --series) SERIES_FILE="$2"; shift ;;
        --variant) VARIANT="$2"; shift ;;
        --resume) RESUME=1 ;;
        -*) echo "unknown option $1"; exit 2 ;;
        *) break ;;
    esac
    shift
done
W="${1:-$HOME/BlackwellEngine-build}"
mkdir -p "$W/downloads"

json() {  # json <key.path>: a value of engine/inputs.json (lists come out space-separated)
    python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d[k]
print(" ".join(d) if isinstance(d, list) else d)' "$ENG/inputs.json" "$1"
}
fetch() {  # fetch <inputs key> <file>: download unless already there, then check the SHA-256
    local url sha
    url="$(json "$1.url")"; sha="$(json "$1.sha256")"
    if [ ! -f "$2" ]; then
        echo "  download $url"
        curl -fL --retry 3 -o "$2.part" "$url" && mv "$2.part" "$2"
    fi
    [ "$(shasum -a 256 "$2" | cut -d' ' -f1)" = "$sha" ] || { echo "STOP: wrong SHA-256 for $2"; exit 1; }
}

ARCHS="$(json "variants.$VARIANT.archs")"; PE="$(json "variants.$VARIANT.pe")"
DXMT="$(python3 -I -c 'import json,sys; print(1 if json.load(open(sys.argv[1]))["variants"][sys.argv[2]].get("dxmt") else 0)' "$ENG/inputs.json" "$VARIANT")"
[ -n "$SERIES_FILE" ] || SERIES_FILE="$(json "variants.$VARIANT.series")"
echo "== variant $VARIANT: series $SERIES_FILE, archs $ARCHS, PE compiler $PE, DXMT $DXMT"

SRC="$W/src/$(json wine.subdir)"
if [ "$RESUME" = 1 ]; then
    [ -f "$W/build/Makefile" ] || { echo "STOP: nothing to resume in $W/build"; exit 1; }
    echo "== resuming in $W/build (sources and configure kept)"
    rm -rf "$W/out"
    SERIES_SHA="$(cd "$ENG" && cat "$SERIES_FILE" patches/*.patch | shasum -a 256 | cut -d' ' -f1)"
else
echo "== 1. sources"
SRC_TGZ="${TARBALL:-$W/downloads/$(basename "$(json wine.url)")}"
fetch wine "$SRC_TGZ"
rm -rf "$W/src"; mkdir -p "$W/src"
tar -xzf "$SRC_TGZ" -C "$W/src" "$(json wine.subdir)"
SRC="$W/src/$(json wine.subdir)"

echo "== 2. patch series ($SERIES_FILE)"
while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    echo "  $p"
    patch -p1 -d "$SRC" --forward --batch --quiet < "$ENG/patches/$p" \
        || { echo "STOP: $p does not apply"; exit 1; }
done < "$ENG/$SERIES_FILE"
find "$SRC" -name '*.orig' -delete
SERIES_SHA="$(cd "$ENG" && cat "$SERIES_FILE" patches/*.patch | shasum -a 256 | cut -d' ' -f1)"
echo "  series fingerprint $SERIES_SHA"
if [ "$SOURCE_ONLY" = 1 ]; then echo "patched sources: $SRC"; exit 0; fi
fi

echo "== 3. toolchain"
# llvm-mingw is fetched for both variants: engine/package.sh compiles the DirectX 12 shim with it.
LM_TXZ="$W/downloads/$(basename "$(json llvm-mingw.url)")"
fetch llvm-mingw "$LM_TXZ"
LM="$W/toolchains/$(basename "$LM_TXZ" .tar.xz)"
[ -x "$LM/bin/x86_64-w64-mingw32-clang" ] || { mkdir -p "$W/toolchains"; tar -xJf "$LM_TXZ" -C "$W/toolchains"; }
if [ "$PE" = "mingw-w64" ]; then
    command -v x86_64-w64-mingw32-gcc >/dev/null && command -v i686-w64-mingw32-gcc >/dev/null \
        || { echo "STOP: mingw-w64 gcc needed for the $VARIANT variant (brew install mingw-w64)"; exit 1; }
    # The 32-bit side gets SSE2 maths as Windows' own DLLs do (GCC's i686 default is x87, which Rosetta runs
    # slowly), and realigns its stack where it spills: Windows only promises 4 bytes on i386. Highball's flags.
    PE_FLAGS=(CROSSCC=x86_64-w64-mingw32-gcc x86_64_CC=x86_64-w64-mingw32-gcc i386_CC=i686-w64-mingw32-gcc
              "i386_CFLAGS=-g -O2 -msse2 -mfpmath=sse -mincoming-stack-boundary=2")
else
    PE_FLAGS=(x86_64_CC=x86_64-w64-mingw32-clang i386_CC=i686-w64-mingw32-clang)
fi
BISON_DIR=/opt/homebrew/opt/bison/bin
[ -x "$BISON_DIR/bison" ] || BISON_DIR="$(dirname "$(command -v bison)")"
"$BISON_DIR/bison" --version | head -1 | grep -q ' 3\.' || { echo "STOP: bison 3 needed (brew install bison)"; exit 1; }
echo "  llvm-mingw $LM, bison $BISON_DIR"
echo "== 3b. x86_64 GnuTLS, GMP, FreeType, MoltenVK (engine/build-deps.sh)"
bash "$ENG/build-deps.sh" "" "$W" | sed 's/^/  /'
P="$W/deps/prefix"
FT_INC="$P/include/freetype2" GT_INC="$P/include"
if [ "$PE" = "mingw-w64" ]; then
    export PATH="$BISON_DIR:$PATH"            # mingw-w64 gcc from Homebrew; llvm-mingw stays off the PATH
else
    # Only llvm-mingw's cross tools, first in the PATH: Homebrew's mingw-w64 gcc (for the steam variant) must not
    # stand in for them, and llvm-mingw's own plain clang must not stand in for Apple's.
    XB="$W/toolchains/llvm-mingw-cross-bin"; rm -rf "$XB"; mkdir -p "$XB"
    for t in "$LM"/bin/x86_64-w64-mingw32-* "$LM"/bin/i686-w64-mingw32-*; do ln -s "$t" "$XB/$(basename "$t")"; done
    export PATH="$XB:$BISON_DIR:$PATH"
fi

if [ "$RESUME" != 1 ]; then
echo "== 4. configure (x86_64, under Rosetta; log $W/configure.log)"
rm -rf "$W/build" "$W/out"; mkdir -p "$W/build"
# shellcheck disable=SC2046  # the flags are meant to split
# clang targets arm64 even under arch -x86_64: the Unix half is asked for x86_64 explicitly.
( cd "$W/build" && arch -x86_64 "$SRC/configure" --prefix="$W/out/engine" --enable-archs="$ARCHS" $(json configure) \
    CC="/usr/bin/clang -arch x86_64" CXX="/usr/bin/clang++ -arch x86_64" "${PE_FLAGS[@]}" ) > "$W/configure.log" 2>&1 \
    || { tail -30 "$W/configure.log"; echo "STOP: configure failed"; exit 1; }

echo "== 5. FreeType, GnuTLS, MoltenVK and SDL2 in config.h, as in the working engine"
# Wine dlopens these libraries by name at run time; the names stay bare (not the build prefix's paths) so the
# copies in the engine's lib/ are found. These are the defines tools/mac_enable_freetype.sh and
# tools/mac_enable_gnutls.sh wrote into the working engine.
python3 -I - "$W/build/include/config.h" "$W/build/Makefile" "$FT_INC" "$GT_INC" <<'PY'
import os, re, sys
cfg, mk, ft, gt = sys.argv[1:5]
c = open(cfg).read()
def define(name, value):
    global c
    if "#define %s " % name in c:
        return
    pat = "/* #undef %s */" % name
    if pat not in c:
        sys.exit("config.h has no %s" % name)
    c = c.replace(pat, "#define %s %s" % (name, value))
    print("  #define %s %s" % (name, value))
define("HAVE_FT2BUILD_H", "1")
define("SONAME_LIBFREETYPE", '"libfreetype.6.dylib"')
for full, part in re.findall(r"/\* #undef (HAVE_FREETYPE_(\w+)_H) \*/", c):
    if os.path.exists(os.path.join(ft, "freetype", part.lower() + ".h")):
        define(full, "1")
define("SONAME_LIBGNUTLS", '"libgnutls.30.dylib"')
define("HAVE_GNUTLS_CIPHER_INIT", "1")
define("SONAME_LIBMOLTENVK", '"libMoltenVK.dylib"')
define("SONAME_LIBVULKAN", '"libMoltenVK.dylib"')
# winebus.sys reads controllers through SDL2 (bus_sdl.c) as well as IOKit: every pad SDL knows, mapped to XInput.
define("SONAME_LIBSDL2", '"libSDL2-2.0.0.dylib"')
define("HAVE_SDL_H", "1")
open(cfg, "w").write(c)
PY
# The include paths go on make's command line: make regenerates the Makefile and would drop an edit there.
# FREETYPE_LIBS: tools/sfnt2fon links FreeType to make the bitmap fonts.
fi
HEADERS=(FREETYPE_CFLAGS="-I$FT_INC" FREETYPE_LIBS="-L$P/lib -lfreetype" GNUTLS_CFLAGS="-I$GT_INC" GNUTLS_LIBS="-L$P/lib -lgnutls"
         SDL2_CFLAGS="-I$P/include/SDL2 -D_THREAD_SAFE")

echo "== 6. build (log $W/make.log)"
( cd "$W/build" && arch -x86_64 make -j"$(sysctl -n hw.ncpu)" "${HEADERS[@]}" ) > "$W/make.log" 2>&1 \
    || { grep -n -m20 -E 'error:|Error [0-9]' "$W/make.log"; echo "STOP: build failed"; exit 1; }
( cd "$W/build" && arch -x86_64 make install-lib "${HEADERS[@]}" ) > "$W/install.log" 2>&1 \
    || { tail -20 "$W/install.log"; echo "STOP: install failed"; exit 1; }

echo "== 7. the libraries into the engine, and checks"
E="$W/out/engine"
bash "$ENG/build-deps.sh" "$E" "$W" | sed 's/^/  /' 
fail() { echo "STOP: $1"; exit 1; }
[ -x "$E/bin/wine" ] || fail "no bin/wine"
[ -f "$E/lib/wine/x86_64-windows/xgameruntime.dll" ] || fail "no xgameruntime.dll"
strings -a "$E/lib/wine/x86_64-unix/win32u.so" | grep libfreetype.6.dylib >/dev/null || fail "win32u.so without FreeType"
strings -a "$E/lib/wine/x86_64-unix/bcrypt.so" | grep libgnutls.30.dylib >/dev/null || fail "bcrypt.so without GnuTLS"
strings -a "$E/lib/wine/x86_64-unix/winebus.so" | grep libSDL2-2.0.0.dylib >/dev/null || fail "winebus.so without SDL2"
case ",$ARCHS," in *,i386,*)
    [ -f "$E/lib/wine/i386-windows/ntdll.dll" ] || fail "no 32-bit half (lib/wine/i386-windows)"
    [ -f "$E/lib/wine/x86_64-windows/wow64.dll" ] || fail "no wow64.dll"
    echo "  32-bit half: $(ls "$E/lib/wine/i386-windows" | wc -l | tr -d ' ') files" ;;
esac
if [ "$PE" = "mingw-w64" ]; then
    # gcc keeps its debug information in the PE files, 5 to 7 times their size; the loader needs none of it.
    find "$E/lib/wine" \( -path '*-windows/*' \) -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' \
        -o -name '*.cpl' -o -name '*.ocx' -o -name '*.acm' -o -name '*.tlb' \) -print0 \
        | xargs -0 -n 50 x86_64-w64-mingw32-strip --strip-debug 2>/dev/null || true
fi
if [ "$DXMT" = 1 ]; then
    # DXMT as a renderer overlay (renderers/dxmt/wine, put first in WINEDLLPATH_PREPEND for Steam's window only),
    # and its winemetal.dll as an engine built-in too: Wine loads a built-in from an overlay only when the prefix
    # has a placeholder for it, and wineboot writes placeholders for the engine's own built-ins (Highball's build.yml).
    DXMT_TGZ="$W/downloads/$(basename "$(json dxmt.url)")"
    fetch dxmt "$DXMT_TGZ"
    rm -rf "$W/dxmt" "$E/renderers/dxmt"; mkdir -p "$W/dxmt" "$E/renderers/dxmt/wine"
    tar -xzf "$DXMT_TGZ" -C "$W/dxmt" --strip-components 1
    for d in x86_64-windows i386-windows; do
        mkdir -p "$E/renderers/dxmt/wine/$d"
        for f in d3d11.dll dxgi.dll d3d10core.dll winemetal.dll; do cp "$W/dxmt/$d/$f" "$E/renderers/dxmt/wine/$d/"; done
        cp "$W/dxmt/$d/winemetal.dll" "$E/lib/wine/$d/winemetal.dll"
    done
    mkdir -p "$E/renderers/dxmt/wine/x86_64-unix"; cp "$W/dxmt/x86_64-unix/winemetal.so" "$E/renderers/dxmt/wine/x86_64-unix/"
    LIC="$W/downloads/dxmt-LICENSE"
    [ -f "$LIC" ] || curl -fsSL -o "$LIC" "$(json dxmt.license)"
    [ "$(shasum -a 256 "$LIC" | cut -d' ' -f1)" = "$(json dxmt.licenseSha256)" ] || fail "wrong DXMT licence file"
    cp "$LIC" "$E/share/licenses/DXMT-LICENSE"
    echo "  DXMT $(json dxmt.name) in renderers/dxmt"
fi
if ! ls "$E/share/wine/fonts/"*.ttf >/dev/null 2>&1; then
    mkdir -p "$E/share/wine/fonts" && cp "$SRC/fonts/"*.ttf "$E/share/wine/fonts/"
    echo "  fonts copied from the source tree"
fi
echo "  $(arch -x86_64 "$E/bin/wine" --version), $(ls "$E/share/wine/fonts" | wc -l | tr -d ' ') fonts, $(du -sh "$E" | cut -f1)"

echo "== 8. ready"
echo "$SERIES_SHA" > "$E/.series-sha256"
echo "engine: $E"
echo "next: bash engine/package.sh <version> $W"
