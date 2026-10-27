#!/usr/bin/env python3
"""Ask xodus-service for an Xbox Live token the way Wine's xgameruntime does (framing read from
dlls/xgameruntime/unixlib.c) and report ONLY whether it works. The token itself is never printed or stored;
the gamertag is shown partly masked. Needs xodus-service running (tools/mac_xodus_service.sh start)."""
import os, re, socket, struct, sys

RT = os.environ.get("XODUS_RUNTIME_DIR", "/private/tmp/xodus-runtime-test")
GAME = os.path.expanduser(os.environ.get("FH6_DIR", "~/FH6"))
URL = os.environ.get("PROBE_URL", "https://xboxlive.com")
MAGIC, REQ = 0x58445358, 5

def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;").replace("'", "&apos;")

def tag(xml, name):
    m = re.search(r"<%s>(.*?)</%s>" % (name, name), xml, re.S)
    return m.group(1) if m else ""

def mask(s):
    return (s[:2] + "*" * max(len(s) - 2, 0)) if s else ""

cfg = ""
try:
    cfg = open(os.path.join(GAME, "MicrosoftGame.Config"), errors="replace").read()
except OSError as e:
    print("note: cannot read MicrosoftGame.Config (%s); sending empty TitleId" % e)
def cfgval(*pats):
    for p in pats:
        m = re.search(p, cfg)
        if m: return m.group(1)
    return ""
title = cfgval(r"<TitleId>\s*([^<\s]+)", r'TitleId="([^"]+)"')
msa = cfgval(r"<MSAAppId>\s*([^<\s]+)", r'MSAAppId="([^"]+)"')
print("title id: %s | msa app id: %s" % (title or "(none)", msa or "(none)"))

body = ("<XSTSTokenRequest><Url>%s</Url><RelyingParty></RelyingParty><Method>GET</Method><TitleId>%s</TitleId>"
        "<TitleClientId>%s</TitleClientId><BodyBase64></BodyBase64></XSTSTokenRequest>") % (esc(URL), esc(title), esc(msa))
data = body.encode()
path = os.path.join(RT, "xodus.sock")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(60)
try:
    s.connect(path)
except OSError as e:
    print("RESULT: cannot reach xodus-service on %s (%s). Start it: bash tools/mac_xodus_service.sh start" % (path, e)); sys.exit(2)
s.sendall(struct.pack("<IHH", MAGIC, REQ, len(data)) + data)

def readn(n):
    out = b""
    while len(out) < n:
        c = s.recv(n - len(out))
        if not c: raise EOFError("service closed the connection")
        out += c
    return out
try:
    magic, typ, ln = struct.unpack("<IHH", readn(8))
except (EOFError, socket.timeout) as e:
    print("RESULT: no answer from xodus-service (%s)" % e); sys.exit(3)
if magic != MAGIC or typ != REQ + 1:
    print("RESULT: unexpected reply (magic %#x type %d)" % (magic, typ)); sys.exit(4)
if ln == 0:
    print("RESULT: the service answered with no token: the account is not signed in or the token request was refused.")
    sys.exit(5)
reply = readn(ln).decode(errors="replace")
token, xuid, gt, exp = tag(reply, "Token"), tag(reply, "Xuid"), tag(reply, "Gamertag"), tag(reply, "Expiry")
if not token:
    print("RESULT: reply without a token. Tags present: %s" % ", ".join(sorted(set(re.findall(r"<(\w+)>", reply)))))
    sys.exit(6)
print("RESULT: OK, xodus-service gave a token (%d characters, not shown)" % len(token))
print("        xuid: %s | gamertag: %s (%d chars) | expiry: %s" % ("present" if xuid else "missing", mask(gt) or "missing", len(gt), exp or "?"))
