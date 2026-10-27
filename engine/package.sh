#!/bin/bash
# Make the Blackwell Engine tarball the MetalHorizon app installs: the engine engine/build.sh built (with its own
# GnuTLS, FreeType and MoltenVK) plus Highball's DirectX 12 shim, compiled from tools/tsshim.
#   bash engine/package.sh <version> [work folder, default ~/BlackwellEngine-build]
# Output: <work>/blackwell-engine-<version>.tar.xz (top folder "Blackwell Engine") and its .sha256.
# It stops if a file from Apple (D3DMetal) or from CrossOver.app ends up inside: those are not part of the engine.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
V="${1:?usage: engine/package.sh <version> [work folder]}"
W="${2:-$HOME/BlackwellEngine-build}"
E="$W/out/engine"
fail() { echo "STOP: $1"; exit 1; }
[ -x "$E/bin/wine" ] || fail "no engine in $E: run engine/build.sh first"
[ -f "$E/lib/libgnutls.30.dylib" ] || fail "the engine has no GnuTLS of its own: run engine/build.sh again"
LM="$(ls -d "$W"/toolchains/llvm-mingw-* | head -1)"
[ -x "$LM/bin/x86_64-w64-mingw32-clang" ] || fail "no llvm-mingw in $W/toolchains"

echo "== DirectX 12 shim (Highball's tsshim, GPL-3.0)"
S="$E/renderers/tsshim/x86_64-windows"
rm -rf "$E/renderers/tsshim"; mkdir -p "$S"
"$LM/bin/x86_64-w64-mingw32-clang" -shared -O2 -Wall -static-libgcc -o "$S/d3d12.dll" \
    "$REPO/tools/tsshim/d3d12.c" "$REPO/tools/tsshim/dxil_shadingrate.c" "$REPO/tools/tsshim/inspect.c" \
    "$REPO/tools/tsshim/d3d12.def" 2> "$W/tsshim.log" || { tail -20 "$W/tsshim.log"; fail "shim build failed"; }
python3 -I "$REPO/tools/pe_tools.py" mark-builtin "$S/d3d12.dll"
cp "$REPO/tools/tsshim/ORIGIN.md" "$E/renderers/tsshim/ORIGIN.md"

echo "== nothing from Apple or CrossOver"
if find "$E" \( -iname '*d3dmetal*' -o -iname 'libd3dshared*' -o -path '*apple_gptk*' -o -iname '*crossover*' \) | grep .; then
    fail "the files above must not be in the engine"
fi
if grep -rl --include='*.dll' --include='*.so' -e 'D3DMetalDLLsBase' -e 'com.apple.libd3dshared' "$E/lib" "$E/renderers" 2>/dev/null | grep .; then
    fail "the files above are Apple's d3d12 halves, not Wine's"
fi

echo "== notices and manifest"
mkdir -p "$E/share/licenses"
cp "$W/src/sources/wine/COPYING.LIB" "$E/share/licenses/Wine-COPYING.LIB" 2>/dev/null || true
cp "$W/src/sources/wine/dlls/xgameruntime/LICENSE" "$E/share/licenses/xgameruntime-LICENSE" 2>/dev/null || true
python3 -I - "$E/metalhorizon.json" "$V" "$REPO/engine/inputs.json" "$(cat "$E/.series-sha256" 2>/dev/null)" \
    "$(git -C "$REPO" rev-parse HEAD)" <<'PY'
import json, sys, time
out, version, inputs, series, commit = sys.argv[1:6]
i = json.load(open(inputs))
json.dump({"name": "Blackwell Engine", "version": version, "built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "commit": commit, "seriesSha256": series, "wineSource": i["wine"]["url"], "wineSha256": i["wine"]["sha256"],
           "llvmMingwSha256": i["llvm-mingw"]["sha256"],
           "deps": {k: v["url"] for k, v in i["deps"].items() if isinstance(v, dict)},
           "source": "https://github.com/alexandreunitypro/blackwell-engine"},
          open(out, "w"), indent=2)
PY

echo "== tarball"
NAME="blackwell-engine-$V"
rm -f "$W/$NAME.tar.xz"
tar -C "$W/out" -s '|^engine|Blackwell Engine|' -cJf "$W/$NAME.tar.xz" engine
( cd "$W" && shasum -a 256 "$NAME.tar.xz" | tee "$NAME.tar.xz.sha256" )
echo "size: $(stat -f %z "$W/$NAME.tar.xz") bytes ($(du -h "$W/$NAME.tar.xz" | cut -f1))"
