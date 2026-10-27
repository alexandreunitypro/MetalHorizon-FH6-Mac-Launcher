#!/bin/bash
# Write app/components.json: what MetalHorizon downloads by itself, pinned by SHA-256.
#   bash app/update-components.sh <release tag> <blackwell-engine-*.tar.xz> <d3dmetal-*-redist.tar.xz>
# The tarballs are the assets of the GitHub release <tag> of this repository (engine/package.sh and
# engine/package-d3dmetal.sh make them). build-app.sh copies the file into the app.
set -euo pipefail
cd "$(dirname "$0")"
TAG="${1:?usage: app/update-components.sh <tag> <engine tarball> <d3dmetal tarball>}"; ENGINE="${2:?}"; D3DM="${3:?}"
REPO_URL="https://github.com/alexandreunitypro/blackwell-engine"   # public: the app downloads from its releases
python3 -I - "$TAG" "$ENGINE" "$D3DM" "$REPO_URL" > components.json <<'PY'
import hashlib, json, os, re, sys
tag, engine, d3dm, repo = sys.argv[1:5]
def entry(path, cid, name, folder, license=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 22), b""): h.update(chunk)
    base = os.path.basename(path)
    version = re.sub(r"^(blackwell-engine-|d3dmetal-)|(-redist)?\.tar\.xz$", "", base)
    e = {"id": cid, "name": name, "version": version, "url": "%s/releases/download/%s/%s" % (repo, tag, base),
         "sha256": h.hexdigest(), "size": os.path.getsize(path), "folder": folder, "root": folder}
    if license: e["license"] = license
    return e
print(json.dumps({"components": [
    entry(engine, "engine", "Blackwell Engine", "Blackwell Engine"),
    entry(d3dm, "d3dmetal", "D3DMetal (Apple)", "D3DMetal", "License.rtf")]}, indent=2))
PY
cat components.json
