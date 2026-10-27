#!/bin/bash
# Build Blackwell Engine, MetalHorizon's Wine, from the pinned sources (engine/inputs.json), the patch series
# (engine/series) and its own x86_64 run-time libraries (engine/build-deps.sh) into <work>/out/engine. Nothing from
# CrossOver.app is used. engine/package.sh then adds the DirectX 12 shim and makes the tarball the app installs.
# Everything happens inside the work folder: the engine the game runs on today is not touched.
#   bash engine/build.sh [--source-only] [--tarball <crossover-sources-26.3.0.tar.gz>] [work folder]
# Work folder: ~/BlackwellEngine-build by default. --source-only stops once the patches are applied
# (engine/verify-series.sh uses it). Files already in <work>/downloads are reused when their SHA-256 matches.
# Needs: an Apple silicon Mac with Rosetta (the engine is x86_64), Xcode Command Line Tools, Python 3, bison 3
# and pkg-config (brew install bison pkgconf).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENG="$REPO/engine"
SOURCE_ONLY=0; TARBALL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source-only) SOURCE_ONLY=1 ;;
        --tarball) TARBALL="$2"; shift ;;
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

echo "== 1. sources"
SRC_TGZ="${TARBALL:-$W/downloads/$(basename "$(json wine.url)")}"
fetch wine "$SRC_TGZ"
rm -rf "$W/src"; mkdir -p "$W/src"
tar -xzf "$SRC_TGZ" -C "$W/src" "$(json wine.subdir)"
SRC="$W/src/$(json wine.subdir)"

echo "== 2. patch series"
while IFS= read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    echo "  $p"
    patch -p1 -d "$SRC" --forward --batch --quiet < "$ENG/patches/$p" \
        || { echo "STOP: $p does not apply"; exit 1; }
done < "$ENG/series"
find "$SRC" -name '*.orig' -delete
SERIES_SHA="$(cd "$ENG" && cat series patches/*.patch | shasum -a 256 | cut -d' ' -f1)"
echo "  series fingerprint $SERIES_SHA"
if [ "$SOURCE_ONLY" = 1 ]; then echo "patched sources: $SRC"; exit 0; fi

echo "== 3. toolchain"
LM_TXZ="$W/downloads/$(basename "$(json llvm-mingw.url)")"
fetch llvm-mingw "$LM_TXZ"
LM="$W/toolchains/$(basename "$LM_TXZ" .tar.xz)"
[ -x "$LM/bin/x86_64-w64-mingw32-clang" ] || { mkdir -p "$W/toolchains"; tar -xJf "$LM_TXZ" -C "$W/toolchains"; }
BISON_DIR=/opt/homebrew/opt/bison/bin
[ -x "$BISON_DIR/bison" ] || BISON_DIR="$(dirname "$(command -v bison)")"
"$BISON_DIR/bison" --version | head -1 | grep -q ' 3\.' || { echo "STOP: bison 3 needed (brew install bison)"; exit 1; }
echo "  llvm-mingw $LM, bison $BISON_DIR"
echo "== 3b. x86_64 GnuTLS, GMP, FreeType, MoltenVK (engine/build-deps.sh)"
bash "$ENG/build-deps.sh" "" "$W" | sed 's/^/  /'
P="$W/deps/prefix"
FT_INC="$P/include/freetype2" GT_INC="$P/include"
export PATH="$BISON_DIR:$PATH:$LM/bin"   # llvm-mingw last: it has a clang of its own

echo "== 4. configure (x86_64, under Rosetta; log $W/configure.log)"
rm -rf "$W/build" "$W/out"; mkdir -p "$W/build"
# shellcheck disable=SC2046  # the flags are meant to split
# clang targets arm64 even under arch -x86_64: the Unix half is asked for x86_64 explicitly.
( cd "$W/build" && arch -x86_64 "$SRC/configure" --prefix="$W/out/engine" $(json configure) \
    CC="/usr/bin/clang -arch x86_64" CXX="/usr/bin/clang++ -arch x86_64" x86_64_CC=x86_64-w64-mingw32-clang ) > "$W/configure.log" 2>&1 \
    || { tail -30 "$W/configure.log"; echo "STOP: configure failed"; exit 1; }

echo "== 5. FreeType, GnuTLS and MoltenVK in config.h, as in the working engine"
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
open(cfg, "w").write(c)
PY
# The include paths go on make's command line: make regenerates the Makefile and would drop an edit there.
# FREETYPE_LIBS: tools/sfnt2fon links FreeType to make the bitmap fonts.
HEADERS=(FREETYPE_CFLAGS="-I$FT_INC" FREETYPE_LIBS="-L$P/lib -lfreetype" GNUTLS_CFLAGS="-I$GT_INC" GNUTLS_LIBS="-L$P/lib -lgnutls")

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
if ! ls "$E/share/wine/fonts/"*.ttf >/dev/null 2>&1; then
    mkdir -p "$E/share/wine/fonts" && cp "$SRC/fonts/"*.ttf "$E/share/wine/fonts/"
    echo "  fonts copied from the source tree"
fi
echo "  $(arch -x86_64 "$E/bin/wine" --version), $(ls "$E/share/wine/fonts" | wc -l | tr -d ' ') fonts, $(du -sh "$E" | cut -f1)"

echo "== 8. ready"
echo "$SERIES_SHA" > "$E/.series-sha256"
echo "engine: $E"
echo "next: bash engine/package.sh <version> $W"
