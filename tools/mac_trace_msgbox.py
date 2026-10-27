#!/usr/bin/env python3
"""Diagnostic only: in dlls/user32/msgbox.c (MSGBOX_OnInit), log the caption and the full text of every
message box with ERR, in 100-character pieces, so a box that macOS draws unreadable can be read from
the log."""
import re, sys
path = sys.argv[1]
src = open(path).read()
if "FH6 message box" in src:
    print("already applied"); sys.exit(0)
m = re.search(r'\n([ \t]*)SetWindowTextW\(\s*GetDlgItem\(\s*hwnd,\s*MSGBOX_IDTEXT\s*\),\s*([A-Za-z_][A-Za-z_0-9>.-]*)\s*\);\n', src)
if not m:
    print("STOP: SetWindowTextW(GetDlgItem(hwnd, MSGBOX_IDTEXT), ...) not found"); sys.exit(1)
i, text = m.group(1), m.group(2)
cap = re.search(r'SetWindowTextW\(\s*hwnd,\s*([A-Za-z_][A-Za-z_0-9>.-]*)\s*\);', src[:m.start()])
capexpr = cap.group(1) if cap else "NULL"
add = (f'{i}{{\n'
       f'{i}    /* FH6 diagnostic */\n'
       f'{i}    const WCHAR *fh6_t = {text};\n'
       f'{i}    int fh6_n = fh6_t ? lstrlenW( fh6_t ) : 0, fh6_i;\n'
       f'{i}    ERR( "FH6 message box caption %s, %d chars\\n", debugstr_w({capexpr}), fh6_n );\n'
       f'{i}    for (fh6_i = 0; fh6_i < fh6_n; fh6_i += 100)\n'
       f'{i}        ERR( "FH6 message box text[%d] %s\\n", fh6_i, debugstr_wn( fh6_t + fh6_i, min( 100, fh6_n - fh6_i ) ) );\n'
       f'{i}}}\n')
src = src[:m.end()] + add + src[m.end():]
open(path, "w").write(src)
print("msgbox.c updated (text=%s caption=%s)" % (text, capexpr))
