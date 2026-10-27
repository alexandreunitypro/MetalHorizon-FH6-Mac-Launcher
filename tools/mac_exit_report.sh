#!/bin/bash
# Read-only, on the last out/fh6-after.log: why the game quit by itself (exit code 0 from the
# xgameruntime thread). Shows the Xbox runtime messages, message boxes, and the thread's last lines.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
L="$REPO/out/fh6-after.log"
F="$REPO/out/fh6-noseh.log"
grep -v ":seh:\|:unwind:\|FHTRACE" "$L" > "$F"
echo "== lines without seh/unwind: $(wc -l < "$F")"
echo "== Xbox runtime / Gaming Services messages (unique)"
grep -i "xgame\|xuser\|xstore\|xbox\|gaming\|xblapi\|xsapi\|appmodel\|package" "$F" | sed -E 's/^[0-9.]+:[0-9a-f]+://' | cut -c1-170 | awk '!s[$0]++' | head -40
echo "== message boxes / windows"
grep -i "MessageBox\|CreateWindowEx\|dialog" "$F" | cut -c1-200 | head -15
echo "== exit"
grep -n "NtTerminateProcess\|exit code" "$F" | tail -5
T=$(grep "terminating itself" "$F" | tail -1 | cut -d: -f2)
echo "== last 50 lines of thread $T before the exit"
grep ":$T:" "$F" | tail -50 | sed -E 's#/Users/[^ ]*/##g' | cut -c1-200
