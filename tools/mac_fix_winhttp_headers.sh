#!/bin/bash
# Fix for the "Cloud save synchronization failed" box (found with tools/httpprobe).
# Cause: libHttpClient (PlayFab, Xbox services) first asks WinHttpQueryHeaders(WINHTTP_QUERY_RAW_HEADERS_CRLF, buffer=NULL)
# "how big?". Windows answers FALSE with GetLastError() == ERROR_INSUFFICIENT_BUFFER (122) and the size in *buflen.
# On this Wine the probe saw FALSE with GetLastError() == 0. libHttpClient treats anything but 122 as fatal, drops the
# HTTP call at HEADERS_AVAILABLE and returns E_FAIL (0x80004005): the PlayFab login never completes, the save SDK
# reports 0x80004005 and the game shows the Game Saves box (even for "offline" mode).
#
# The source's WinHttpQueryHeaders ends with `SetLastError( ret ); return !ret;`, which cannot give "FALSE + error 0",
# so the installed winhttp.dll may simply not match the source. This script therefore goes in three steps:
#   A. run tools/httpprobe against the DLL that is installed now                       (the "before" picture)
#   B. rebuild winhttp.dll from the UNMODIFIED source, install it (engine + prefix), probe again
#        -> if the size query now gives err=122, the old DLL was stale: done, nothing else is changed
#   C. only if B did not fix it: patch WinHttpQueryHeaders (report ERROR_INSUFFICIENT_BUFFER when the caller's buffer
#        was too small), rebuild, install, probe again
# Backups: request.c, the engine's winhttp.dll and the prefix's winhttp.dll (.pre-qh.bak). Undo: --undo
# If request.c does not look as expected nothing is patched and the function is copied to the clipboard.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"
BUILD="$WORK/crossover-source/build-x64-cross"
ENGINE="$WORK/crossover-source/out-x64/engine"
PFX="${FH6_PREFIX:-$HOME/FH6/.blackwell-wine}"
F="$SRC/dlls/winhttp/request.c"
EDLL="$ENGINE/lib/wine/x86_64-windows/winhttp.dll"
PDLL="$PFX/drive_c/windows/system32/winhttp.dll"
CXLIB="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/lib64"
mkdir -p "$REPO/out"; exec > >(tee "$REPO/out/fix-winhttp.log") 2>&1
REPORT="$REPO/out/fix-winhttp-report.txt"; : > "$REPORT"
note() { echo "$@"; echo "$@" >> "$REPORT"; }

if [ "${1:-}" = "--undo" ]; then
    for f in "$F" "$EDLL" "$PDLL"; do [ -f "$f.pre-qh.bak" ] && cp "$f.pre-qh.bak" "$f" && echo "restored $f"; done
    exit 0
fi
[ -f "$F" ] || { echo "STOP: $F not found"; exit 1; }

info() { for f in "$@"; do [ -f "$f" ] && note "   $(stat -f %z "$f") octets  md5 $(md5 -q "$f")  $(basename "$(dirname "$f")")/$(basename "$f")"; done; }

run_probe() {   # $1 = label ; prints the key lines, returns 0 when the size query gives err=122 everywhere
    local label="$1" log="$REPO/out/httpprobe-$1.log" i PID
    export CX_ROOT="$ENGINE" WINEPREFIX="$PFX" WINEDEBUG="err+all" DYLD_LIBRARY_PATH="$ENGINE/lib:$CXLIB"
    "$ENGINE/bin/wineserver" -k 2>/dev/null
    "$ENGINE/bin/wine" "$REPO/tools/httpprobe/httpprobe.exe" > "$log" 2>/dev/null &
    PID=$!
    for i in $(seq 120); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
    kill "$PID" 2>/dev/null
    "$ENGINE/bin/wineserver" -k 2>/dev/null
    note "-- sonde ($label)"
    { grep "winhttp.dll loaded\|\[sync\]\|SUMMARY" "$log"; grep -m6 "\[callback\]" "$log"; } | cut -c1-200 | while IFS= read -r l; do note "   $l"; done
    local good total
    total=$(grep -c "\[callback\] RAW_HEADERS_CRLF null-buffer:" "$log")
    good=$(grep -c "\[callback\] RAW_HEADERS_CRLF null-buffer: ok=0 err=122 " "$log")
    [ "$total" -ge 1 ] && [ "$good" -eq "$total" ]
}

