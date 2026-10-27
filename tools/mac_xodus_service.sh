#!/bin/bash
# Start / stop / check xodus-service, the helper that holds the signed-in Microsoft account (macOS Keychain
# items "Xodus Service") and gives the game its Xbox token through $XODUS_RUNTIME_DIR/xodus.sock.
# Without it the game's xgameruntime logs "xodus-service is not reachable; no Xbox Live sign-in" and the game
# shows "Cloud save synchronization failed". `xodus-cli run` does NOT start it.
#   bash tools/mac_xodus_service.sh start | stop | status | info
# The service's log goes to out/xodus-service.log (shown here with token-looking strings removed).
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work}"
XS="$WORK/xodus/target/release/xodus-service"
SRC="$WORK/crossover-source/sources/wine"
RT="${XODUS_RUNTIME_DIR:-/private/tmp/xodus-runtime-test}"
PIDF="$REPO/out/xodus-service.pid"; LOGF="$REPO/out/xodus-service.log"
mkdir -p "$REPO/out"
clean() { sed -E 's/eyJ[A-Za-z0-9_.-]{20,}/<jwt removed>/g; s/([Tt]oken|[Bb]earer|[Ss]ecret|[Pp]assword)[=: ]+[A-Za-z0-9_.+\/-]{24,}/\1=<removed>/g'; }
alive() { [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null; }
state() {
    if alive && [ -S "$RT/xodus.sock" ]; then echo "xodus-service: RUNNING (pid $(cat "$PIDF"), socket $RT/xodus.sock)"; return 0; fi
    alive && echo "xodus-service: process alive but no socket yet" || echo "xodus-service: NOT running"; return 1
}
case "${1:-status}" in
  status) state; [ -f "$LOGF" ] && { echo "-- last log lines"; tail -8 "$LOGF" | clean; } ;;
  stop)
    alive && kill "$(cat "$PIDF")" 2>/dev/null; sleep 1; rm -f "$PIDF" "$RT/xodus.sock"; echo "xodus-service stopped" ;;
  start)
    [ -x "$XS" ] || { echo "STOP: $XS not found (cargo build --release -p xodus-service in $WORK/xodus)"; exit 1; }
    state >/dev/null && { state; exit 0; }
    mkdir -p "$RT" && chmod 700 "$RT"
    rm -f "$RT/xodus.sock" "$PIDF"
    echo "starting xodus-service (a macOS Keychain window may ask to let it use the 'Xodus Service' item: choose Allow)"
    ( cd /tmp && XODUS_RUNTIME_DIR="$RT" XODUS_LOG="${XODUS_LOG:-info}" nohup "$XS" > "$LOGF" 2>&1 & echo $! > "$PIDF" )
    for i in $(seq 60); do
        [ -S "$RT/xodus.sock" ] && break
        alive || break
        sleep 1
    done
    state && exit 0
    echo "STOP: the service did not open its socket. Its log:"; tail -25 "$LOGF" | clean; exit 1 ;;
  info)
    echo "== utils.rs (runtime dir logic)"; cat "$WORK/xodus/crates/xodus-service/src/utils.rs" 2>/dev/null
    echo "== xodus-service router.rs"; sed -n 1,60p "$WORK/xodus/crates/xodus-service/src/connection/router.rs" 2>/dev/null
    echo "== client side of the protocol (unixlib.c)"
    sed -n 50,75p "$SRC/dlls/xgameruntime/unixlib.c" 2>/dev/null
    sed -n 279,420p "$SRC/dlls/xgameruntime/unixlib.c" 2>/dev/null ;;
  *) echo "usage: $0 start|stop|status|info" ;;
esac
