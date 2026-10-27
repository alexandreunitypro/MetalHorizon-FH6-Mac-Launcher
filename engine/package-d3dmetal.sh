#!/bin/bash
# Package Apple's D3DMetal for the MetalHorizon app: the Game Porting Toolkit's redist/lib (D3DMetal.framework,
# libd3dshared.dylib and the Wine d3d12/dxgi halves, whose .so files are links to libd3dshared.dylib) with Apple's
# License.rtf and Acknowledgements.rtf, unmodified.
#   bash engine/package-d3dmetal.sh <Game Porting Toolkit .dmg or mounted volume> [output folder]
# Apple's licence (section 2A(iii) and 2C) lets the Framework and the Redistributables be distributed separately for
# non-commercial purposes, with their notices. MetalHorizon is free; the app shows License.rtf and installs only
# after the user accepts it. Output: d3dmetal-<version>-redist.tar.xz (top folder "D3DMetal") and its .sha256.
set -euo pipefail
IN="${1:?usage: engine/package-d3dmetal.sh <toolkit .dmg or volume> [output folder]}"
OUT="${2:-$HOME/BlackwellEngine-build}"
fail() { echo "STOP: $1"; exit 1; }
MOUNTED=""
if [ -f "$IN" ]; then
    MP="$(hdiutil attach -nobrowse -readonly -noverify "$IN" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
    MOUNTED="$MP"
else
    MP="$IN"
fi
trap '[ -n "$MOUNTED" ] && hdiutil detach -quiet "$MOUNTED" || true' EXIT
L="$MP/redist/lib"
[ -f "$L/external/libd3dshared.dylib" ] && [ -f "$L/wine/x86_64-windows/d3d12.dll" ] || fail "no redist/lib in $MP"
[ -f "$MP/License.rtf" ] || fail "no License.rtf in $MP"
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$L/external/D3DMetal.framework/Versions/A/Resources/Info.plist")"
case "$V" in 4.*) ;; *) fail "D3DMetal $V: version 4 is needed";; esac

STAGE="$OUT/.d3dmetal-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/D3DMetal"
cp -RP "$L/external" "$L/wine" "$STAGE/D3DMetal/"       # -P keeps the .so links
cp "$MP/License.rtf" "$MP/Acknowledgements.rtf" "$STAGE/D3DMetal/" 2>/dev/null || cp "$MP/License.rtf" "$STAGE/D3DMetal/"
cat > "$STAGE/D3DMetal/README.txt" <<TXT
D3DMetal $V, the redistributable part of Apple's Game Porting Toolkit (redist/lib), unmodified.
Copyright Apple Inc. Distributed separately and non-commercially under Apple's licence (License.rtf, sections 2A and 2C).
MetalHorizon installs it only after you accept that licence.
TXT
# the copy must be bit for bit Apple's
( cd "$L" && find external wine -type f -exec shasum -a 256 {} + | sort -k2 ) > "$STAGE/apple.sha"
( cd "$STAGE/D3DMetal" && find external wine -type f -exec shasum -a 256 {} + | sort -k2 ) > "$STAGE/copy.sha"
cmp -s "$STAGE/apple.sha" "$STAGE/copy.sha" || fail "the copy differs from Apple's files"
[ -L "$STAGE/D3DMetal/wine/x86_64-unix/d3d12.so" ] || fail "the .so files lost their links"

NAME="d3dmetal-$V-redist"
tar -C "$STAGE" -cJf "$OUT/$NAME.tar.xz" D3DMetal
rm -rf "$STAGE"
( cd "$OUT" && shasum -a 256 "$NAME.tar.xz" | tee "$NAME.tar.xz.sha256" )
echo "size: $(stat -f %z "$OUT/$NAME.tar.xz") bytes"
