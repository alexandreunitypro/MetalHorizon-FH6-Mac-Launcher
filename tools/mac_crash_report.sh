#!/bin/bash
# Read-only. What the last run's log says about a crash ("Unhandled page fault ..."): the faulting address, which loaded
# module it falls in (needs a run with +loaddll), the function there when the build tree has debug info, the lines
# just before, and the usual suspects (Metal / D3DMetal errors). The report is copied to the clipboard (Cmd+V in the chat).
# Run it after the game has been closed and the launcher has printed its summary (that is when out/fh6-small.log is written).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
BUILD="$WORK/crossover-source/build-x64-cross"
LOG="$REPO/out/fh6-small.log"; [ -f "$LOG" ] || LOG="$REPO/out/fh6-after.log"
OUT="$REPO/out/crash-report.txt"
NOISE='FHTRACE|fixme|opentype|open_mapped_image_file|no mapped image|get_memory_section_name'
[ -f "$LOG" ] || { echo "STOP: pas de journal ($LOG)"; exit 1; }
{
echo "journal: $LOG  $(ls -l "$LOG" | awk '{print $6,$7,$8}')  lignes: $(wc -l < "$LOG")"
echo "=== lignes d'exception (10 max)"
grep -n "Unhandled\|page fault\|c0000005\|Backtrace\|Register dump" "$LOG" | grep -v FHTRACE | cut -c1-230 | head -10
python3 - "$LOG" <<'PY'
import re, sys
log = open(sys.argv[1], errors="replace").read().split("\n")
rip = fault = None
for l in log:
    m = re.search(r"Unhandled .*? access to (?:0x)?([0-9A-Fa-f]+) at address (?:0x)?([0-9A-Fa-f]+)", l)
    if m: fault, rip = int(m.group(1), 16), int(m.group(2), 16); break
    m = re.search(r"Unhandled .*? access to (?:0x)?([0-9A-Fa-f]+)", l)       # execute fault: the address is the rip
    if m: fault = rip = int(m.group(1), 16); break
mods = []
for l in log:
    m = re.search(r'Loaded L"([^"]+)" at ([0-9A-Fa-f]{8,16}): (\w+)', l)
    if m: mods.append((int(m.group(2), 16), m.group(1).replace("\\\\", "\\"), m.group(3)))
print("=== adresse fautive: %s   adresse accedee: %s   modules connus (+loaddll): %d" %
      (hex(rip) if rip else "inconnue", hex(fault) if fault is not None else "?", len(mods)))
if rip and mods:
    below = [m for m in mods if m[0] <= rip]
    if below:
        base, path, kind = max(below)
        print("module le plus probable: %s (%s) base %s, decalage (RVA) %s" % (path, kind, hex(base), hex(rip - base)))
        print("RIPMOD=%s RVA=%s" % (path.split("\\")[-1], hex(rip - base)), file=sys.stderr)
    else:
        print("aucun module charge sous cette adresse")
elif rip:
    print("pas de lignes +loaddll dans ce journal : relancer avec FH6_DEBUG=\"err+all,+loaddll\" pour savoir dans quelle DLL")
PY
echo "=== 25 lignes avant la premiere exception (sans bruit)"
U=$(grep -n "Unhandled" "$LOG" | head -1 | cut -d: -f1)
[ -n "${U:-}" ] && sed -n "$((U>1500?U-1500:1)),${U}p" "$LOG" | grep -vE "$NOISE" | cut -c1-220 | tail -25
echo "=== erreurs frequentes dans tout le journal (hors bruit), les 12 plus nombreuses"
grep ":err:" "$LOG" | grep -vE "$NOISE" | sed -E 's/^[0-9a-f]+:err://; s/0x[0-9a-fA-F]+|[0-9a-fA-F]{8,}/N/g' | cut -c1-140 | sort | uniq -c | sort -rn | head -12
echo "=== Metal / D3DMetal"
echo "pipelines refusees: $(grep -c 'Failed to create pipeline state' "$LOG")   D3DMetal Unsupported: $(grep -c 'D3DMetal Unsupported' "$LOG")"
grep -m3 "D3DMetal Unsupported\|MTL\|Metal" "$LOG" | cut -c1-200
echo "=== 20 dernieres lignes (sans bruit)"
grep -vE "$NOISE" "$LOG" | cut -c1-220 | tail -20
} 2> "$REPO/out/crash-report.rip" > "$OUT"

# best effort: function name at the faulting address, from the UNSTRIPPED build-tree DLL (needs llvm-addr2line)
RIPLINE=$(grep '^RIPMOD=' "$REPO/out/crash-report.rip" | head -1)
if [ -n "$RIPLINE" ]; then
    MOD=$(echo "$RIPLINE" | sed 's/^RIPMOD=\([^ ]*\) .*/\1/' | tr 'A-Z' 'a-z'); RVA=$(echo "$RIPLINE" | sed 's/.*RVA=//')
    A2L=$(find "$WORK/toolchains" -name "llvm-addr2line" 2>/dev/null | head -1)
    DLL=$(find "$BUILD/dlls" -iname "$MOD" -path "*x86_64-windows*" 2>/dev/null | head -1)
    {
    echo "=== fonction a cette adresse (DLL du dossier de compilation, avec symboles si disponibles)"
    if [ -n "$A2L" ] && [ -n "$DLL" ]; then
        IB=$(find "$WORK/toolchains" -name "llvm-readobj" 2>/dev/null | head -1)
        BASE=$("$IB" --file-headers "$DLL" 2>/dev/null | awk '/ImageBase/ {print $2; exit}')
        ADDR=$(python3 -c "print(hex(int('${BASE:-0x0}',16) + int('$RVA',16)))")
        echo "$DLL   ImageBase ${BASE:-?}   RVA $RVA"
        "$A2L" -f -C -i -e "$DLL" "$ADDR" 2>&1 | head -8
    else
        echo "(pas de llvm-addr2line ou pas de DLL '$MOD' dans le dossier de compilation)"
    fi
    } >> "$OUT"
fi
rm -f "$REPO/out/crash-report.rip"
wc -l "$OUT"
pbcopy < "$OUT"
echo "== RAPPORT COPIE : colle-le dans le chat (Cmd+V)"
