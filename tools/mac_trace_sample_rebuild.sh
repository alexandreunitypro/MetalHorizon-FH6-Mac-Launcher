#!/bin/bash
# Rebuilds the trace report from the files that tools/mac_trace_sample.sh leaves in out/ (trace-sample.toc.xml and one
# trace-sample.<schema>.xml per table), WITHOUT running xctrace. Use it when out/trace-sample.txt came out empty (two copies
# of the sampler ran at once and one truncated it). Read-only. The report (40 KB max) is copied to the clipboard.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO/out" || exit 1
OUT="$REPO/out/trace-sample-rebuilt.txt"
{
echo "fichiers intermediaires dans out/:"; ls -la trace-sample* 2>/dev/null | awk '{print $5, $9}' | head -30
if [ -s trace-sample.toc.xml ]; then
    echo "== table des matieres: $(wc -c < trace-sample.toc.xml) octets"
    echo "process(es):"; grep -o '<process [^>]*>' trace-sample.toc.xml | cut -c1-160 | head -6
    echo "tables (schema, nombre):"; grep -o 'table schema="[^"]*"' trace-sample.toc.xml | sed 's/table schema=//' | sort | uniq -c | sort -rn | head -80
else
    echo "(pas de table des matieres: trace-sample.toc.xml absent ou vide)"
fi
for f in trace-sample.*.xml; do
    [ "$f" = "trace-sample.toc.xml" ] && continue
    [ -s "$f" ] || { echo "== $f: VIDE"; continue; }
    echo "== $f ($(wc -c < "$f") octets)"
    echo "colonnes:"; grep -o '<mnemonic>[^<]*</mnemonic>' "$f" | sed 's/<[^>]*>//g' | tr '\n' ' ' | cut -c1-500; echo
    echo "premieres lignes:"; grep -o '<row>.*' "$f" | head -3 | cut -c1-800
done
} 2>&1 | head -c 40000 > "$OUT"
wc -c "$OUT"; pbcopy < "$OUT"; echo "== RAPPORT COPIE (presse-papiers) : Cmd+V dans le chat"
