#!/bin/bash
# Build MetalHorizon.app and the files of a GitHub release.
#   bash app/build-app.sh [version, default 0.1.0]
# Output in app/dist/: MetalHorizon.app, MetalHorizon-<version>.zip, xodus-source-<version>.tar.gz, SHA256SUMS.
# XODUS_CLI / XODUS_SERVICE: the xodus binaries to bundle, and XODUS_CLI_SRC / XODUS_SERVICE_SRC the source trees
# they were built from (both GPL-3.0: the release carries that source). Defaults: the working setup's.
# Nothing from Apple or CrossOver goes into the app: the user picks D3DMetal from Apple's Game Porting Toolkit.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-0.1.0}"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
XODUS_CLI="${XODUS_CLI:-$WORK/xodus/target/release/xodus-cli}"
XODUS_SERVICE="${XODUS_SERVICE:-$WORK/xodus/target/release/xodus-service}"
XODUS_CLI_SRC="${XODUS_CLI_SRC:-$WORK/xodus}"
XODUS_SERVICE_SRC="${XODUS_SERVICE_SRC:-$WORK/xodus-ferestre}"   # see the header of patches/xodus-cli/0002
for f in "$XODUS_CLI" "$XODUS_SERVICE"; do [ -x "$f" ] || { echo "STOP: $f not found"; exit 1; }; done

echo "== build"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/MetalHorizon"

echo "== bundle"
DIST="$PWD/dist"; APP="$DIST/MetalHorizon.app"; RES="$APP/Contents/Resources"
rm -rf "$DIST"; mkdir -p "$APP/Contents/MacOS" "$RES"
cp "$BIN" "$APP/Contents/MacOS/MetalHorizon"
cp Resources/metalhorizon-play.sh "$RES/"
[ -f components.json ] || { echo "STOP: no app/components.json (bash app/update-components.sh)"; exit 1; }
cp components.json "$RES/components.json"
cp "$XODUS_CLI" "$RES/xodus-cli"; cp "$XODUS_SERVICE" "$RES/xodus-service"
chmod 755 "$RES/xodus-cli" "$RES/xodus-service" "$RES/metalhorizon-play.sh"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MetalHorizon</string>
    <key>CFBundleIdentifier</key><string>io.github.alexandreunitypro.metalhorizon</string>
    <key>CFBundleName</key><string>MetalHorizon</string>
    <key>CFBundleDisplayName</key><string>MetalHorizon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Microsoft's sign-in page needs xodus-cli to run as an app of its own (it opens a web view).
LOGIN="$RES/Xodus Login.app"
mkdir -p "$LOGIN/Contents/MacOS"
cp "$XODUS_CLI" "$LOGIN/Contents/MacOS/xodus-login"
cat > "$LOGIN/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>xodus-login</string>
    <key>CFBundleIdentifier</key><string>org.xodus-gaming.xodus-cli</string>
    <key>CFBundleName</key><string>Xodus Login</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "== no Apple or CrossOver file in the app"
if find "$APP" \( -iname '*d3dmetal*' -o -iname 'libd3dshared*' -o -iname '*crossover*' -o -iname 'd3d12*' \) | grep .; then
    echo "STOP: the files above must not be shipped"; exit 1
fi

echo "== sign (ad hoc: not notarized yet)"
codesign --force --sign - "$LOGIN"
codesign --force --sign - "$RES/xodus-cli" "$RES/xodus-service"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "== release files"
ditto -c -k --keepParent "$APP" "$DIST/MetalHorizon-$VERSION.zip"
# GPL-3.0 corresponding source of the two bundled xodus binaries: the trees they were built from.
SRCSTAGE="$DIST/xodus-source-$VERSION"
mkdir -p "$SRCSTAGE"
rsync -a --exclude target --exclude .git --exclude '*.bak' --exclude '.DS_Store' "$XODUS_CLI_SRC/" "$SRCSTAGE/xodus-cli-source/"
rsync -a --exclude target --exclude .git --exclude '*.bak' --exclude '.DS_Store' "$XODUS_SERVICE_SRC/" "$SRCSTAGE/xodus-service-source/"
{
    echo "Source of the xodus binaries in MetalHorizon $VERSION (GPL-3.0, https://github.com/xodus-gaming/xodus)."
    echo "xodus-cli-source/: xodus $(git -C "$XODUS_CLI_SRC" rev-parse --short HEAD 2>/dev/null || echo '?') with local changes; build: cargo build --release -p xodus-cli"
    echo "xodus-service-source/: Ferestre's xodus tree with patches/xodus-cli/0002; build: PROTOC=<protoc> cargo build --release -p xodus-service"
    echo "SHA-256 of the bundled binaries:"
    shasum -a 256 "$XODUS_CLI" "$XODUS_SERVICE" | sed 's|  .*/|  |'
} > "$SRCSTAGE/README.txt"
tar -C "$DIST" -czf "$DIST/xodus-source-$VERSION.tar.gz" "xodus-source-$VERSION"
rm -rf "$SRCSTAGE"
( cd "$DIST" && shasum -a 256 "MetalHorizon-$VERSION.zip" "xodus-source-$VERSION.tar.gz" | tee SHA256SUMS )
du -sh "$APP" "$DIST/MetalHorizon-$VERSION.zip" "$DIST/xodus-source-$VERSION.tar.gz"
