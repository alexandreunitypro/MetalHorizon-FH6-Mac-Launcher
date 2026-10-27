#!/bin/bash
# Why is the engine sound silent? Reads the out/fh6-small.log of a run made with the audio channels on (see the command in
# the chat) and lists, by how often they occur, the fixme/err/warn lines of the audio stack: XAudio2, X3DAudio, XAPOFX,
# mmdevapi (WASAPI), dsound, winmm, Media Foundation / codecs. A "fixme ... not implemented" there is the usual cause of a
# missing sound. Read-only; the report (about 8 KB) is copied to the clipboard; otherwise: open -e out/audio-report.txt
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"; LOG="$REPO/out/fh6-small.log"; OUT="$REPO/out/audio-report.txt"
[ -f "$LOG" ] || { echo "STOP: pas de journal ($LOG)"; exit 1; }
CH='xaudio2|x3daudio|xapofx|mmdevapi|dsound|winmm|mfplat|mfreadwrite|mf:|wmvcore|wmcodecdsp|msacm|msaudio|audioses|coreaudio|winecoreaudio|xaudio|gameinput|dmusic'
{
echo "journal: $(ls -l "$LOG" | awk '{print $6,$7,$8}')  lignes: $(wc -l < "$LOG")"
echo "=== lignes audio par canal (nombre)"
grep -oE ":(fixme|err|warn|trace):($CH)[a-z0-9_]*:" "$LOG" | sed 's/^://' | sort | uniq -c | sort -rn | head -25
echo "=== fixme / err / warn audio, messages differents (40 plus frequents)"
grep -E ":(fixme|err|warn):($CH)" "$LOG" | sed -E 's/^[0-9a-f]+://; s/0x[0-9a-fA-F]+|[0-9a-fA-F]{8,}/N/g; s/[0-9]+/N/g' | cut -c1-200 | sort | uniq -c | sort -rn | head -40
echo "=== format audio demande / peripherique (mmdevapi, 12 lignes)"
grep -iE "(mmdevapi|coreaudio).*(channel|format|rate|device|spatial)" "$LOG" | cut -c1-190 | awk '!s[$0]++' | head -12
} > "$OUT" 2>&1
wc -c "$OUT"; pbcopy < "$OUT"; echo "== RAPPORT COPIE : Cmd+V dans le chat ; sinon: open -e $OUT"
