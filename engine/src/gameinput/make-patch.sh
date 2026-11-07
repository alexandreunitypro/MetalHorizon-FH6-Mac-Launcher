#!/bin/bash
# Regenerates engine/patches/0012-gameinput-xinput-backend.patch from this folder: gameinput.c and Makefile.in
# against the CrossOver 26.3 originals kept beside them (*.orig).
#   bash engine/src/gameinput/make-patch.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/../../patches/0012-gameinput-xinput-backend.patch"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/a/dlls/gameinput" "$T/b/dlls/gameinput"
cp "$HERE/gameinput.c.orig" "$T/a/dlls/gameinput/gameinput.c"
cp "$HERE/Makefile.in.orig" "$T/a/dlls/gameinput/Makefile.in"
cp "$HERE/gameinput.c" "$T/b/dlls/gameinput/gameinput.c"
cp "$HERE/Makefile.in" "$T/b/dlls/gameinput/Makefile.in"
{
    cat <<'EOF'
GameInput on top of XInput, the desktop key state and the cursor (WINE_GAMEINPUT=1).

Games built with Microsoft's GDK read controllers through GameInput, and Wine's gameinput.dll was a stub
(GameInputCreate returned E_NOTIMPL), so a GDK game saw no controller at all while XInput saw it. Serves the
v0, v1 and v2 interfaces from XInput 1.4 (four pads: Xbox pads directly, the others through winebus.sys and
SDL2), plus one keyboard and one mouse. Off unless WINE_GAMEINPUT=1, which keeps every tested game as it was.
Source: engine/src/gameinput/ (MetalHorizon), LGPL-2.1-or-later like Wine.

EOF
    ( cd "$T" && diff -ruN a b || true )
} > "$OUT"
echo "$OUT"
