#!/bin/bash
# Build the x86_64 libraries Blackwell Engine dlopens at run time, which used to come from CrossOver.app's lib64:
# GnuTLS (with Nettle built in, as CrossOver ships it: it only needs GMP), GMP, FreeType, plus MoltenVK from its
# official release. They go into <engine>/lib with @loader_path install names, so the engine needs nothing else.
#   bash engine/build-deps.sh [engine folder] [work folder, default ~/BlackwellEngine-build]
# Without an engine folder (or with ""), only builds them into <work>/deps/prefix, where engine/build.sh links against
# them. A finished build is kept (deps/prefix/.built) until engine/inputs.json changes.
# Sources are pinned in engine/inputs.json ("deps"); files already in <work>/downloads are reused when their SHA-256 matches.
# Needs pkg-config (brew install pkgconf) for GnuTLS's configure.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ENG="$REPO/engine"
ENGINE="${1:-}"
W="${2:-$HOME/BlackwellEngine-build}"
P="$W/deps/prefix"
mkdir -p "$W/downloads" "$W/deps"

json() {
    python3 -I -c 'import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d = d[k]
print(d)' "$ENG/inputs.json" "$1"
}
fetch() {  # fetch <deps key>: the pinned tarball in downloads/, checked
    local url sha f
    url="$(json "deps.$1.url")"; sha="$(json "deps.$1.sha256")"; f="$W/downloads/$(basename "$url")"
    [ -f "$f" ] || curl -fL --retry 3 -o "$f.part" "$url" && { [ -f "$f" ] || mv "$f.part" "$f"; }
    [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$sha" ] || { echo "STOP: wrong SHA-256 for $f" >&2; exit 1; }
    echo "$f"
}
unpack() {  # unpack <deps key>: a clean source folder, printed
    local f d
    f="$(fetch "$1")"; d="$W/deps/$1"
    rm -rf "$d"; mkdir -p "$d"; tar -xf "$f" -C "$d" --strip-components 1
    echo "$d"
}
# clang targets arm64 even under arch -x86_64: ask for x86_64 explicitly; macOS 13 is Wine's own floor.
export CC="/usr/bin/clang -arch x86_64" CXX="/usr/bin/clang++ -arch x86_64"
export CFLAGS="-O2 -mmacosx-version-min=13.0" LDFLAGS="-mmacosx-version-min=13.0"
HOST=(--host=x86_64-apple-darwin --build=x86_64-apple-darwin --prefix="$P")
export PKG_CONFIG_PATH="$P/lib/pkgconfig" PKG_CONFIG_LIBDIR="$P/lib/pkgconfig"   # only what is built here
build() {  # build <name> <folder> <configure args...>: configure, make, install, log in deps/<name>.log
    local name="$1" dir="$2"; shift 2
    echo "== $name"
    ( cd "$dir" && arch -x86_64 ./configure "${HOST[@]}" "$@" && arch -x86_64 make -j"$(sysctl -n hw.ncpu)" \
        && arch -x86_64 make install ) > "$W/deps/$name.log" 2>&1 || { tail -30 "$W/deps/$name.log"; echo "STOP: $name failed"; exit 1; }
}

STAMP="$(python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["deps"], sort_keys=True))' "$ENG/inputs.json" | shasum -a 256 | cut -c1-16)"
if [ "$(cat "$P/.built" 2>/dev/null)" = "$STAMP" ]; then
    echo "== libraries already built in $P"
else
rm -rf "$P"
build gmp "$(unpack gmp)" --enable-shared --disable-static
build nettle "$(unpack nettle)" --disable-shared --enable-static --disable-documentation --disable-openssl \
    --with-include-path="$P/include" --with-lib-path="$P/lib"
GNUTLS_ENV=(NETTLE_CFLAGS="-I$P/include" NETTLE_LIBS="-L$P/lib -lnettle"
            HOGWEED_CFLAGS="-I$P/include" HOGWEED_LIBS="-L$P/lib -lhogweed -lgmp"
            GMP_CFLAGS="-I$P/include" GMP_LIBS="-L$P/lib -lgmp")
build gnutls "$(unpack gnutls)" --enable-shared --disable-static --with-included-libtasn1 --with-included-unistring \
    --without-p11-kit --without-idn --without-tpm --without-tpm2 --without-brotli --without-zstd --without-leancrypto \
    --disable-doc --disable-manpages --disable-tools --disable-tests --disable-cxx --disable-guile --disable-nls \
    --disable-libdane --disable-full-test-suite "${GNUTLS_ENV[@]}"
build freetype "$(unpack freetype)" --enable-shared --disable-static --without-png --without-harfbuzz \
    --without-brotli --without-bzip2

echo "== MoltenVK"
MVK="$W/deps/moltenvk"; rm -rf "$MVK"; mkdir -p "$MVK"
tar -xf "$(fetch moltenvk)" -C "$MVK" MoltenVK/LICENSE MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib
lipo "$MVK/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" -thin x86_64 -output "$P/lib/libMoltenVK.dylib"
echo "$STAMP" > "$P/.built"
fi
[ -n "$ENGINE" ] || { echo "libraries ready in $P"; exit 0; }
MVK="$W/deps/moltenvk"

echo "== into $ENGINE/lib"
LIBS=(libgmp.10.dylib libgnutls.30.dylib libfreetype.6.dylib libMoltenVK.dylib)
mkdir -p "$ENGINE/lib" "$ENGINE/share/licenses"
for l in "${LIBS[@]}"; do
    cp -L "$P/lib/$l" "$ENGINE/lib/$l"
    chmod 644 "$ENGINE/lib/$l"
    install_name_tool -id "@loader_path/$l" "$ENGINE/lib/$l" 2>/dev/null
    # dependencies on the build prefix become siblings
    for dep in $(otool -L "$ENGINE/lib/$l" | awk 'NR>1 {print $1}' | grep "^$P/lib/" || true); do
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$ENGINE/lib/$l" 2>/dev/null
    done
    codesign --force --sign - "$ENGINE/lib/$l" 2>/dev/null
done
cp "$MVK/MoltenVK/LICENSE" "$ENGINE/share/licenses/MoltenVK-LICENSE"
cp "$W/deps/gnutls/LICENSE" "$ENGINE/share/licenses/GnuTLS-LICENSE" 2>/dev/null || true
cp "$W/deps/gmp/COPYING.LESSERv3" "$ENGINE/share/licenses/GMP-COPYING.LESSERv3" 2>/dev/null || true
cp "$W/deps/nettle/COPYING.LESSERv3" "$ENGINE/share/licenses/Nettle-COPYING.LESSERv3" 2>/dev/null || true
cp "$W/deps/freetype/LICENSE.TXT" "$ENGINE/share/licenses/FreeType-LICENSE.TXT" 2>/dev/null || true

echo "== checks"
for l in "${LIBS[@]}"; do
    lipo -archs "$ENGINE/lib/$l" | grep -qx x86_64 || { echo "STOP: $l is not x86_64 only"; exit 1; }
    if otool -L "$ENGINE/lib/$l" | awk 'NR>1 {print $1}' | grep -v -E '^(@loader_path|/usr/lib|/System)'; then
        echo "STOP: $l links outside the engine and the system"; exit 1
    fi
    echo "  $l ok"
done
