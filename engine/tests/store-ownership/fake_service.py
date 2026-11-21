#!/usr/bin/env python3
"""A stand-in for xodus-service, for xgameruntime's Store and profile frames (engine/tests/store-ownership).

It answers CSDX (Store catalog) with answers the real service made from the live catalog (the
`the_runtime_test_answers` test of xodus-service writes them), GSDX (gamer picture) with a PNG of the size asked,
and ASDX/ESDX (account roles, entitlement) with "signed in" and "licensed". Every request is written to the log, so
the test also checks what the runtime asked for.

  python3 -I fake_service.py <socket folder> <answers folder> <log> [mode]

Modes: normal (default); fail: the catalog answers E_FAIL and there is no picture, as when Microsoft cannot be
reached. No credentials or account data: everything here is made up or public catalog data.
"""
import os
import socket
import struct
import sys
import threading
import zlib

CSDX, GSDX, ASDX, ESDX = (struct.unpack("<I", m)[0] for m in (b"CSDX", b"GSDX", b"ASDX", b"ESDX"))
E_FAIL = 0x80004005


def png(side):
    """A valid PNG, `side` pixels a side, one colour, so its header carries the size asked for."""
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + b"\x1e\x90\xff" * side for _ in range(side))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


class Reader:
    def __init__(self, data):
        self.data, self.at = data, 0

    def u32(self):
        (v,) = struct.unpack_from("<I", self.data, self.at)
        self.at += 4
        return v

    def text(self):
        n = self.u32()
        s = self.data[self.at:self.at + n].decode()
        self.at += n
        return s


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        part = conn.recv(n - len(buf))
        if not part:
            raise EOFError
        buf += part
    return buf


def catalog_request(data):
    r = Reader(data)
    req = {"version": r.u32(), "associated": r.u32(), "kinds": r.u32(), "parent": r.text(), "market": r.text(),
           "locale": r.text()}
    req["ids"] = [r.text() for _ in range(r.u32())]
    req["actions"] = [r.text() for _ in range(r.u32())]
    req["flags"] = r.u32() if req["version"] >= 2 else None
    if r.at != len(data):
        raise ValueError("trailing bytes in the catalog request")
    return req


def serve(conn, answers, log, mode):
    with conn:
        while True:
            try:
                (magic,) = struct.unpack("<I", recv_exact(conn, 4))
            except EOFError:
                return
            if magic == CSDX:
                (size,) = struct.unpack("<I", recv_exact(conn, 4))
                req = catalog_request(recv_exact(conn, size))
                if req["flags"] and req["flags"] & 1:
                    name = "entitled" if req["kinds"] & 4 else "addons"
                else:
                    name = "listing"
                if mode == "fail":
                    body = struct.pack("<III", 1, E_FAIL, 0)
                    name = "failure"
                else:
                    with open(os.path.join(answers, name + ".bin"), "rb") as f:
                        body = f.read()
                log(f"CSDX version={req['version']} associated={req['associated']} kinds={req['kinds']} "
                    f"parent={req['parent']} flags={req['flags']} ids={len(req['ids'])} -> {name} ({len(body)} bytes)")
                conn.sendall(struct.pack("<II", CSDX, len(body)) + body)
            elif magic == GSDX:
                version, pixels = struct.unpack("<II", recv_exact(conn, 8))
                if mode == "fail" or version != 1:
                    log(f"GSDX version={version} pixels={pixels} -> none")
                    conn.sendall(struct.pack("<III", GSDX, 1, 0))
                else:
                    image = png(pixels)
                    log(f"GSDX version={version} pixels={pixels} -> png ({len(image)} bytes)")
                    conn.sendall(struct.pack("<III", GSDX, 0, len(image)) + image)
            elif magic == ASDX:
                (version,) = struct.unpack("<I", recv_exact(conn, 4))
                log(f"ASDX version={version}")
                conn.sendall(struct.pack("<IIII", 1, 1, 1, 1))
            elif magic == ESDX:
                version, length = struct.unpack("<II", recv_exact(conn, 8))
                product = recv_exact(conn, length).decode()
                log(f"ESDX version={version} product={product}")
                conn.sendall(struct.pack("<II", 1, 1))
            else:
                log(f"unknown frame {magic:#010x}: closed")
                return


def main():
    folder, answers, log_path = sys.argv[1:4]
    mode = sys.argv[4] if len(sys.argv) > 4 else "normal"
    path = os.path.join(folder, "xodus.sock")
    if os.path.exists(path):
        os.unlink(path)
    lock = threading.Lock()
    log_file = open(log_path, "a", buffering=1)

    def log(line):
        with lock:
            log_file.write(line + "\n")

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(16)
    log(f"listening on {path} ({mode})")
    while True:
        conn, _ = server.accept()
        threading.Thread(target=serve, args=(conn, answers, log, mode), daemon=True).start()


if __name__ == "__main__":
    main()
