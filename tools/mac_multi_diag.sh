#!/bin/bash
# FH6 multiplayer diagnostic: launches the game like tools/jouer.sh (D3DMetal 4, Highball shim) with the traces that matter
# for online play, watches its network live, and writes one report with an automatic verdict. Nothing secret is kept:
# tokens are stripped from everything copied into the report.
#
#   bash ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT/tools/mac_multi_diag.sh            # play, go online, quit by the menu
#   bash ~/FORZA-LAUNCHER-FOR-MAC-BLACKWELL-PROJECT/tools/mac_multi_diag.sh --report   # rebuild the report of the last run
#   (also: ws2_32 accepting SIO_UDP_NETRESET, wine 0003)
# Options: --max <seconds> (default 1800)   --light (no libHttpClient trace, smaller log)
#
# What it shows, in the order the online stack is built:
#   1. components: patched winhttp (wine 0002), xgameruntime (gamer picture), xodus-service (title-authenticated XSTS)
#   2. xodus-service: did the title sign in (SISU as FH6), which URLs got a token, for which relying party, failures
#   3. libHttpClient: every PlayFab / Xbox / Forza request with its HTTP status, WebSocket connects (from +hctrace)
#   4. network timeline sampled every 3 s: Forza game server (gameservices.fh6.forzamotorsport.net), UDP = a game session
#   5. Xbox runtime calls the runtime does not implement, crashes (with the crashing thread's last lines), deadlocks
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="$REPO/out"; mkdir -p "$OUTDIR"
LOG="$OUTDIR/fh6-after.log"
SVCLOG="$OUTDIR/xodus-service.log"
NET="$OUTDIR/multi-net.txt"
STAMPF="$OUTDIR/multi-diag.stamp"
WORK="/Users/alexandre/Documents/Codex/2026-10-19/goal-reprend-son-travail-on-invente/work"
PFX="$HOME/FH6/.blackwell-wine/drive_c/windows/system32"
ENGW="$WORK/crossover-source/out-x64/engine/lib/wine/x86_64-windows"
SVCBIN="$WORK/xodus/target/release/xodus-service"
FORZA_HOST="gameservices.fh6.forzamotorsport.net"
MAX=1800; MODE=run; LIGHT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --report) MODE=report ;;
        --max) MAX="${2:-1800}"; shift ;;
        --light) LIGHT=1 ;;
        [0-9]*) MAX="$1" ;;
        *) echo "unknown option $1"; exit 1 ;;
    esac
    shift
done
redact() { sed -E 's/eyJ[A-Za-z0-9_.-]{20,}/<jwt>/g; s/XBL3\.0 x=[^ "]+/XBL3.0 x=<tok>/g; s/(t=|[Tt]oken[=:" ]+)[A-Za-z0-9_.+\/=-]{40,}/\1<tok>/g; s/\x1b\[[0-9;]*m//g'; }
game_pid() { pgrep -f 'forzahorizon6.exe' | while read -r p; do ps -o comm= -p "$p" 2>/dev/null | grep -qi forza && echo "$p"; done | head -1; }

