#!/bin/bash
# Apply Highball's Forza-relevant Wine patches (tools/forza-patches, GPL-3.0) to the CrossOver Wine
# source and rebuild only the DLLs they touch, each with a .bak backup. The three core Forza patches
# (0017-0019) are required; the rest are best-effort (on a build failure that DLL is restored and we
# go on, so the working engine is never left broken).
#   0017 kernelbase  GetIntegratedDisplaySize stub (else FH6 aborts once its window opens)   [required]
#   0018 ntdll.so    commit charge = phys_footprint (else "87 GB / 32 GB" low-memory warning) [required]
#   0019 advapi32    keep the Xbox sign-in instead of a device code every launch              [required]
#   0020 winemac     retina HORZRES/VERTRES not doubled (fullscreen not cropped)
#   0022 mmdevapi    7.1/7.1.4 spatial channel order
#   0023 winecoreaudio surround on a 2-channel Mac (HB_SPATIAL=0 to disable)
#   0024 kernel32+kernelbase  app-package lookups answer from the registry instead of hanging forever
#   0025 ntdll.dll   closing async I/O no longer crashes
# Undo: tools/mac_apply_forza_patches.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
ENGINE="$WORK/crossover-source/out-x64/engine"
BUILD="$WORK/crossover-source/build-x64-cross"
mkdir -p "$REPO/out"; exec > >(tee "$REPO/out/forza-patches.log") 2>&1

# source files each patch may touch (for backup/undo) and the installed DLLs they rebuild
SRCS=(
  dlls/kernelbase/kernelbase.spec dlls/kernelbase/main.c dlls/kernelbase/version.c
  dlls/ntdll/unix/process.c dlls/ntdll/threadpool.c dlls/advapi32/cred.c
  dlls/winemac.drv/gdi.c dlls/mmdevapi/spatialaudio.c dlls/winecoreaudio.drv/coreaudio.c
  dlls/kernel32/kernel32.spec loader/wine.inf.in
)
# installed file  <=  built file (relative to $BUILD)
declare -a INST=(
  "lib/wine/x86_64-windows/kernelbase.dll|dlls/kernelbase/x86_64-windows/kernelbase.dll"
  "lib/wine/x86_64-unix/ntdll.so|dlls/ntdll/ntdll.so"
  "lib/wine/x86_64-windows/ntdll.dll|dlls/ntdll/x86_64-windows/ntdll.dll"
  "lib/wine/x86_64-windows/advapi32.dll|dlls/advapi32/x86_64-windows/advapi32.dll"
  "lib/wine/x86_64-unix/winemac.so|dlls/winemac.drv/x86_64-unix/winemac.so"
  "lib/wine/x86_64-windows/mmdevapi.dll|dlls/mmdevapi/x86_64-windows/mmdevapi.dll"
  "lib/wine/x86_64-unix/winecoreaudio.so|dlls/winecoreaudio.drv/x86_64-unix/winecoreaudio.so"
  "lib/wine/x86_64-windows/kernel32.dll|dlls/kernel32/x86_64-windows/kernel32.dll"
)

if [ "${1:-}" = "--undo" ]; then
    for f in "${SRCS[@]}"; do [ -f "$SRC/$f.pre-forza.bak" ] && cp "$SRC/$f.pre-forza.bak" "$SRC/$f" && echo "restored src $f"; done
    for pair in "${INST[@]}"; do i="${pair%%|*}"; [ -f "$ENGINE/$i.pre-forza.bak" ] && cp "$ENGINE/$i.pre-forza.bak" "$ENGINE/$i" && echo "restored $i"; done
    exit 0
fi

echo "== CrossOver source version"
grep -rhoE "crossover-sources-[0-9.]+|CrossOver [0-9.]+|26\.[0-9]" "$SRC/VERSION" "$SRC/configure.ac" "$SRC/configure" 2>/dev/null | sort -u | head -3 || echo "(version string not found)"

echo "== backups"
for f in "${SRCS[@]}"; do [ -f "$SRC/$f" ] && { [ -f "$SRC/$f.pre-forza.bak" ] || cp "$SRC/$f" "$SRC/$f.pre-forza.bak"; }; done
for pair in "${INST[@]}"; do i="${pair%%|*}"; [ -f "$ENGINE/$i" ] && { [ -f "$ENGINE/$i.pre-forza.bak" ] || cp "$ENGINE/$i" "$ENGINE/$i.pre-forza.bak"; }; done

echo "== build tools"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
    CC=$(find "$WORK" /opt/homebrew /usr/local /opt -maxdepth 6 \( -name x86_64-w64-mingw32-gcc -o -name x86_64-w64-mingw32-clang \) \( -type f -o -type l \) 2>/dev/null | head -1)
    [ -n "$CC" ] || { echo "STOP: no mingw cross compiler"; exit 1; }
    mkdir -p "$REPO/out/cross-bin"; ln -sf "$CC" "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc"
    export PATH="$REPO/out/cross-bin:$(dirname "$CC"):$PATH"; echo "using $CC"
fi

