#!/bin/bash
# Takes a SMALL text sample out of a (possibly huge) Metal System Trace made by tools/mac_metal_trace.sh, using
# Apple's own `xctrace export`. Step 1: the table of contents (which tables exist). Step 2: for a few tables that look
# useful (GPU intervals, command buffers, shader compilation, frames/present, driver events), the column definitions
# and the first rows, each capped. The report (about 40 KB max) is copied to the clipboard: Cmd+V in the chat.
# Run it ONCE (two copies at the same time fight over RAM and over the same output files).
# Needs the recording to be FINISHED (no xctrace running). Read-only on the trace; writes only out/trace-sample*.
# Usage: bash tools/mac_trace_sample.sh [trace path]   (default: newest out/metal-*.trace)
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
XCT="$(xcrun -f xctrace 2>/dev/null)"; [ -n "$XCT" ] || { echo "STOP: xctrace absent (Xcode non selectionne)"; exit 1; }
if pgrep -f "xctrace record" >/dev/null; then echo "STOP: xctrace enregistre encore. Attends la fin (ou Ctrl+C dans sa fenetre), puis relance."; exit 1; fi
if pgrep -f "xctrace export" >/dev/null; then echo "STOP: une extraction tourne deja (xctrace export). Ne lance pas deux fois cet outil."; exit 1; fi
T="${1:-$(ls -td "$REPO"/out/metal-*.trace 2>/dev/null | head -1)}"
[ -n "$T" ] && [ -e "$T" ] || { echo "STOP: pas de trace"; exit 1; }
OUT="$REPO/out/trace-sample.txt"; TOC="$REPO/out/trace-sample.toc.xml"
{
echo "trace: $T   taille: $(du -sh "$T" | cut -f1)   $(df -h / | tail -1 | awk '{print "libre sur le disque: " $4}')"
echo "== 1. table des matieres"
"$XCT" export --input "$T" --toc > "$TOC" 2>"$REPO/out/trace-sample.err"
echo "toc: $(wc -c < "$TOC") octets   erreurs: $(head -c 300 "$REPO/out/trace-sample.err" | tr '\n' ' ')"
echo "run(s) / process(es):"; grep -o '<process [^>]*>' "$TOC" | cut -c1-160 | head -6
echo "tables (schema):"; grep -o 'table schema="[^"]*"' "$TOC" | sed 's/table schema=//' | sort | uniq -c | sort -rn | head -60
echo
for pat in 'gpu-interval' 'command-buffer' 'compil|present|frame'; do   # 3 exports at most: each one reloads the trace (minutes, GBs of RAM)
    S=$(grep -o 'table schema="[^"]*"' "$TOC" | sed 's/table schema="//; s/"$//' | sort -u | grep -E "$pat" | head -1)
    for s in $S; do
        echo "== table: $s"
        "$XCT" export --input "$T" --xpath "/trace-toc/run[1]/data/table[@schema=\"$s\"]" 2>/dev/null | head -c 6000 > "$REPO/out/trace-sample.$s.xml"
        echo "colonnes:"; grep -o '<mnemonic>[^<]*</mnemonic>' "$REPO/out/trace-sample.$s.xml" | sed 's/<[^>]*>//g' | tr '\n' ' ' | cut -c1-400; echo
        echo "premieres lignes:"; grep -o '<row>.*' "$REPO/out/trace-sample.$s.xml" | head -3 | cut -c1-700
        grep -c '<row>' "$REPO/out/trace-sample.$s.xml" | sed 's/^/lignes dans cet echantillon (6 Ko): /'
    done
done
} 2>&1 | head -c 40000 > "$OUT"
wc -c "$OUT"; pbcopy < "$OUT"; echo "== ECHANTILLON COPIE : colle-le dans le chat (Cmd+V)"