build_install() {   # rebuilds winhttp.dll from the current request.c and installs it in the engine and the prefix
    export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
    if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
        CC=$(find "$WORK" /opt/homebrew /usr/local /opt -maxdepth 6 \( -name x86_64-w64-mingw32-gcc -o -name x86_64-w64-mingw32-clang \) \( -type f -o -type l \) 2>/dev/null | head -1)
        [ -n "$CC" ] || { echo "STOP: no mingw cross compiler"; return 1; }
        mkdir -p "$REPO/out/cross-bin"; ln -sf "$CC" "$REPO/out/cross-bin/x86_64-w64-mingw32-gcc"
        export PATH="$REPO/out/cross-bin:$(dirname "$CC"):$PATH"
    fi
    touch "$F"
    make -C "$BUILD" dlls/winhttp/x86_64-windows/winhttp.dll > "$REPO/out/fix-winhttp-make.log" 2>&1 \
        || { echo "STOP: build failed"; grep -m6 -E "error|Error|No rule" "$REPO/out/fix-winhttp-make.log"; return 1; }
    local built="$BUILD/dlls/winhttp/x86_64-windows/winhttp.dll"
    [ -f "$built" ] || built="$(find "$BUILD/dlls/winhttp" -name winhttp.dll -path '*x86_64-windows*' | head -1)"
    [ -n "$built" ] && [ -f "$built" ] || { echo "STOP: built winhttp.dll not found"; return 1; }
    tail -1 "$REPO/out/fix-winhttp-make.log" | cut -c1-160
    cp "$built" "$EDLL" && note "   installe: $EDLL"
    if [ -f "$PDLL" ]; then cp "$built" "$PDLL" && note "   installe: $PDLL"; fi
    return 0
}

note "== sauvegardes"
for f in "$F" "$EDLL" "$PDLL"; do [ -f "$f" ] && { [ -f "$f.pre-qh.bak" ] || cp "$f" "$f.pre-qh.bak"; echo "ok $f"; }; done
note "DLL au depart (moteur, prefix, copie de secours):"
info "$EDLL" "$PDLL" "$EDLL.pre-qh.bak"

note "== A. avant: la DLL installee maintenant"
if run_probe avant; then note "== deja bon avant toute modification (rien a corriger ici)"; pbcopy < "$REPORT"; echo "== RAPPORT COPIE : colle-le dans le chat (Cmd+V)"; exit 0; fi

note "== B. recompilation SANS modification"
cp "$F.pre-qh.bak" "$F" 2>/dev/null   # source exactly as found
build_install || { pbcopy < "$REPORT"; exit 1; }
info "$EDLL"
if cmp -s "$EDLL" "$EDLL.pre-qh.bak"; then note "   la DLL recompilee est IDENTIQUE a l'ancienne (la DLL n'etait pas perimee)"; fi
if run_probe recompile; then
    note "== VERDICT: CORRIGE par simple recompilation (l'ancienne DLL ne correspondait pas a la source)"
    pbcopy < "$REPORT"; echo "== RAPPORT COPIE : colle-le dans le chat (Cmd+V)"; exit 0
fi

note "== C. correctif dans WinHttpQueryHeaders"
python3 - "$F" "$REPO/out/winhttp-querydump.txt" <<'PY'
import re, sys
path, dump = sys.argv[1:3]
s = open(path).read()
if "ERROR_INSUFFICIENT_BUFFER (122)" in s:
    print("already patched in the source"); sys.exit(0)
