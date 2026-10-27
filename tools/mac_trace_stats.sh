#!/bin/bash
# Frame pacing and shader-compile statistics from two WHOLE tables of a finished Metal System Trace (two xctrace exports,
# one after the other; each takes minutes). Tables (names read from the trace): ca-client-presented-handler (one row per
# displayed frame) and graphics-compiler-activity-intervals (shader compilation). The report is short (3 KB) and is copied
# to the clipboard. Run it ONCE; read-only on the trace.   Usage: bash tools/mac_trace_stats.sh [trace path]
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO/out" || exit 1
XCT="$(xcrun -f xctrace 2>/dev/null)"; [ -n "$XCT" ] || { echo "STOP: xctrace absent"; exit 1; }
pgrep -f "xctrace (record|export)" >/dev/null && { echo "STOP: xctrace tourne deja (record ou export). Attends ou arrete-le."; exit 1; }
T="${1:-$(ls -td "$REPO"/out/metal-*.trace 2>/dev/null | head -1)}"
[ -n "$T" ] && [ -e "$T" ] || { echo "STOP: pas de trace dans out/"; exit 1; }
MAXWAIT="${MAXWAIT:-1500}"
export_table() {   # schema output
    echo "export de $1 (peut prendre plusieurs minutes, max $((MAXWAIT/60)) min)..."
    "$XCT" export --input "$T" --xpath "/trace-toc/run[1]/data/table[@schema=\"$1\"]" > "$2" 2> "$2.err" &
    local pid=$! w=0
    while kill -0 "$pid" 2>/dev/null; do sleep 5; w=$((w+5)); [ "$w" -ge "$MAXWAIT" ] && { kill "$pid" 2>/dev/null; echo "  abandon apres $((w/60)) min"; break; }; done
    echo "  -> $(wc -c < "$2") octets"
}
export_table ca-client-presented-handler trace-presented.xml
export_table graphics-compiler-activity-intervals trace-compile.xml
python3 - trace-presented.xml trace-compile.xml <<'PY' | tee trace-stats.txt
import re, sys
def rows(p):
    try: return re.findall(r"<row>(.*?)</row>", open(p, errors="replace").read(), re.S)
    except OSError: return []
def pct(v, q): return v[min(len(v) - 1, int(q * len(v)))] if v else float("nan")
pres = rows(sys.argv[1]); ts = []
for r in pres:
    m = re.search(r"<start-time[^>]*>(\d+)</start-time>", r)
    if m: ts.append(int(m.group(1)))
ts.sort()
print("== images affichees: %d lignes" % len(ts))
if len(ts) > 3:
    d = [(b - a) / 1e6 for a, b in zip(ts, ts[1:])]; s = sorted(d)
    span = (ts[-1] - ts[0]) / 1e9
    print("duree couverte: %.1f s   images/s moyen: %.1f" % (span, len(d) / span if span else 0))
    print("intervalle entre images (ms): mediane %.1f  p90 %.1f  p95 %.1f  p99 %.1f  max %.1f" % (pct(s, .5), pct(s, .9), pct(s, .95), pct(s, .99), s[-1]))
    print("ecran 120 Hz = 8,33 ms par rafraichissement. Repartition par nombre de rafraichissements:")
    bins = [(9, "1 (120 i/s)"), (17.5, "2 (60)"), (25.9, "3 (40)"), (34.2, "4 (30)"), (42.5, "5 (24)"), (51, "6 (20)"), (67, "7-8"), (1e9, "9+ (<15 i/s)")]
    prev = 0
    for hi, lab in bins:
        n = sum(1 for x in d if prev < x <= hi); print("  %-14s %5d  (%4.1f %%)" % (lab, n, 100.0 * n / len(d))); prev = hi
    j = sum(1 for a, b in zip(d, d[1:]) if abs(a - b) > 6); print("changements de rythme d'une image a l'autre (>6 ms): %d sur %d (%.0f %%)" % (j, len(d) - 1, 100.0 * j / max(1, len(d) - 1)))
    big = sorted(((x, (ts[i] - ts[0]) / 1e9) for i, x in enumerate(d) if x > 50), reverse=True)[:6]
    print("plus longs intervalles >50 ms (ms @ seconde): " + ", ".join("%.0f@%.1f" % (x, t) for x, t in big) if big else "aucun intervalle > 50 ms")
comp = rows(sys.argv[2]); items = []
for r in comp:
    t = re.search(r"<start-time[^>]*>(\d+)</start-time>", r); du = re.search(r"<duration[^>]*>(\d+)</duration>", r)
    lab = re.search(r'<formatted-label[^>]*fmt="([^"]*)"', r)
    if t and du: items.append((int(t.group(1)) / 1e9, int(du.group(1)) / 1e6, (lab.group(1) if lab else "?").split(" (wine")[0]))
print("\n== compilations de shaders: %d evenements" % len(items))
if items:
    tot = sum(x[1] for x in items); print("temps total de compilation: %.1f ms   plus long: %.1f ms" % (tot, max(x[1] for x in items)))
    kinds = {}
    for _, du, lab in items: k = re.sub(r"[0-9a-fx]+$", "", lab).strip(); kinds[k] = kinds.get(k, [0, 0.0]); kinds[k][0] += 1; kinds[k][1] += du
    for k, (n, du) in sorted(kinds.items(), key=lambda x: -x[1][1])[:6]: print("  %-32s %5d   %.1f ms" % (k[:32], n, du))
    t0 = min(x[0] for x in items); b = {}
    for t, du, _ in items: b[int((t - t0) // 5)] = b.get(int((t - t0) // 5), 0) + 1
    print("evenements par tranche de 5 s: " + " ".join("%d:%d" % (k, v) for k, v in sorted(b.items())))
    print("les 4 plus longs (ms @ seconde): " + ", ".join("%.1f@%.1f" % (du, t) for t, du, _ in sorted(items, key=lambda x: -x[1])[:4]))
PY
pbcopy < trace-stats.txt; echo "== RAPPORT COPIE : Cmd+V dans le chat"
