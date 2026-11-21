#!/bin/bash
# Blackwell Engine beta (alpha): the public Rosetta engine of a build folder plus the beta patches of a series
# (the lines after "# --- Beta"), built by rebuilding only the modules they touch, then packaged on its own.
# MetalHorizon installs it only in beta mode (Settings › Advanced), beside the public engine.
#   bash engine/build-beta.sh <work folder> <series-beta file> <version> <name>
#   e.g. bash engine/build-beta.sh ~/BlackwellEngine-build series-beta beta-1.3a1 blackwell-engine-beta-1.3a1
# The build folder must hold the public engine (engine/build.sh): its sources, build/ and out/engine. The beta
# patches are taken out again at the end and the same modules rebuilt, so the folder holds the public engine again.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; ENG="$REPO/engine"
W="${1:?work folder}"; SERIES="$ENG/${2:?series file}"; V="${3:?version}"; NAME="${4:?tarball name}"
SRC="$W/src/sources/wine"; B="$W/build"; OUT="$W/out/engine"; STAGE="$W/out-beta/engine"
fail() { echo "STOP: $1"; exit 1; }
[ -f "$B/Makefile" ] && [ -x "$OUT/bin/wine" ] || fail "no public engine build in $W"
# the PE compiler the build was configured with: llvm-mingw (Xbox variant) or Homebrew's mingw-w64 gcc (Steam variant)
LM="$(ls -d "$W"/toolchains/llvm-mingw-* 2>/dev/null | head -1)"
grep -q '^x86_64_CC = x86_64-w64-mingw32-clang' "$B/Makefile" && [ -n "$LM" ] && export PATH="$LM/bin:$PATH"
ARCHS="$(sed -n "s/^ac_cs_config=.*--enable-archs=\([a-z0-9_,]*\).*/\1/p" "$B/config.status")"
BETA=(); while IFS= read -r p; do BETA+=("$p"); done < <(sed -n '/^# --- Beta/,$p' "$SERIES" | grep -v '^#' | grep -v '^$')
[ ${#BETA[@]} -gt 0 ] || fail "no beta patches in $SERIES"
TARGETS=(dlls/ntdll/ntdll.so dlls/ntdll/x86_64-windows/ntdll.dll dlls/winecoreaudio.drv/winecoreaudio.so)
case ",$ARCHS," in *,i386,*) TARGETS+=(dlls/ntdll/i386-windows/ntdll.dll) ;; esac
rebuild() { ( cd "$B" && arch -x86_64 make -j"$(sysctl -n hw.ncpu)" "${TARGETS[@]}" ) > "$W/make-beta.log" 2>&1 || { tail -20 "$W/make-beta.log"; fail "build failed"; }; }
revert() { for (( i=${#BETA[@]}-1; i>=0; i-- )); do patch -p1 -R -d "$SRC" --batch --quiet < "$ENG/patches/${BETA[$i]}"; done; find "$SRC" -name '*.orig' -delete; }

echo "== 1. beta patches (${#BETA[@]})"
for p in "${BETA[@]}"; do echo "  $p"; patch -p1 -d "$SRC" --forward --batch --quiet < "$ENG/patches/$p" || { revert 2>/dev/null || true; fail "$p does not apply"; }; done
find "$SRC" -name '*.orig' -delete
trap 'echo "== taking the beta patches out again"; revert; rebuild' EXIT
echo "== 2. modules: ${TARGETS[*]} (archs $ARCHS)"
rebuild
echo "== 3. staging $STAGE"
rm -rf "$W/out-beta"; mkdir -p "$W/out-beta"; ditto "$OUT" "$STAGE"
cp "$B/dlls/ntdll/ntdll.so" "$STAGE/lib/wine/x86_64-unix/ntdll.so"
cp "$B/dlls/ntdll/x86_64-windows/ntdll.dll" "$STAGE/lib/wine/x86_64-windows/ntdll.dll"
cp "$B/dlls/winecoreaudio.drv/winecoreaudio.so" "$STAGE/lib/wine/x86_64-unix/winecoreaudio.so"
case ",$ARCHS," in *,i386,*) cp "$B/dlls/ntdll/i386-windows/ntdll.dll" "$STAGE/lib/wine/i386-windows/ntdll.dll"
    command -v x86_64-w64-mingw32-strip >/dev/null && x86_64-w64-mingw32-strip --strip-debug \
        "$STAGE/lib/wine/x86_64-windows/ntdll.dll" "$STAGE/lib/wine/i386-windows/ntdll.dll" 2>/dev/null || true ;;
esac
[ "$(strings -a "$STAGE/lib/wine/x86_64-unix/ntdll.so" | grep -c "bw-pacer: on")" -gt 0 ] || fail "the staged ntdll.so has no pacer"
python3 -I - "$STAGE/metalhorizon.json" "$V" "$(cd "$ENG" && cat "$(basename "$SERIES")" patches/*.patch | shasum -a 256 | cut -d' ' -f1)" \
    "$(git -C "$REPO" rev-parse HEAD)" <<'PY'
import json, sys, time
path, version, series, commit = sys.argv[1:5]
d = json.load(open(path))
d.update({"version": version, "channel": "beta", "built": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
          "seriesSha256": series, "commit": commit,
          "beta": "Rosetta line: Blackwell Pacer (BW_PACER=auto) and Highball's 0005, 0014, 0015, 0025, 0028"})
json.dump(d, open(path, "w"), indent=2)
PY
echo "== 4. tarball"
rm -f "$W/$NAME.tar.xz"
tar -C "$W/out-beta" -s '|^engine|Blackwell Engine|' -cJf "$W/$NAME.tar.xz" engine
( cd "$W" && shasum -a 256 "$NAME.tar.xz" | tee "$NAME.tar.xz.sha256" )
echo "size: $(stat -f %z "$W/$NAME.tar.xz")"
