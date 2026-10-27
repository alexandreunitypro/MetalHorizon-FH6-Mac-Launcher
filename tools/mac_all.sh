#!/bin/bash
# One-shot: apply every fix not yet applied, launch the game, print a short report
# (also saved to out/report.txt and copied to the clipboard).
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1
R="$REPO/out/report.txt"; mkdir -p out
{
echo "== fixes"
bash tools/mac_setup_tsshim.sh 2>&1 | grep -E "STOP|done|marked|export name|shim ready|using" | tail -6
bash tools/mac_apply_forza_patches.sh 2>&1 | grep -E "STOP|done|version|using|failed|not in" | tail -8
bash tools/mac_move_short.sh 2>&1 | tail -2
bash tools/mac_fix_leaf_unwind.sh 2>&1 | grep -E "STOP|done|already|updated|using|error" | tail -8
bash tools/mac_fix_fonts.sh 2>&1 | tail -1
bash tools/mac_trace_msgbox.sh 2>&1 | grep -E "STOP|done|already|error" | tail -3
bash tools/mac_trace_null_call.sh 2>&1 | grep -E "STOP|done|already|error" | tail -5
echo "== game (max ${1:-150}s)"
FH6_DEBUG="${FH6_DEBUG:-+timestamp,+loaddll,warn+process,warn+seh,+seh,+unwind,+win,+dialog,err+all}" bash tools/mac_launch_fh6.sh "${1:-150}" 2>&1 | sed -n '/== summary/,/-- last 25/p' | head -16
L=out/fh6-small.log; [ -s "$L" ] || L=out/fh6-after.log
echo "== path the game sees"
grep -m1 -o "env=15:[^|]*" "$L"
echo "== crash"
grep -n -m8 "Unhandled\|start_debugger\|personality routine\|unwinding as leaf\|terminating itself\|exe:4" "$L" | cut -c1-200
n=$(grep -n -m1 "Unhandled" "$L" | cut -d: -f1)
[ -n "$n" ] && sed -n "$((n>25?n-25:1)),${n}p" "$L" | grep -v "FHTRACE\|ILLEGAL_INSTRUCTION\|c000001d\|call_vectored\|segv_handler\|dispatch_exception r\|sigsys" | cut -c1-200
echo "== windows created by the game (class, name, size)"
grep "NtUserCreateWindowEx" "$L" | sed -E 's/.*NtUserCreateWindowEx //' | cut -c1-200 | awk '!seen[$0]++' | head -25
echo "== fonts (a message box drawn as a thin pill usually means no usable font)"
P=/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/audit/gamefarm-audit/.blackwell-wine
E=/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine
echo "prefix Fonts: $(ls "$P/drive_c/windows/Fonts" 2>/dev/null | wc -l | tr -d ' ') files; engine fonts: $(ls "$E/share/wine/fonts" 2>/dev/null | wc -l | tr -d ' ') files"
grep -m5 -i "font" "$L" | grep -v ":seh:" | cut -c1-160
echo "== dialog texts (message boxes and warnings)"
grep "WIN_CreateWindowEx L\"" "$L" | grep -v 'WIN_CreateWindowEx L""' | grep "Static\|#32770" | sed 's/.*WIN_CreateWindowEx //; s/ L"[^"]*"->.*//' | awk '!s[$0]++' | head -8
grep -m1 "DXGI\|adapter.*desc\|D3DM_DEVICE" "$L" | cut -c1-160
echo "== MESSAGE BOX TEXT"
grep "FH6 message box" "$L" | sed -E "s/.*FH6 message box //" | head -20
grep -m3 "DIALOG_CreateIndirect units" "$L" | cut -c1-120
echo "== tsshim log (shader-model hook, pipelines compiled)"
TL=$(ls -t "$HOME/FH6/.blackwell-wine/drive_c/highball/logs/"tsshim-*.log 2>/dev/null | head -1)
if [ -n "$TL" ]; then echo "file: $TL ($(wc -l < "$TL") lines)"; grep -iE "SHADER_MODEL|ResolveSubresource|pipeline|CreateQueryHeap" "$TL" | awk '!s[$0]++' | tail -10; fi
grep -iE "tsshim\[" "$L" | grep -iE "SHADER_MODEL|ResolveSubresource|pipeline|CheckFeatureSupport|loaded in front" | awk '!s[$0]++' | tail -10
echo "== GetIntegratedDisplaySize / sign-in"
grep -iE "GetIntegratedDisplaySize|unimplemented function|microsoft.com|device code|user_code|DeviceKey" "$L" | grep -iv FHTRACE | cut -c1-150 | tail -6 || echo "(none)"
echo "== last window created"
grep "WIN_CreateWindowEx L\"" "$L" 2>/dev/null | grep -v 'WIN_CreateWindowEx L""' | sed "s/.*WIN_CreateWindowEx //; s/ L\"[A-Za-z#0-9.!]*\"->.*//" | awk '!s[$0]++' | tail -6
echo "== xodus-service (Xbox token helper)"
bash tools/mac_xodus_service.sh status 2>&1 | head -12
echo "== d3d12 loaded"
grep -i "Loaded.*\(d3d12\|apd12\|dxgi\)" "$L" | sed 's/.*Loaded L"//; s/" at .*//' | sed 's#.*\\##' | head -6
echo "== PE files naming Win32DispatchInit"
E=/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work/crossover-source/out-x64/engine
for f in "$E"/lib64/apple_gptk/wine/x86_64-windows/*.dll "$E"/renderers/d3dmetal-tsshim/wine/x86_64-windows/*.dll; do
    c=$(strings -a "$f" | grep -c "Win32DispatchInit\|D3DMThreadInit"); [ "$c" != 0 ] && echo "$(basename "$f"): $c"
done
echo "== null call"
grep -m12 "FH6 null call" "$L" | cut -c1-220
bash tools/mac_symbolize_null.sh
} 2>&1 | tee "$R"
pbcopy < "$R" && echo "== RAPPORT COPIE : colle-le dans le chat (Cmd+V)"