apply() {  # name patchfile required(0/1) "builddir..." "installfile..." "srcfile..." markerfile markerstring
    local name="$1" pf="$2" req="$3" dirs="$4" installs="$5" files="$6" mf="${7:-}" ms="${8:-}" d f
    echo "== $name"
    if [ -n "$mf" ] && [ -f "$mf" ] && grep -qF "$ms" "$mf"; then
        echo "   already present in the source (installed DLL already carries it) — skipping"
        return 0
    fi
    # a patch that leaves a .rej did not fully apply: back its files out and skip (never half-patched source)
    rm -f "$SRC"/*.rej "$SRC"/dlls/*/*.rej "$SRC"/dlls/*/*/*.rej 2>/dev/null
    if ! ( cd "$SRC" && patch -p1 --forward --fuzz=3 < "$pf" ); then
        echo "   patch did not apply cleanly"
    fi
    if ls "$SRC"/dlls/*/*.rej "$SRC"/dlls/*/*/*.rej >/dev/null 2>&1; then
        echo "   REJECTED hunks -> restoring $name files and skipping"
        for f in $files; do [ -f "$SRC/$f.pre-forza.bak" ] && cp "$SRC/$f.pre-forza.bak" "$SRC/$f"; done
        rm -f "$SRC"/dlls/*/*.rej "$SRC"/dlls/*/*/*.rej 2>/dev/null
        [ "$req" = 1 ] && { echo "   STOP: $name is required"; exit 1; }
        return 1
    fi
    for d in $dirs; do
        if ! make -C "$BUILD" "dlls/$d" >/dev/null 2>"$REPO/out/build-$name.err"; then
            echo "   BUILD FAILED for dlls/$d"; tail -3 "$REPO/out/build-$name.err"
            [ "$req" = 1 ] && { echo "   STOP: $name is required"; exit 1; }
            echo "   -> restoring $name files and skipping"
            for f in $files; do [ -f "$SRC/$f.pre-forza.bak" ] && cp "$SRC/$f.pre-forza.bak" "$SRC/$f"; done
            return 1
        fi
    done
    for i in $installs; do
        local built="" rel
        for pair in "${INST[@]}"; do [ "${pair%%|*}" = "$i" ] && rel="${pair#*|}"; done
        built="$BUILD/$rel"
        [ -f "$built" ] || built="$(find "$BUILD/dlls" -name "$(basename "$i")" -newer "$pf" 2>/dev/null | head -1)"
        if [ -n "$built" ] && [ -f "$built" ]; then cp "$built" "$ENGINE/$i" && echo "   installed $i"
        else echo "   WARN: built file for $i not found"; fi
    done
}

apply 0017 "$REPO/tools/forza-patches/0017-"*.patch 1 "kernelbase" "lib/wine/x86_64-windows/kernelbase.dll" "dlls/kernelbase/kernelbase.spec dlls/kernelbase/main.c" "$SRC/dlls/kernelbase/kernelbase.spec" "stdcall GetIntegratedDisplaySize"
apply 0018 "$REPO/tools/forza-patches/0018-"*.patch 1 "ntdll" "lib/wine/x86_64-unix/ntdll.so" "dlls/ntdll/unix/process.c" "$SRC/dlls/ntdll/unix/process.c" "phys_footprint"
apply 0019 "$REPO/tools/forza-patches/0019-"*.patch 1 "advapi32" "lib/wine/x86_64-windows/advapi32.dll" "dlls/advapi32/cred.c" "$SRC/dlls/advapi32/cred.c" "ERROR_NOT_FOUND) ret = ERROR_SUCCESS"
apply 0020 "$REPO/tools/forza-patches/0020-"*.patch 0 "winemac.drv" "lib/wine/x86_64-unix/winemac.so" "dlls/winemac.drv/gdi.c"
apply 0022 "$REPO/tools/forza-patches/0022-"*.patch 0 "mmdevapi" "lib/wine/x86_64-windows/mmdevapi.dll" "dlls/mmdevapi/spatialaudio.c" "$SRC/dlls/mmdevapi/spatialaudio.c" "channels follow the speaker bits in ascending order"
apply 0023 "$REPO/tools/forza-patches/0023-"*.patch 0 "winecoreaudio.drv" "lib/wine/x86_64-unix/winecoreaudio.so" "dlls/winecoreaudio.drv/coreaudio.c" "$SRC/dlls/winecoreaudio.drv/coreaudio.c" "HB_SPATIAL"
apply 0024 "$REPO/tools/forza-patches/0024-"*.patch 0 "kernelbase kernel32" "lib/wine/x86_64-windows/kernelbase.dll lib/wine/x86_64-windows/kernel32.dll" "dlls/kernelbase/kernelbase.spec dlls/kernelbase/version.c dlls/kernel32/kernel32.spec loader/wine.inf.in" "$SRC/dlls/kernelbase/version.c" "RegOpenKeyExW(HKEY_LOCAL_MACHINE, packages_key_name"
apply 0025 "$REPO/tools/forza-patches/0025-"*.patch 0 "ntdll" "lib/wine/x86_64-windows/ntdll.dll" "dlls/ntdll/threadpool.c" "$SRC/dlls/ntdll/threadpool.c" "runs once that completion arrives"

echo "== verify core patches are in the source"
grep -q "stdcall GetIntegratedDisplaySize" "$SRC/dlls/kernelbase/kernelbase.spec" && echo "0017 ok" || echo "0017 MISSING"
grep -q "phys_footprint" "$SRC/dlls/ntdll/unix/process.c" && echo "0018 ok" || echo "0018 MISSING"
grep -q "ERROR_NOT_FOUND) ret = ERROR_SUCCESS" "$SRC/dlls/advapi32/cred.c" && echo "0019 ok" || echo "0019 MISSING"
echo "== done"
