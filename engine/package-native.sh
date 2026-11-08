#!/bin/bash
# Blackwell Engine Native: the bundle MetalHorizon 1.0 installs for the native Apple silicon route.
#   bash engine/package-native.sh <wine out/engine> <highball r4 engine tarball> <kosmickrisp tarball> <renderers tarball> [version]
#
# What is ours: Wine 11.18 for arm64 (arm64ec + aarch64 + i386) built from WineHQ's source with Highball's
# patches-arm64 (branch arm64-games, through 0054) and Blackwell's Xbox patches ported to 11.18
# (engine/patches-arm64-xbox/: xgameruntime, Xbox app packages, msixvc images, network, audio, GameInput).
# What comes from Highball's release unchanged, each pinned by SHA-256 in engine/inputs-native.json: FEX 2610 with
# Highball's FEX patches (xtajit64.dll / xtajit.dll and their Darwin helper), GStreamer and winegstreamer, the host
# libraries Wine opens by name, Wine Mono and Gecko, KosmicKrisp (Mesa's Vulkan on Metal 4) and its Khronos loader,
# vkd3d-proton and DXVK (ARM64EC). The loader is not in the bundle: MetalHorizon links every `wine` to Highball's
# signed WineLoader.app at install, the only loader that carries Apple's cross-architecture entitlement.
set -euo pipefail
OUT_ENGINE="$1"; HB_ENGINE="$2"; KK="$3"; RENDERERS="$4"; VERSION="${5:-1.0}"
NAME="Blackwell Engine Native"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
B="$WORK/$NAME"; HB="$WORK/hb"
mkdir -p "$B" "$HB"
tar -xzf "$HB_ENGINE" -C "$HB"
test -f "$HB/engine/lib/wine/aarch64-windows/xtajit64.dll" || { echo "STOP: not a Highball arm64 engine tarball"; exit 1; }

echo "== Wine (ours)"
ditto "$OUT_ENGINE" "$B/engine"
W="$B/engine/lib/wine"
test -f "$W/aarch64-windows/xgameruntime.dll" && test -f "$W/aarch64-unix/xgameruntime.so" || { echo "STOP: this build has no Xbox runtime"; exit 1; }

echo "== FEX, winegstreamer, host libraries, Mono and Gecko (Highball r4, unchanged)"
mv "$W/aarch64-windows/xtajit64.dll" "$W/aarch64-windows/xtajit64.dll.wine" 2>/dev/null || true
for f in aarch64-windows/xtajit64.dll aarch64-windows/xtajit.dll aarch64-unix/libarm64ecfex.so aarch64-unix/libwow64fex.so \
         aarch64-windows/winegstreamer.dll aarch64-unix/winegstreamer.so i386-windows/winegstreamer.dll; do
    if [ -e "$HB/engine/lib/wine/$f" ]; then cp -p "$HB/engine/lib/wine/$f" "$W/$f"; else echo "  (not in Highball's engine: $f)"; fi
done
for f in "$HB"/engine/lib/*.dylib; do cp -P "$f" "$B/engine/lib/"; done
ln -sfn ../../frameworks/GStreamer.framework "$B/engine/lib/GStreamer.framework"
mkdir -p "$B/engine/share/wine"
for d in mono gecko; do [ -d "$HB/engine/share/wine/$d" ] && ditto "$HB/engine/share/wine/$d" "$B/engine/share/wine/$d"; done
ditto "$HB/frameworks" "$B/frameworks"

echo "== KosmicKrisp and the renderers"
mkdir -p "$WORK/kk" "$B/renderers"
tar -xzf "$KK" -C "$WORK/kk"
cp "$WORK/kk/lib/libMoltenVK.dylib" "$B/engine/lib/libMoltenVK.dylib"   # the Khronos loader, under the name winevulkan opens
ditto "$WORK/kk/renderers/kosmickrisp" "$B/renderers/kosmickrisp"
tar -xzf "$RENDERERS" -C "$B"
test -d "$B/renderers/vkd3d/wine" && test -f "$B/renderers/kosmickrisp/kosmickrisp_icd.json" || { echo "STOP: renderers incomplete"; exit 1; }

echo "== strip debug info (as Highball's build does)"
before=$(du -sm "$B/engine" | cut -f1)
STRIP_PE="${LLVM_STRIP:-$(command -v llvm-strip || true)}"
[ -x "$STRIP_PE" ] || { echo "STOP: llvm-strip not found (llvm-mingw's bin on PATH, or LLVM_STRIP=)"; exit 1; }
find "$W/aarch64-windows" "$W/i386-windows" \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.cpl' -o -name '*.ocx' -o -name '*.acm' -o -name '*.tlb' \) -type f ! -name 'xtajit*' ! -name 'winegstreamer.dll' -print0 \
    | xargs -0 -n 50 "$STRIP_PE" --strip-debug 2>/dev/null || true
find "$W/aarch64-unix" -name '*.so' -type f ! -name 'lib*fex.so' ! -name 'winegstreamer.so' -print0 | xargs -0 -n 50 strip -x -S 2>/dev/null || true
strip -x -S "$B/engine/bin/wineserver" 2>/dev/null || true
echo "  engine: ${before} MB -> $(du -sm "$B/engine" | cut -f1) MB"

echo "== ad-hoc signatures on what was rebuilt or stripped"
find "$W/aarch64-unix" -name '*.so' -type f -print0 | xargs -0 -n 50 codesign -f -s - 2>/dev/null || true
codesign -f -s - "$B/engine/bin/wineserver" 2>/dev/null || true

echo "== licences and notice"
mkdir -p "$B/licenses"
cp "$(dirname "$0")/NOTICE-native.md" "$B/NOTICE.md"
[ -d "$WORK/kk/licenses" ] && ditto "$WORK/kk/licenses" "$B/licenses/kosmickrisp"
[ -f "$HB/engine/share/wine/LICENSE" ] && cp "$HB/engine/share/wine/LICENSE" "$B/licenses/wine-LICENSE" || true
echo "$VERSION" > "$B/VERSION"

TAR="blackwell-engine-native-$VERSION.tar.xz"
echo "== $TAR"
tar -C "$WORK" -cJf "$TAR" "$NAME"
shasum -a 256 "$TAR" | tee "$TAR.sha256"
ls -la "$TAR"