if [ "$MODE" = run ]; then
    if [ -n "$(game_pid)" ]; then echo "STOP: le jeu tourne deja. Ferme-le par son menu, attends 30 s, puis relance ce script."; exit 1; fi
    pkill -f xodus-cli 2>/dev/null; sleep 1
    date +%s > "$STAMPF"
    # The token service only says which URL it signs for at debug level, and the game caches tokens for hours,
    # so it has to be logging before the game starts.
    bash "$REPO/tools/mac_xodus_service.sh" stop >/dev/null 2>&1
    XODUS_LOG="info,xodus_service=debug" bash "$REPO/tools/mac_xodus_service.sh" start >/dev/null 2>&1 \
        || echo "ATTENTION: xodus-service n'a pas demarre (pas de connexion Xbox)"
    # Live network sampler: every 3 s, the game's sockets (TCP and UDP) -> $NET; short notes on the console.
    : > "$NET"
    (
        seen_forza=""; seen_udp=""; started=""
        fz_ips=" $(dig +short "$FORZA_HOST" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ') "
        for _ in $(seq $((MAX / 3 + 60))); do
            g=$(game_pid)
            if [ -z "$g" ]; then [ -n "$started" ] && break; sleep 3; continue; fi
            [ -z "$started" ] && { started=1; echo "   [reseau] jeu demarre (pid $g)"; }
            socks=$(lsof -nP -a -p "$g" -i 2>/dev/null | awk 'NR>1{print $8, $9}')
            echo "$(date +%T) $(echo "$socks" | tr '\n' '|')" >> "$NET"
            for ip in $(echo "$socks" | grep -o -E -- '->[0-9.]+' | tr -d '>-'); do
                case "$fz_ips" in *" $ip "*) [ -z "$seen_forza" ] && { seen_forza=1; echo "   [reseau] $(date +%T) serveur Forza joint ($ip)"; } ;; esac
            done
            if echo "$socks" | grep -q '^UDP' && [ -z "$seen_udp" ]; then
                seen_udp=1; echo "   [reseau] $(date +%T) socket UDP ouvert: le jeu entre dans une session de jeu"
            fi
            sleep 3
        done
    ) &
    SAMPLER=$!
    # Hang catcher: before each c0000409 so far, a thread sat >5 s on a critical section another thread held, and
    # the game aborted ~7 s later (its own watchdog, it seems). Those threads log nothing, so photograph every
    # thread's stack (macOS `sample`: Wine, D3DMetal and Metal frames are named) the moment Wine reports the wait.
    rm -f "$OUTDIR/multi-hang-sample.txt" "$OUTDIR/multi-hang-line.txt"
    (
        until [ -f "$LOG" ] && [ "$(stat -f %m "$LOG")" -ge "$(cat "$STAMPF")" ]; do sleep 1; done
        tail -n0 -F "$LOG" 2>/dev/null | LC_ALL=C grep -a --line-buffered -m1 "RtlpWaitForCriticalSection" > "$OUTDIR/multi-hang-line.txt"
        g=$(game_pid)
        [ -n "$g" ] && { echo "   [blocage] $(date +%T) thread fige detecte, capture des piles du jeu..."; \
                         sample "$g" 3 -file "$OUTDIR/multi-hang-sample.txt" >/dev/null 2>&1; }
    ) &
    HANGCATCH=$!
    if [ -n "$LIGHT" ]; then
        export FH6_DEBUG="+timestamp,err+all,err-module,err-virtual,fixme-all,fixme+gdkc,warn+gdkc,warn+winhttp,warn+winsock,+loaddll"
    else
        # Quiet everything else: Wine's default fixme output alone (bcrypt: ~400 lines/s) and the loader's FHTRACE errors
        # slowed the game enough that its watchdog aborted it (c0000409) before matchmaking in every traced run.
        export FH6_DEBUG="+timestamp,err+all,err-module,err-virtual,fixme-all,fixme+gdkc,fixme+winhttp,fixme+winsock,warn+gdkc,warn+winhttp,warn+winsock,+hctrace,+httpreq,+udpreq,+loaddll"
        export XGDK_HC_TRACE=1   # xgameruntime only hooks libHttpClient's trace when asked
    fi
    : # Blackwell Engine + D3DMetal installed by MetalHorizon (tools/mac_launch_fh6.sh), no CrossOver.app
    echo "== jeu lance avec les traces reseau (max ${MAX}s). Va dans le mode en ligne, laisse chercher 2-3 min, puis ferme par le menu."
    bash "$REPO/tools/mac_launch_fh6.sh" "$MAX" > "$OUTDIR/multi-diag-run.txt" 2>&1
    kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
    pkill -P "$HANGCATCH" 2>/dev/null; kill "$HANGCATCH" 2>/dev/null
    # back to the normal (quiet) service
    bash "$REPO/tools/mac_xodus_service.sh" stop >/dev/null 2>&1
    bash "$REPO/tools/mac_xodus_service.sh" start >/dev/null 2>&1
