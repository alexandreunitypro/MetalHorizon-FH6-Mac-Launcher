#!/bin/bash
# Applies the xodus half (keep the decrypted image named on macOS) to the xodus-cli that
# BlackwellLauncher.app bundles, rebuilds it, installs it with a backup.
# Undo: tools/mac_apply_xodus_fix.sh --undo
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
mkdir -p "$REPO/out"
exec > >(tee "$REPO/out/apply-xodus-fix.log") 2>&1
[ -d "$WORK/cargo-home" ] && export CARGO_HOME="$WORK/cargo-home"
[ -d "$WORK/rustup-home" ] && export RUSTUP_HOME="$WORK/rustup-home"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
# build tools the earlier xodus builds used, kept in the work tree
for t in cmake protoc; do
    command -v "$t" >/dev/null && continue
    f=$(find "$WORK/cmake-python" "$WORK/protoc" "$WORK/toolchains" /opt/homebrew/bin /usr/local/bin -name "$t" -type f -perm +111 2>/dev/null | head -1)
    [ -n "$f" ] && export PATH="$(dirname "$f"):$PATH" && echo "using $f"
done
command -v protoc >/dev/null && export PROTOC="$(command -v protoc)"
command -v cmake >/dev/null || echo "WARNING: cmake not found"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"

echo "== 1. bundled xodus-cli"
BUNDLED=$(find "$WORK/blackwell-launcher" /Applications "$HOME/Applications" -path "*BlackwellLauncher.app/Contents/Resources/xodus-cli" -type f 2>/dev/null | head -1)
echo "BUNDLED=$BUNDLED"
if [ -z "$BUNDLED" ]; then
    # no packaged launcher: the xodus-cli in use is the one built in a work tree
    for d in xodus xodus-ferestre; do
        [ -f "$WORK/$d/target/release/xodus-cli" ] && BUNDLED="$WORK/$d/target/release/xodus-cli" && break
    done
    echo "no BlackwellLauncher.app; using BUNDLED=$BUNDLED"
fi
[ -n "$BUNDLED" ] || { echo "STOP: no xodus-cli found"; exit 1; }

if [ "${1:-}" = "--undo" ]; then
    cp "$BUNDLED.pre-fh6-named.bak" "$BUNDLED" && echo "xodus-cli restored"
    for r in $(find "$WORK" -maxdepth 6 -path "*crates/xodus-cli/src/commands/run.rs.pre-fh6-named.bak" 2>/dev/null); do
        cp "$r" "${r%.pre-fh6-named.bak}" && echo "restored ${r%.pre-fh6-named.bak}"; done
    exit 0
fi
B_SHA=$(shasum -a 256 "$BUNDLED" | cut -d' ' -f1); echo "bundled sha256 $B_SHA"

echo "== 2. which xodus source built it"
SRC=""
for d in xodus-ferestre xodus xodus-nexus-ref; do
    [ -f "$WORK/$d/crates/xodus-cli/src/commands/run.rs" ] || continue
    for t in "$WORK/$d/target/release/xodus-cli" "$WORK/$d/target/x86_64-apple-darwin/release/xodus-cli" "$WORK/$d/target/aarch64-apple-darwin/release/xodus-cli"; do
        [ -f "$t" ] || continue
        s=$(shasum -a 256 "$t" | cut -d' ' -f1); echo "$t $s"
        [ "$s" = "$B_SHA" ] && SRC="$WORK/$d" && BUILT="$t"
    done
done
if [ -z "$SRC" ]; then
    for d in xodus-ferestre xodus; do [ -f "$WORK/$d/crates/xodus-cli/src/commands/run.rs" ] && SRC="$WORK/$d" && break; done
    BUILT="$SRC/target/release/xodus-cli"
    echo "no exact match; using $SRC"
fi
echo "SRC=$SRC"
file "$BUNDLED"

echo "== 3. edit run.rs"
RUN="$SRC/crates/xodus-cli/src/commands/run.rs"
[ -f "$RUN.pre-fh6-named.bak" ] || cp "$RUN" "$RUN.pre-fh6-named.bak"
python3 "$REPO/tools/mac_replace_make_temp_file.py" "$RUN" || { echo "STOP: could not edit run.rs"; exit 1; }

[ -f "$BUNDLED.pre-fh6-named.bak" ] || cp "$BUNDLED" "$BUNDLED.pre-fh6-named.bak"
echo "== 4. build"
TARGET_ARGS=""
case "$BUILT" in */x86_64-apple-darwin/*) TARGET_ARGS="--target x86_64-apple-darwin";; */aarch64-apple-darwin/*) TARGET_ARGS="--target aarch64-apple-darwin";; esac
(cd "$SRC" && cargo build --release -p xodus-cli $TARGET_ARGS) || { echo "STOP: build failed"; exit 1; }
grep -q "xodus-image-" "$BUILT" || { echo "STOP: built xodus-cli lacks the fix"; exit 1; }

echo "== 5. install into the app (backup first)"
[ -f "$BUNDLED.pre-fh6-named.bak" ] || cp "$BUNDLED" "$BUNDLED.pre-fh6-named.bak"
[ "$BUILT" = "$BUNDLED" ] || cp "$BUILT" "$BUNDLED"; codesign --force -s - "$BUNDLED" 2>&1 | tail -1
shasum -a 256 "$BUNDLED" "$BUNDLED.pre-fh6-named.bak"
echo "== done"
