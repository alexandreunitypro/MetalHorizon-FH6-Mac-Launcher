#!/bin/bash
# Read-only. How is xodus-service started, which socket does it open, where does it find the signed-in
# Microsoft account? Lists names and code only; never prints the content of a credentials file.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
XD="$WORK/xodus"; S="$XD/crates/xodus-service/src"
mkdir -p "$REPO/out"
{
echo "== built binaries"
ls -la "$XD/target/release" 2>/dev/null | grep -iE 'xodus' | grep -v '\.d$' | awk '{print $5" "$6" "$7" "$9}'
echo "== running now"
pgrep -fl 'xodus' || echo "(nothing running)"
echo "== xodus-service Cargo.toml"
sed -n 1,40p "$XD/crates/xodus-service/Cargo.toml" 2>/dev/null
echo "== xodus-service sources"
ls -la "$S" "$S"/* 2>/dev/null | awk '{print $5" "$9}' | grep -v '^ *$' | head -40
echo "== main.rs: arguments, environment, socket, startup"
grep -nE "fn main|clap|Parser|#\[arg|env::var|XODUS_|RUNTIME|xodus\.sock|bind|listen|UnixListener|SOCK|runtime_dir|TMPDIR|/tmp|daemon|login|token|auth|credential|keychain|keyring|home_dir|config_dir|data_dir|cache_dir" "$S/main.rs" 2>/dev/null | head -60
echo "== other service files mentioning where the account is read from"
grep -rnE "keyring|keychain|home_dir|config_dir|data_dir|cache_dir|\.json|read_to_string|File::open|load_auth|AuthStore|TokenStore|refresh" "$S" 2>/dev/null | sed "s#$XD/##" | head -30
echo "== xodus auth.rs: where the login is stored (code only)"
grep -nE "fn |home_dir|config_dir|data_dir|cache_dir|keyring|keychain|\.json|\.toml|read_to_string|File::create|File::open|write|save|load|store|path|Entry::new|service_name" "$XD/crates/xodus/src/auth.rs" 2>/dev/null | head -50
echo "== xodus-cli login / logout"
"$XD/target/release/xodus-cli" login --help 2>&1 | head -12
"$XD/target/release/xodus-cli" logout --help 2>&1 | head -12
echo "== xodus-cli: does 'run' start the service itself?"
grep -rnE "xodus-service|xodus_service|spawn|Command::new|service" "$XD/crates/xodus-cli/src/commands/run.rs" 2>/dev/null | head -20
echo "== keychain entries NAMED xodus (attributes only, no secret values)"
security dump-keychain 2>/dev/null | grep -iE '"svce"|"acct"|xodus' | grep -i xodus | head -6 || true
} > "$REPO/out/xodus-service.txt" 2>&1
wc -l < "$REPO/out/xodus-service.txt" | sed 's/^/lignes: /'
