#!/bin/bash
# Blackwell Engine: a beta made public. Takes the beta engine that build-beta.sh staged (<work>/out-beta/engine),
# checks it is the beta named, and packages the same files as a public engine. The binaries are unchanged. Its record
# (metalhorizon.json) says public, the version given and "rosettaLine" (MetalHorizon then turns the pacer and the
# Trap Boost on), with the public series, which now holds the beta's patches.
#   bash engine/promote-beta.sh <work folder> <public series> <beta version> <public version> <tarball name>
#   e.g. bash engine/promote-beta.sh ~/BlackwellEngine-build series beta-1.4a2 1.4 blackwell-engine-1.4
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; ENG="$REPO/engine"
W="${1:?work folder}"; SERIES="$ENG/${2:?series file}"; FROM="${3:?beta version}"; V="${4:?public version}"; NAME="${5:?tarball name}"
STAGE="$W/out-beta/engine"; OUT="$W/out-public/engine"
fail() { echo "STOP: $1"; exit 1; }
[ -f "$STAGE/metalhorizon.json" ] || fail "no staged beta in $STAGE (engine/build-beta.sh)"
staged="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$STAGE/metalhorizon.json")"
[ "$staged" = "$FROM" ] || fail "the staged beta is $staged, not $FROM"
[ "$(strings -a "$STAGE/lib/wine/x86_64-unix/ntdll.so" | grep -c "bw-pacer: on")" -gt 0 ] || fail "the staged ntdll.so has no pacer"
grep -qx '0016-ntdll-blackwell-pacer.patch' "$SERIES" || fail "$(basename "$SERIES") does not hold the beta's patches yet"
for p in $(sed -n '/^# --- Beta/,$p' "$ENG/$(basename "$SERIES")" | grep -v '^#' | grep -v '^$'); do fail "$(basename "$SERIES") still has a beta section ($p)"; done

echo "== 1. the beta's files, as they are ($FROM)"
rm -rf "$W/out-public"; mkdir -p "$W/out-public"; ditto "$STAGE" "$OUT"
echo "== 2. its record: public $V"
python3 -I - "$OUT/metalhorizon.json" "$V" "$FROM" "$(cd "$ENG" && cat "$(basename "$SERIES")" patches/*.patch | shasum -a 256 | cut -d' ' -f1)" \
    "$(git -C "$REPO" rev-parse HEAD)" <<'PY'
import json, sys, time
path, version, beta, series, commit = sys.argv[1:6]
d = json.load(open(path))
built_from = d.get("commit", "")
for k in ("beta", "channel"): d.pop(k, None)
d.update({"version": version, "channel": "public", "seriesSha256": series, "commit": commit,
          "promotedFrom": beta, "binariesBuiltFromCommit": built_from,
          "packaged": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
          "rosettaLine": "the Blackwell Pacer (BW_PACER=auto), the Trap Boost (BW_TRAP_BOOST=1) and Highball's 0005, 0014, 0015, 0025, 0028"})
json.dump(d, open(path, "w"), indent=2)
PY
echo "== 3. tarball"
rm -f "$W/$NAME.tar.xz"
tar -C "$W/out-public" -s '|^engine|Blackwell Engine|' -cJf "$W/$NAME.tar.xz" engine
( cd "$W" && shasum -a 256 "$NAME.tar.xz" | tee "$NAME.tar.xz.sha256" )
echo "size: $(stat -f %z "$W/$NAME.tar.xz")"
