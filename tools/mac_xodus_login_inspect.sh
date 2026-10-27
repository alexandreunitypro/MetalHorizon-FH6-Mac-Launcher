#!/bin/bash
# Read-only. How does the game get its Xbox token? Looks at what xodus offers (commands, service folder,
# whether a login exists) and how Wine's xgameruntime asks for the token. It lists NAMES only: it never
# prints the content of a credentials file. Result in out/xodus-login.txt and the clipboard.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
SRC="$WORK/crossover-source/sources/wine"; XD="$WORK/xodus"; XB="$XD/target/release/xodus-cli"
RT="${XODUS_RUNTIME_DIR:-/private/tmp/xodus-runtime-test}"
mkdir -p "$REPO/out"
{
echo "== xodus-cli commands"
"$XB" --help 2>&1 | head -30
echo "== xodus-cli run options"
"$XB" run --help 2>&1 | head -30
echo "== xodus crates"
ls "$XD/crates" 2>/dev/null | tr '\n' ' '; echo
echo "== xodus service folder $RT (names and sizes only)"
ls -la "$RT" 2>&1 | head -15
echo "== possible stored logins (names only, never content)"
for d in "$HOME/.config/xodus" "$HOME/.local/share/xodus" "$HOME/Library/Application Support/xodus" "$HOME/.xodus" "$XD/.xodus"; do
  [ -e "$d" ] && { echo "$d"; ls -la "$d" 2>/dev/null | awk '{print "   "$1" "$5" "$9}' | head -10; }
done
find "$HOME" -maxdepth 4 \( -iname '*xodus*' -o -iname '*xbl*token*' -o -iname '*msal*' -o -iname '*xal*cache*' \) -not -path '*/Documents/*' -not -path '*/.Trash/*' 2>/dev/null | head -10
echo "== xodus: where login / tokens are mentioned in its source"
grep -rniE "xsts|device.?code|oauth|login\.live|msal|refresh.?token|sign.?in" "$XD/crates" --include=*.rs -l 2>/dev/null | sed "s#$XD/##" | head -12
echo "== xodus CLI subcommand definitions"
grep -rnE "enum (Commands|Command|Cmd|Subcommand)|^\s+(Login|Auth|Token|Run|Service|Logout|Account)\b" "$XD/crates/xodus-cli/src" 2>/dev/null | sed "s#$XD/##" | head -20
echo "== Wine xgameruntime sources"
ls "$SRC/dlls/xgameruntime" 2>/dev/null | tr '\n' ' '; echo
echo "== how Wine's xuser.c asks for a token (matching lines)"
grep -nEi "xsts|token|runtime_dir|XODUS|getenv|unix_call|sign|gamertag|E_FAIL|E_NOTIMPL|E_ABORT|HRESULT_FROM" "$SRC/dlls/xgameruntime/xuser.c" 2>/dev/null | head -50
echo "== unix side (the .so) : files and matching lines"
ls "$SRC/dlls/xgameruntime"/*unix* "$SRC/dlls/xgameruntime"/*.c 2>/dev/null | sed "s#$SRC/##" | tr '\n' ' '; echo
grep -rnEi "xodus|runtime_dir|getenv|xsts_token|socket|connect\(|sockaddr|AF_UNIX|\.sock|fifo" "$SRC/dlls/xgameruntime" 2>/dev/null | sed "s#$SRC/##" | head -30
echo "== how connected storage / cloud save is done (xgamesave.c)"
grep -nEi "cloud|sync|xbl|http|playfab|connected|E_FAIL|local|offline|folder" "$SRC/dlls/xgameruntime/xgamesave.c" 2>/dev/null | head -30
} > "$REPO/out/xodus-login.txt" 2>&1
pbcopy < "$REPO/out/xodus-login.txt"; wc -l < "$REPO/out/xodus-login.txt" | sed 's/^/lignes: /'; echo "COPIE OK - puis: cat out/xodus-login.txt"