lines = s.split("\n")
start = next((i for i, l in enumerate(lines) if re.match(r"BOOL WINAPI WinHttpQueryHeaders\s*\(", l)), None)
def fail(msg):
    print("STOP:", msg)
    if start is not None:
        end = next((i for i in range(start, len(lines)) if lines[i] == "}"), start + 60)
        open(dump, "w").write("\n".join(lines[start:end + 1]))
        print("the function text was written to", dump)
    sys.exit(3)
if start is None: fail("WinHttpQueryHeaders not found")
brace = next((i for i in range(start, start + 6) if lines[i] == "{"), None)
if brace is None: fail("opening brace not found")
end = next((i for i in range(brace, len(lines)) if lines[i] == "}"), None)
if end is None: fail("end of function not found")
call = next((i for i in range(brace, end) if re.search(r"\b\w+\s*=\s*query_headers\s*\(", lines[i])), None)
if call is None: fail("call to query_headers not found")
var = re.search(r"\b(\w+)\s*=\s*query_headers\s*\(", lines[call]).group(1)
if "buflen" not in "\n".join(lines[start:brace]): fail("parameter 'buflen' not found in the prototype")
comment = [
    "    /* Windows reports ERROR_INSUFFICIENT_BUFFER (122) when the buffer was too small (or NULL) and puts the needed",
    "     * size in *buflen; callers such as libHttpClient test for exactly that and fail the request otherwise. */",
]
setl = next((i for i in range(call + 1, end) if re.search(r"SetLastError\s*\(\s*%s\s*\)" % re.escape(var), lines[i])), None)
if setl is not None:        # style: query_headers returns an error code, the wrapper does SetLastError( ret ); return !ret;
    at = setl
    fix = comment + ["    if (%s && buflen && *buflen > in_len) %s = ERROR_INSUFFICIENT_BUFFER;" % (var, var)]
    style = "error-code"
else:                        # style: query_headers returns a BOOL
    at = next((i for i in range(end, call, -1) if re.match(r"\s*return\s+%s\s*;" % re.escape(var), lines[i])), None)
    if at is None: fail("neither SetLastError( %s ) nor 'return %s;' found after the call" % (var, var))
    fix = comment + ["    if (!%s && buflen && *buflen > in_len && GetLastError() == ERROR_SUCCESS) SetLastError( ERROR_INSUFFICIENT_BUFFER );" % var]
    style = "bool"
lines[at:at] = fix                        # later line first, so the earlier index stays valid
lines[brace + 1:brace + 1] = ["    DWORD in_len = buflen ? *buflen : 0;"]
open(path, "w").write("\n".join(lines))
print("patched (%s style): variable '%s', function lines %d-%d" % (style, var, start + 1, end + 2))
PY
rc=$?
if [ $rc -eq 3 ]; then
    [ -f "$REPO/out/winhttp-querydump.txt" ] && cp "$REPO/out/winhttp-querydump.txt" "$REPORT.dump" && { cat "$REPORT" "$REPORT.dump" | pbcopy; }
    echo "== TEXTE COPIE : colle-le dans le chat (Cmd+V)"; exit 1
fi
[ $rc -eq 0 ] || { echo "STOP: edit failed"; exit 1; }
grep -n -B1 -A3 "ERROR_INSUFFICIENT_BUFFER (122)" "$F" | cut -c1-170 | head -12
build_install || { cp "$F.pre-qh.bak" "$F"; pbcopy < "$REPORT"; exit 1; }
info "$EDLL"
if run_probe corrige; then note "== VERDICT: CORRIGE par le correctif (err=122 comme Windows)"; else note "== VERDICT: PAS CORRIGE (voir les lignes de la sonde)"; fi
pbcopy < "$REPORT"
echo "== RAPPORT COPIE : colle-le dans le chat (Cmd+V)"
