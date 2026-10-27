#!/bin/bash
# Turn GnuTLS on in the self-built Wine so bcrypt/secur32/crypt32 get asymmetric crypto and TLS.
# Cause (seen in the FH6 log): "err:bcrypt:key_asymmetric_create no encryption support" (45x) -- config.h has
# `#undef SONAME_LIBGNUTLS`, so bcrypt.so/secur32.so are built without GnuTLS and the PlayFab cloud save sync
# (HTTPS + signed requests) fails, which is what the "Game Saves / Cloud save synchronization failed" box says.
#
# Same method as tools/mac_enable_freetype.sh: Wine only needs the HEADERS at build time and dlopens the
# x86_64 libgnutls.30.dylib from CrossOver.app at run time (the launcher already puts CrossOver's lib64 on
# DYLD_LIBRARY_PATH). Headers come from Homebrew's gnutls (brew install gnutls).
#   1. find gnutls/gnutls.h   2. back up config.h, Makefile and the installed .so files
#   3. edit config.h (SONAME_LIBGNUTLS, HAVE_GNUTLS_CIPHER_INIT) and the Makefile (GNUTLS_CFLAGS)
#   4. rebuild bcrypt.so / secur32.so / crypt32.so (the ones that use GnuTLS) and install them
# Undo:   tools/mac_enable_gnutls.sh --undo
# Report: tools/mac_enable_gnutls.sh --check
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
BUILD="$WORK/crossover-source/build-x64-cross"
ENGINE="$WORK/crossover-source/out-x64/engine"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
CFG="$BUILD/include/config.h"
UNIX="$ENGINE/lib/wine/x86_64-unix"
mkdir -p "$REPO/out"; exec > >(tee "$REPO/out/enable-gnutls.log") 2>&1

if [ "${1:-}" = "--undo" ]; then
    for f in "$CFG" "$BUILD/Makefile" "$UNIX/bcrypt.so" "$UNIX/secur32.so" "$UNIX/crypt32.so"; do
        [ -f "$f.pre-gnutls.bak" ] && cp "$f.pre-gnutls.bak" "$f" && echo "restored $(basename "$f")"
    done
    exit 0
fi

echo "== state"
grep -E "SONAME_LIBGNUTLS|HAVE_GNUTLS_CIPHER_INIT" "$CFG" || echo "config.h: no GNUTLS lines"
for n in bcrypt secur32 crypt32; do
    printf "%s.so mentions gnutls: " "$n"; strings -a "$UNIX/$n.so" 2>/dev/null | grep -ci gnutls
done

echo "== library (x86_64, loaded by Wine at run time)"
LIB="$CX/lib64/libgnutls.30.dylib"
[ -f "$LIB" ] && file "$LIB" | sed 's/^[^:]*: //' || { echo "STOP: $LIB not found"; exit 1; }

echo "== headers (gnutls/gnutls.h)"
INC=""
for d in /opt/homebrew/include /usr/local/include /opt/local/include; do
    [ -f "$d/gnutls/gnutls.h" ] && { INC="$d"; break; }
done
if [ -z "$INC" ]; then
    echo "no gnutls.h found. Install it first:  brew install gnutls"
    echo "(it is only used for the headers; Wine loads CrossOver's x86_64 library)"
    exit 1
fi
echo "$INC"
for h in crypto abstract pkcs12 x509; do [ -f "$INC/gnutls/$h.h" ] || echo "WARN: $INC/gnutls/$h.h missing"; done

[ "${1:-}" = "--check" ] && { echo "== check only: nothing changed"; exit 0; }

# "enabled" means the INSTALLED bcrypt.so carries GnuTLS, not just that config.h was edited
if strings -a "$UNIX/bcrypt.so" | grep -q "libgnutls"; then echo "already enabled: the installed bcrypt.so loads libgnutls"; exit 0; fi

echo "== backups"
for f in "$CFG" "$BUILD/Makefile" "$UNIX/bcrypt.so" "$UNIX/secur32.so" "$UNIX/crypt32.so"; do
    [ -f "$f" ] && { [ -f "$f.pre-gnutls.bak" ] || cp "$f" "$f.pre-gnutls.bak"; echo "saved $(basename "$f")"; }