fi

[ -f "$LOG" ] || { echo "STOP: pas de journal $LOG (lance d'abord sans --report)"; exit 1; }
# launch time of the run being reported; without a stamp (older runs), the log's own last write minus its run time
START=$(cat "$STAMPF" 2>/dev/null)
if [ -z "$START" ]; then
    ran=$(grep -o "ran for about [0-9]*" "$OUTDIR/multi-diag-run.txt" 2>/dev/null | grep -o "[0-9]*$")
    START=$(( $(stat -f %m "$LOG") - ${ran:-3600} - 120 ))
fi
START_ISO=$(date -u -r "$START" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo 0000)
REPORT="$OUTDIR/multi-diag-$(date -r "$START" +%Y%m%d-%H%M 2>/dev/null || date +%Y%m%d-%H%M).txt"
SVCRUN=$(mktemp -t fh6svc); trap 'rm -f "$SVCRUN"' EXIT
# service lines of this run only (its timestamps are UTC ISO-8601, which sort as text)
redact < "$SVCLOG" 2>/dev/null | awk -v s="$START_ISO" 'substr($1,1,19) >= s' | grep -v "Failed to read magic" > "$SVCRUN"
FZ_IPS=" $(dig +short "$FORZA_HOST" 2>/dev/null | grep -E '^[0-9.]+$' | tr '\n' ' ') "

