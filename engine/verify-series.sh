#!/bin/bash
# Proves the recipe reproduces the dev tree: applies engine/series to the pinned sources (engine/build.sh
# --source-only) and compares the result with the tree the working engine was built from.
#   bash engine/verify-series.sh <dev sources/wine> [--tarball <crossover-sources-26.3.0.tar.gz>] [work folder]
# Allowed to differ: configure (the dev tree regenerated it with another autoconf; the series only adds
# the new DLLs' lines, checked below), the tests folders (not built) and backup files.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEV="${1:?usage: engine/verify-series.sh <dev sources/wine> [build.sh options] [work folder]}"; shift
OUT="$(bash "$REPO/engine/build.sh" --source-only "$@")" || { echo "$OUT"; exit 1; }
echo "$OUT"
SRC="$(echo "$OUT" | sed -n 's/^patched sources: //p')"
diffs="$(diff -rq -x '*.bak' -x '*.pre-*' -x '*.orig' -x '*.rej' -x autom4te.cache -x 'configure~' \
    -x configure.before-xgameruntime -x configure -x tests "$SRC" "$DEV" || true)"
missing=0
while IFS= read -r line; do
    grep -qxF -- "$line" "$SRC/configure" || { echo "configure lacks: $line"; missing=1; }
done < <(awk '/^--- a\/configure$/{p=1; next} /^--- /{p=0} p && /^\+[^+]/{print substr($0, 2)}' \
    "$REPO/engine/patches/0001-xgameruntime.patch")
grep -q 'wine_fn_config_makefile dlls/xgameruntime' "$DEV/configure" || { echo "the dev configure has no xgameruntime"; missing=1; }
if [ -z "$diffs" ] && [ "$missing" = 0 ]; then
    echo "IDENTICAL: the series reproduces $DEV ($(find "$SRC" -type f | wc -l | tr -d ' ') files compared)"
else
    echo "$diffs"; echo "DIFFERENT"; exit 1
fi
