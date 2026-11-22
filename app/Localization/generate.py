#!/usr/bin/env python3
# Builds app/Localization/<language>.lproj/Localizable.strings from batches/*.json (one list of translations per
# language, in the order of en-keys.json, the English texts). Checks that each translation keeps the same values
# (%@, %lld) and is not empty. Run: python3 app/Localization/generate.py. build-app.sh copies the .lproj folders.
import json, glob, re, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
keys = json.load(open(f"{HERE}/en-keys.json"))
out = HERE
ph = lambda s: sorted(re.findall(r'%(?:lld|@)', s))
def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
langs = {}
for f in sorted(glob.glob(f"{HERE}/batches/batch*.json")):
    langs.update(json.load(open(f)))
bad = 0
for lang, vals in langs.items():
    if len(vals) != len(keys): print(lang, "count", len(vals)); bad += 1; continue
    for i, (k, v) in enumerate(zip(keys, vals)):
        if ph(k) != ph(v): print(lang, i, "placeholders", repr(v)); bad += 1
        if not v.strip(): print(lang, i, "empty"); bad += 1
if bad: sys.exit(1)
# English too, each text its own translation: without an en.lproj, macOS does not find English among the app's
# languages and shows a Mac set to English another one (2.0 and 2.1, issue #15)
langs["en"] = list(keys)
for lang, vals in langs.items():
    d = f"{out}/{lang}.lproj"; os.makedirs(d, exist_ok=True)
    with open(f"{d}/Localizable.strings", "w") as fh:
        fh.write("/* MetalHorizon's screens. Generated: the English text is the key (see Sources/MetalHorizon/Localization.swift). */\n\n")
        for k, v in zip(keys, vals): fh.write(f'"{esc(k)}" = "{esc(v)}";\n')
print(len(langs), "languages:", " ".join(sorted(langs)))
