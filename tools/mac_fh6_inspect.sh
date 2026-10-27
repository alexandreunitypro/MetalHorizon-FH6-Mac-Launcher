#!/bin/bash
# Report, in French, on the last game run made with the shim's inspector (HB_TSSHIM_INSPECT=1, tools/tsshim/inspect.c):
# what was created and what failed, which pipelines' draws write no pixel and at which step their pixels are lost,
# crashes and errors from the Wine log of the same run. Written to out/inspect-report.txt. Reads only.
# Usage: bash tools/mac_fh6_inspect.sh [inspect log] [wine log, default out/fh6-after.log]
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="$HOME/FH6/.blackwell-wine/drive_c/highball/logs"
ILOG="${1:-$(ls -t "$LOGS"/inspect-*.log 2>/dev/null | head -1)}"
WLOG="${2:-$REPO/out/fh6-after.log}"
[ -n "$ILOG" ] && [ -f "$ILOG" ] || { echo "no inspector log in $LOGS (launch with HB_TSSHIM_INSPECT=1)"; exit 1; }
python3 "$REPO/tools/mac_fh6_inspect.py" --wine "$WLOG" --out "$REPO/out/inspect-report.txt" "$ILOG"
echo "(report kept in out/inspect-report.txt)"