{
echo "=============== FH6 diagnostic multijoueur ($(date -r "$START" '+%d/%m %H:%M' 2>/dev/null)) ==============="
grep -E "^lines:|ran for" "$OUTDIR/multi-diag-run.txt" 2>/dev/null

# ---- automatic verdict ------------------------------------------------------------------------------------------------
echo; echo "## VERDICT"
signed=$(grep -c "signed in as" "$SVCRUN")
forza_tok=$(grep -c "forzamotorsport" "$SVCRUN")
forza_net=0; for ip in $FZ_IPS; do grep -q -- "->$ip:" "$NET" 2>/dev/null && forza_net=1; done
udp=$(grep -c "UDP " "$NET" 2>/dev/null); udp=${udp:-0}
crash=$(LC_ALL=C grep -a -c -E "Unhandled (exception|page fault)|terminating itself|start_debugger" "$LOG")
svcfail=$(grep -c -i -E "failed|panicked" "$SVCRUN")
[ "$signed" -gt 0 ] && echo "OK    xodus-service s'est connecte comme FH6 (SISU titre)" \
                    || echo "??    pas de connexion SISU du titre dans ce run (jetons deja en cache ?)"
[ "$forza_tok" -gt 0 ] && echo "OK    jeton delivre pour le serveur Forza ($forza_tok demandes)" \
                       || echo "??    aucune demande de jeton pour forzamotorsport.net"
if [ ! -s "$NET" ]; then
    echo "??    pas de releve reseau pour ce run (rapport d'un ancien run)"
else
    [ "$forza_net" = 1 ] && echo "OK    le jeu s'est connecte au serveur Forza ($FORZA_HOST)" \
                         || echo "KO    le jeu n'a jamais contacte le serveur Forza (message 'serveur indisponible' probable)"
    [ "$udp" -gt 0 ] && echo "OK    socket UDP ouvert: le jeu est entre dans une session (premier: $(grep -m1 'UDP ' "$NET" | cut -d' ' -f1))" \
                     || echo "KO    aucun socket UDP vu: le matchmaking n'a pas abouti a une session"
fi
udpcalls=$(LC_ALL=C grep -a -c "SIO_UDP_CONNRESET" "$LOG"); udpcalls=${udpcalls:-0}
[ "$udpcalls" -gt 0 ] && echo "info  le jeu a cree $udpcalls socket(s) UDP de jeu (SIO_UDP_CONNRESET) pendant le run"
[ "$svcfail" -gt 0 ] && echo "KO    $svcfail echecs cote xodus-service (voir section 2)"
# PlayFab Multiplayer (its own WinHTTP calls, seen only through the httpreq channel): where does the search stop?
if LC_ALL=C grep -a -q ":httpreq:" "$LOG"; then
    hr() { LC_ALL=C grep -a ":httpreq:" "$LOG" | grep -c -E "$1"; }
    hst() { LC_ALL=C grep -a ":httpreq:" "$LOG" | grep " status " | grep -E "$1" | grep -o -E "status [0-9]+" | sort | uniq -c | tr '\n' ' '; }
    for step in "Match/CreateMatchmakingTicket:ticket de matchmaking cree" "Match/SubscribeToMatchmakingResource:abonnement aux notifications du ticket" \
                "Match/GetMatchmakingTicket:suivi du ticket" "Match/GetMatch:partie trouvee (GetMatch)" \
                "Lobby/(CreateLobby|JoinArrangedLobby|JoinLobby):lobby cree / rejoint" "pubsub/negotiate|PubSub/Negotiate:negociation PubSub" \
                "signalr.net:WebSocket PubSub (Azure SignalR)" "MultiplayerServer/(RequestMultiplayerServer|ListQos):serveurs dedies / QoS"; do
        pat=${step%%:*}; label=${step#*:}; n=$(hr "open .*($pat)")
        if [ "$n" -gt 0 ]; then echo "OK    PlayFab: $label ($n requetes; $(hst "$pat"))"; else echo "--    PlayFab: $label: aucune requete"; fi
    done
    LC_ALL=C grep -a ":httpreq:" "$LOG" | grep -q "receive error" && echo "KO    une WebSocket a eu une erreur de reception (section 3b)"
fi
if LC_ALL=C grep -a -q ":udpreq:" "$LOG"; then
    refused=$(LC_ALL=C grep -a ":udpreq:" "$LOG" | grep "setsockopt" | grep -c -- "-> -1")
    kept=$(LC_ALL=C grep -a ":udpreq:" "$LOG" | grep -c "bind result 0"); closed=$(LC_ALL=C grep -a ":udpreq:" "$LOG" | grep -c " closed")
    if [ "$refused" -gt 0 ]; then echo "KO    $refused option(s) refusee(s) sur les sockets UDP du jeu: $(LC_ALL=C grep -a ":udpreq:" "$LOG" | grep setsockopt | grep -- "-> -1" | grep -o -E "name (0x[0-9a-f]+|[A-Z_0-9]+)" | sed "s/name 0x4c/name IP_USER_MTU/" | sort -u | tr '\n' ' ')"
    else echo "OK    aucune option refusee sur les sockets UDP du jeu"; fi
    echo "info  sockets UDP lies: $kept, fermes: $closed"
    qos=$(LC_ALL=C grep -a ":udpreq:" "$LOG" | grep "send to" | grep -c "port 3075,")
    other=$(LC_ALL=C grep -a ":udpreq:" "$LOG" | grep "send to" | grep -v -E "port (3075|1900|53)," | grep -c "status 0")
    if [ "$qos" -gt 0 ]; then echo "OK    mesures de latence QoS envoyees ($qos pings vers le port 3075)"
    else echo "KO    aucun ping QoS UDP envoye par le jeu: le ticket de matchmaking part sans latence"; fi
    [ "$other" -gt 0 ] && echo "info  $other envois UDP vers d'autres serveurs (serveur de jeu ?), voir section 3c"
fi
[ "$crash" -gt 0 ] && echo "KO    plantage du jeu (voir section 5)" || echo "OK    pas de plantage"

# ---- 1. components ----------------------------------------------------------------------------------------------------
echo; echo "## 1. Composants installes"
st() { if [ -f "$1.$2" ]; then cmp -s "$1" "$1.$2" && echo "ANCIEN (identique a la sauvegarde)" || echo "corrige"; else echo "pas de sauvegarde $2"; fi; }
echo "winhttp.dll (prefix)        : $(st "$PFX/winhttp.dll" pre-ws.bak)"
echo "xgameruntime.dll (prefix)   : $(st "$PFX/xgameruntime.dll" pre-pic.bak)"
echo "xgameruntime.dll (moteur)   : $(st "$ENGW/xgameruntime.dll" pre-pic.bak)"
echo "ws2_32.dll (prefix)         : $(st "$PFX/ws2_32.dll" pre-netreset.bak)  (SIO_UDP_NETRESET accepte)"
echo "ws2_32.dll journal UDP      : $(strings "$PFX/ws2_32.dll" 2>/dev/null | grep -q udpreq && echo present || echo absent)"
echo "ws2_32 options IPv4 [::]    : $(strings "$PFX/ws2_32.dll" 2>/dev/null | grep -q "applied to dual-stack" && echo "corrige (IP_DONTFRAGMENT/IP_TTL acceptes)" || echo "ANCIEN: le jeu ferme son socket de jeu")"
echo "iphlpapi.dll (SendARP)      : $(st "$PFX/iphlpapi.dll" pre-arp.bak)"
echo "nsiproxy.so (table ARP)     : $(st "$WORK/crossover-source/out-x64/engine/lib/wine/x86_64-unix/nsiproxy.so" pre-arp.bak)"
echo "xodus-service               : $(strings "$SVCBIN" 2>/dev/null | grep -q 'signed in as' && echo 'jetons de titre (corrige)' || echo 'ANCIEN (jetons utilisateur seul)')"

# ---- 2. token service ---------------------------------------------------------------------------------------------------
echo; echo "## 2. xodus-service: URLs signees pendant ce run (hote + chemin -> relying party)"
grep -E "Title token for|Relying party:|XSTS token request for" "$SVCRUN" \
    | sed -E 's/^[^ ]+ +[A-Z]+ +[^ ]+ //; s/\?[^ )]*//; s#(https://[^/ ]+/[^/ ]+/?)[^ )]*#\1...#' \
    | sort | uniq -c | sort -rn | head -40
echo "-- echecs / avertissements:"
grep -i -E "warn|error|failed|panicked" "$SVCRUN" | sed -E 's/^[^ ]+ +//' | cut -c1-220 | sort | uniq -c | sort -rn | head -15

# ---- 3. libHttpClient -----------------------------------------------------------------------------------------------------
echo; echo "## 3. libHttpClient (PlayFab / Xbox / Forza): hotes, statuts HTTP, WebSockets"
if LC_ALL=C grep -a -q "hctrace" "$LOG"; then
    LC_ALL=C grep -a "hctrace" "$LOG" | redact > "$OUTDIR/multi-hctrace.txt"
    echo "-- requetes par hote/chemin:"
    grep -o -E "(https|wss)://[A-Za-z0-9.-]+(/[A-Za-z0-9._~-]+){0,3}" "$OUTDIR/multi-hctrace.txt" | sort | uniq -c | sort -rn | head -40
    echo "-- statuts HTTP:"
    grep -o -i -E "(status(code)?|http status)[^0-9]{0,6}[1-5][0-9]{2}" "$OUTDIR/multi-hctrace.txt" | grep -o -E "[1-5][0-9]{2}$" | sort | uniq -c | sort -rn
    echo "-- erreurs (hr != S_OK, echecs, WebSocket):"
    grep -i -E "fail|error|hr *[=:] *0x8|websocket|disconnect|timeout|retry" "$OUTDIR/multi-hctrace.txt" \
        | sed -E 's/^[0-9.]+:[0-9a-f]+:trace:hctrace://; s/0x[0-9a-fA-F]{9,}/X/g' | cut -c1-230 | sort | uniq -c | sort -rn | head -30
    echo "   (trace complete sans jetons: out/multi-hctrace.txt)"
else
    echo "pas de trace libHttpClient (--light, ou le jeu ne l'a pas activee)"
fi

# ---- 3b. every WinHTTP request, whoever made it --------------------------------------------------------------------
echo; echo "## 3b. Toutes les requetes WinHTTP (libHttpClient, XCurl/PlayFab Multiplayer, ...): hote + chemin, statut"
if LC_ALL=C grep -a -q ":httpreq:" "$LOG"; then
    LC_ALL=C grep -a ":httpreq:" "$LOG" | redact > "$OUTDIR/multi-httpreq.txt"
    echo "-- requetes ouvertes (hote:port + debut du chemin):"
    grep " open " "$OUTDIR/multi-httpreq.txt" | sed -E 's/.* open L"([A-Z]+)" L"([^"]+)":([0-9]+)L"([^"?]{0,60})[^"]*".*/\1 \2:\3\4/' | sort | uniq -c | sort -rn | head -40
    echo "-- statuts par hote:"
    grep " status " "$OUTDIR/multi-httpreq.txt" | sed -E 's/.* status ([0-9]+) L"([^"]+)"L"([^"?]{0,40})[^"]*".*/\1 \2\3/' | sort | uniq -c | sort -rn | head -30
    echo "-- WebSockets:"
    grep -E "websocket" "$OUTDIR/multi-httpreq.txt" | sed -E 's/^[0-9.]+:[0-9a-f]+:trace:httpreq:[A-Za-z_]+ //; s/[0-9A-F]{16}/X/g' | sort | uniq -c | sort -rn | head -10
    echo "-- dernieres requetes du run:"
    grep -E " open | status " "$OUTDIR/multi-httpreq.txt" | tail -8 | cut -c1-200
    echo "   (liste complete: out/multi-httpreq.txt)"
else
    echo "pas de journal httpreq (winhttp.dll sans ce canal, ou --light)"
fi

# ---- 3c. UDP: QoS pings, game server, LAN ---------------------------------------------------------------------------
echo; echo "## 3c. UDP du jeu (ws2_32 udpreq): binds, destinations, reponses"
if LC_ALL=C grep -a -q ":udpreq:" "$LOG"; then
    LC_ALL=C grep -a ":udpreq:" "$LOG" > "$OUTDIR/multi-udp.txt"
    echo "-- binds:"; grep " bind " "$OUTDIR/multi-udp.txt" | grep -o -E "address [0-9.]+, port [0-9]+" | sort | uniq -c | head
    echo "-- envois par destination:"
    grep "send to" "$OUTDIR/multi-udp.txt" | grep -o -E "address [0-9.]+, port [0-9]+ \}, status [0-9a-fx]+" | sort | uniq -c | sort -rn | head -20
    echo "-- receptions directes (recvfrom synchrone):"
    grep " recv " "$OUTDIR/multi-udp.txt" | grep -o -E "recv [0-9]+ bytes from (\{ family AF_INET, address [0-9.]+, port [0-9]+|-), status [0-9a-fx]+" | sed -E 's/ bytes//' | sort | uniq -c | sort -rn | head -15
    echo "-- connect:"; grep " connect " "$OUTDIR/multi-udp.txt" | grep -o -E "address [0-9.]+, port [0-9]+" | sort | uniq -c | head
    echo "   (detail: out/multi-udp.txt)"
else
    echo "pas de journal UDP (ws2_32 sans le canal udpreq, ou --light)"
fi

# ---- 4. network timeline --------------------------------------------------------------------------------------------------
echo; echo "## 4. Reseau du jeu (releve toutes les 3 s)"
if [ -s "$NET" ]; then
    echo "-- serveurs distants vus (nombre de releves):"
    grep -o -E -- '->[0-9.]+:[0-9]+' "$NET" | tr -d '>-' | sort | uniq -c | sort -rn | while read -r n hp; do
        ip=${hp%:*}; tag=""; case "$FZ_IPS" in *" $ip "*) tag="  <- serveur Forza" ;; esac
        echo "   $n  $hp$tag"
    done | head -25
    echo "-- UDP (sessions de jeu):"; grep -o -E 'UDP [^|]+' "$NET" | sort | uniq -c | sort -rn | head -10
    [ "$udp" -eq 0 ] && echo "   aucun"
    echo "-- debut / fin: $(head -1 "$NET" | cut -d' ' -f1) -> $(tail -1 "$NET" | cut -d' ' -f1)"
else
    echo "pas de releve (lance sans --report)"
fi

# ---- 5. runtime, winhttp, crashes -----------------------------------------------------------------------------------------
echo; echo "## 5. Runtime Xbox, WinHTTP, plantages"
echo "-- fonctions Xbox non implementees appelees (gdkc):"
LC_ALL=C grep -a -E "(fixme|warn|err):gdkc" "$LOG" | sed -E 's/^[0-9.]+:[0-9a-f]+://; s/(iface|user|async|queue|context|callback|token|handle)[ =]+[0-9A-Fa-fx]+/\1 X/g' \
    | sort | uniq -c | sort -rn | head -20
echo "-- WinHTTP / sockets:"
LC_ALL=C grep -a -E "(warn|fixme):(winhttp|winsock)" "$LOG" | sed -E 's/^[0-9.]+:[0-9a-f]+://' | sort | uniq -c | sort -rn | head -12
echo "-- blocages (sections critiques):"
LC_ALL=C grep -a "RtlpWaitForCriticalSection" "$LOG" | sed -E 's/^[0-9.]+://' | cut -c1-180 | head -5
echo "-- plantages:"
LC_ALL=C grep -a -n -E "Unhandled exception|terminating itself|start_debugger" "$LOG" | head -1 | while IFS=: read -r ln rest; do
    tid=$(echo "$rest" | cut -d: -f2)
    echo "   $(echo "$rest" | cut -c1-160)"
    LC_ALL=C grep -a -m1 -o -E "Unhandled page fault[^\\]*" "$LOG" | sed 's/^/   /'
    case "$rest" in *c0000409*) echo "   (c0000409 = arret volontaire du jeu: __fastfail / exception C++ non rattrapee)";; esac
    echo "   derniers evenements du thread $tid avant:"
    LC_ALL=C head -n "$ln" "$LOG" | LC_ALL=C grep -a ":$tid:" | LC_ALL=C grep -a -v -E "FHTRACE|c000001d|dispatch_exception|virtual_handle_fault|SetThreadSelectedCpuSets|BCryptCreateHash|PSO|Pipeline" \
        | tail -8 | redact | cut -c1-200 | sed 's/^/      /'