done

echo "== edit config.h and the Makefile directly (no configure: this Mac's bison is too old for it)"
grep -q "^GNUTLS_CFLAGS" "$BUILD/Makefile" || { echo "STOP: no GNUTLS_CFLAGS line in $BUILD/Makefile"; exit 1; }
python3 - "$CFG" "$BUILD/Makefile" "$INC" <<'PY' || { echo "STOP: edit failed"; exit 1; }
import re, sys
cfg, mk, inc = sys.argv[1:4]
c = open(cfg).read()
def define(c, name, value):
    pat = "/* #undef %s */" % name
    return c.replace(pat, "#define %s %s" % (name, value)) if pat in c else c
c = define(c, "SONAME_LIBGNUTLS", '"libgnutls.30.dylib"')
c = define(c, "HAVE_GNUTLS_CIPHER_INIT", "1")
open(cfg, "w").write(c)
t = open(mk).read()
t2 = re.sub(r"(?m)^GNUTLS_CFLAGS\s*=.*$", "GNUTLS_CFLAGS = -I" + inc, t)
assert t2 != t or ("-I" + inc) in t, "GNUTLS_CFLAGS not changed"
open(mk, "w").write(t2)
PY
echo "== config.h now"
grep -E "SONAME_LIBGNUTLS|HAVE_GNUTLS_CIPHER_INIT" "$CFG"
grep -q '^#define SONAME_LIBGNUTLS' "$CFG" || { echo "STOP: SONAME_LIBGNUTLS still not defined"; exit 1; }
grep -E "^GNUTLS_CFLAGS" "$BUILD/Makefile"

echo "== rebuild"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export CPATH="$INC${CPATH:+:$CPATH}"   # also on the compile line, like for FreeType
echo "SDKROOT=$SDKROOT"; echo "CPATH=$CPATH"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    CC=$(find "$WORK" /opt/homebrew /usr/local /opt -maxdepth 6 \( -name x86_64-w64-mingw32-gcc -o -name x86_64-w64-mingw32-clang \) \( -type f -o -type l \) 2>/dev/null | head -1)
    [ -n "$CC" ] && { mkdir -p "$REPO/out/cross-bin"; ln -sf "$CC" "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc"; export PATH="$REPO/out/cross-bin:$(dirname "$CC"):$PATH"; }
fi
FAIL=0
for n in bcrypt secur32 crypt32; do
    echo "-- $n"
    # which unix .so does this build tree use for $n? (layout differs between DLLs, see mac_apply_forza_patches.sh)
    T=""
    for p in "dlls/$n/$n.so" "dlls/$n/x86_64-unix/$n.so"; do [ -f "$BUILD/$p" ] && { T="$p"; break; }; done
    [ -n "$T" ] || { echo "   no built $n.so in the build tree (this DLL may not have a unix part); skipping"; continue; }
    grep -q "include <gnutls" "$SRC"/dlls/$n/*.c 2>/dev/null || { echo "   $n sources do not use gnutls; skipping"; continue; }
    touch "$SRC"/dlls/$n/*.c
    if make -C "$BUILD" "$T" > "$REPO/out/enable-gnutls-make-$n.log" 2>&1; then
        cp "$BUILD/$T" "$UNIX/$n.so" && echo "   installed $UNIX/$n.so"
        printf "   gnutls in the new %s.so: " "$n"; strings -a "$UNIX/$n.so" | grep -c "libgnutls"
    else
        echo "   BUILD FAILED for $n"; grep -m5 -E "error|Error" "$REPO/out/enable-gnutls-make-$n.log"
        [ -f "$UNIX/$n.so.pre-gnutls.bak" ] && cp "$UNIX/$n.so.pre-gnutls.bak" "$UNIX/$n.so" && echo "   restored $n.so"
        FAIL=1
    fi
done
[ "$FAIL" = 0 ] || echo "WARN: at least one DLL failed; the working ones are installed, the failed one was restored"
echo "== done; test: relaunch the game and count  err:bcrypt  lines (was 45)"
