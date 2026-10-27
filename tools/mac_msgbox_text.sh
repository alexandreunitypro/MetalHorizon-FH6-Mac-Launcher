#!/bin/bash
# Read-only: the text of the game's message box ("Forza Horizon"), from the +win/+dialog trace.
L="$(cd "$(dirname "$0")/.." && pwd)/out/fh6-after.log"
T=$(grep -m1 "Using message box font" "$L" | cut -d: -f1)
echo "== message box created at $T"
grep ":dialog:\|window_name L" "$L" | grep -v 'window_name (null)' | grep -v "Default IME\|WineAppBar\|Shell_TrayWnd" | sed -E 's/^[0-9.]+:[0-9a-f]+:trace:[a-z]+://' | cut -c1-300 | awk '!s[$0]++' | head -30