done
[ "$crash" -eq 0 ] && echo "   aucun"
echo "-- piles au moment du blocage (macOS sample):"
if [ -s "$OUTDIR/multi-hang-sample.txt" ]; then
    echo "   declencheur: $(cut -c1-150 "$OUTDIR/multi-hang-line.txt")"
    # threads waiting in the Wine server or in a lock, and anything named in D3DMetal / Metal / sockets
    grep -E "Thread_[0-9]+|RtlpWaitForCriticalSection|NtWaitFor|server_select|wait_select|D3DMetal|MTL|AGX|recv|send|poll|kevent|__psynch|semaphore" "$OUTDIR/multi-hang-sample.txt" \
        | grep -v "^ *[0-9]* *Thread_" | sed -E 's/^[ +!:|]*//; s/ *\(in [^)]*\)//; s/  +/ /g' | cut -c1-140 | sort | uniq -c | sort -rn | head -30
    echo "   (piles completes: out/multi-hang-sample.txt)"
else
    echo "   aucune capture (pas de blocage signale par Wine pendant ce run)"
fi
} > "$REPORT" 2>&1

cp "$REPORT" "$OUTDIR/multi-diag.txt"
cat "$REPORT"
pbcopy < "$REPORT" 2>/dev/null && echo "== rapport copie dans le presse-papiers ($REPORT)"
