#!/bin/bash
# Launch FH6 (Store, through xodus) on Mullion instead of D3DMetal, in a prefix of its own.
# The D3DMetal setup (tools/jouer.sh, tools/mac_launch_fh6.sh, ~/FH6/.blackwell-wine) is not touched.
#   bash tools/mac_launch_fh6_mullion.sh [max-seconds, default 600]
# MULLION_DIR   : a Mullion install (x86_64-windows + x86_64-unix), default ~/Downloads/fh6-sources/install-mullion
# FH6_M_PREFIX  : the prefix, default ~/FH6/.mullion-wine (an APFS copy of .blackwell-wine)
# FH6_GPU       : nvidia (default, as the D3DMetal recipe) | amd | intel | apple
# FH6_M_DEBUG   : WINEDEBUG channels (default +timestamp,+loaddll,warn+process,err+all)
# FH6_M_LOGLVL  : MULLION_LOG_LEVEL (default info; debug/trace for more)
# Logs: out/mullion-<date>/ (wine.log, Mullion's per-DLL logs, summary.txt)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente"
ENGINE="$ROOT/work/crossover-source/out-x64/engine"
MULLION_DIR="${MULLION_DIR:-$HOME/Downloads/fh6-sources/install-mullion}"
PREFIX="${FH6_M_PREFIX:-$HOME/FH6/.mullion-wine}"
SOURCE="$HOME/FH6"
MAX="${1:-600}"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$REPO/out/mullion-$STAMP"
mkdir -p "$OUT"
[ -f "$MULLION_DIR/x86_64-windows/d3d12.dll" ] || { echo "STOP: no Mullion in $MULLION_DIR"; exit 1; }
[ -d "$PREFIX/drive_c" ] || { echo "STOP: no prefix $PREFIX (cp -cR ~/FH6/.blackwell-wine $PREFIX)"; exit 1; }
[ -d "$SOURCE" ] && [ ! -L "$SOURCE" ] || { echo "STOP: game folder must be ~/FH6"; exit 1; }

# Wine loads a builtin DLL from WINEDLLPATH_PREPEND only when a file of that name is in the prefix (winemetal.dll is
# not there otherwise): the DLLs go into this prefix's system32 as install.sh puts them, never into .blackwell-wine
case "$PREFIX" in *blackwell-wine*) echo "STOP: refusing to write into the D3DMetal prefix"; exit 1 ;; esac
cp "$MULLION_DIR"/x86_64-windows/*.dll "$PREFIX/drive_c/windows/system32/"

# nothing of D3DMetal: no CX_GRAPHICS_BACKEND, no D3DM_*, no GPTK on the dylib path, no shim
unset CX_GRAPHICS_BACKEND CX_APPLEGPTK_LIBD3DSHARED_PATH D3DM_MTL4 HB_D3D12_REAL DYLD_FRAMEWORK_PATH
export CX_ROOT="$ENGINE"
export WINEPREFIX="$PREFIX"
export WINEMSYNC=1
export WINEDLLPATH_PREPEND="$MULLION_DIR"
export WINEDLLOVERRIDES="concrt140,msvcp140,msvcp140_atomic_wait,vcruntime140,vcruntime140_1=n,b;d3d12,d3d12core,dxgi,d3d11,d3d10core,winemetal,nvapi64,nvngx=b"
export DYLD_LIBRARY_PATH="$ENGINE/lib:/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64"
export XODUS_RUNTIME_DIR=/private/tmp/xodus-runtime-test
export WINEDEBUG="${FH6_M_DEBUG:-+timestamp,+loaddll,warn+process,err+all}"
export MULLION_LOG_LEVEL="${FH6_M_LOGLVL:-info}"
export MULLION_LOG_PATH="Z:$OUT"
[ "${FH6_HUD:-1}" != "0" ] && export MTL_HUD_ENABLED=1
[ -n "${FH6_METAL_DEBUG:-}" ] && export MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1
[ -n "${FH6_METAL_CAPTURE:-}" ] && export MTL_CAPTURE_ENABLED=1
# the GPU the game sees (FH6 takes an AMD-only path and crashes with AMD's id: FHE21)
case "${FH6_GPU:-nvidia}" in
    intel) CONF="dxgi.customVendorId=8086;dxgi.customDeviceId=56a1;dxgi.customDeviceDesc=Intel(R) Arc(TM) A750 Graphics" ;;
    amd)   CONF="dxgi.customVendorId=1002;dxgi.customDeviceId=73bf;dxgi.customDeviceDesc=AMD Radeon RX 6800 XT" ;;
    apple) CONF="dxgi.customVendorId=106b" ;;
    *)     CONF="dxgi.customVendorId=10de;dxgi.customDeviceId=2786;dxgi.customDeviceDesc=NVIDIA GeForce RTX 4070" ;;
esac
export MULLION_CONFIG="$CONF${FH6_M_CONFIG:+;$FH6_M_CONFIG}"
# upstream DXMT (MULLION_DIR=an install of it) reads the same settings under its own names
export DXMT_CONFIG="$MULLION_CONFIG" DXMT_LOG_PATH="$MULLION_LOG_PATH" DXMT_LOG_LEVEL="$MULLION_LOG_LEVEL"
{
    echo "date: $STAMP"; echo "mullion: $MULLION_DIR"; echo "prefix: $PREFIX"; echo "config: $MULLION_CONFIG"
    shasum -a 256 "$MULLION_DIR"/x86_64-windows/*.dll "$MULLION_DIR"/x86_64-unix/*.so | sed "s|$MULLION_DIR/||"
} > "$OUT/env.txt"
cat "$OUT/env.txt" | head -4

bash "$REPO/tools/mac_xodus_service.sh" start >/dev/null 2>&1 || echo "WARN: xodus-service did not start; no Xbox sign-in"
"$ENGINE/bin/wineserver" -k 2>/dev/null || true
cd "$SOURCE" || exit 1
echo "== launching on Mullion (up to $MAX s), log $OUT/wine.log"
"$ROOT/work/xodus/target/release/xodus-cli" run "$SOURCE" "$ENGINE/bin/wine" --exe forzahorizon6.exe >"$OUT/wine.log" 2>&1 &
PID=$!
trap 'kill -INT $PID 2>/dev/null' INT
for i in $(seq "$MAX"); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
kill -INT "$PID" 2>/dev/null; sleep 3; kill -9 "$PID" 2>/dev/null
wait "$PID" 2>/dev/null
"$ENGINE/bin/wineserver" -k 2>/dev/null || true

{
    echo "ran ~${i}s, $(wc -l < "$OUT/wine.log") wine log lines"
    echo "-- graphics DLLs loaded (must be Mullion's, never apple_gptk/d3dmetal):"
    LC_ALL=C grep -a "Loaded" "$OUT/wine.log" | grep -a -i -E "d3d1|dxgi|winemetal|nvapi|nvngx|apd12|gptk|d3dmetal|D3D12Core" | sed -E 's/^[0-9.]+:[0-9a-f]+:trace:loaddll:[a-z_]+ //' | sort -u
    echo "-- D3DMetal fallback check:"; LC_ALL=C grep -a -c -i "d3dmetal\|apple_gptk\|libd3dshared" "$OUT/wine.log"
    echo "-- Mullion logs:"; ls -la "$OUT"/*.log 2>/dev/null | grep -v wine.log
    for f in "$OUT"/*_d3d12.log "$OUT"/*_d3d12core.log "$OUT"/*_dxgi.log "$OUT"/*_nvapi.log; do [ -f "$f" ] && { echo "--- $f (errors/warnings, unique)"; grep -E "err:|warn:" "$f" | sed -E 's/0x[0-9a-fA-F]+/X/g' | sort | uniq -c | sort -rn | head -40; }; done
    echo "-- self termination / exceptions:"; LC_ALL=C grep -a -m10 -E "terminating itself|Unhandled|page fault|c0000005|FHE[0-9]+" "$OUT/wine.log"
    echo "-- last 30 lines:"; tail -30 "$OUT/wine.log"
} > "$OUT/summary.txt" 2>&1
cat "$OUT/summary.txt"
echo "== logs in $OUT"
