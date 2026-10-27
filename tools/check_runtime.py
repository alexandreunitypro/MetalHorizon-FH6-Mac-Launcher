#!/usr/bin/env python3
"""Say which of the pieces an MSIXVC title needs are really in a built Wine.

Usage:  python3 tools/check_runtime.py <wine install root> [more roots...]

<wine install root> is the directory that contains lib/wine (for example the
prefix you passed to `make install`, or a runtime's files/ directory). The
script looks for strings that only exist in the binaries once a given patch is
compiled in -- the same method as Ferestre's titles/capabilities.toml -- and
prints the full SHA-256 of every binary it looked at, so "which build is
installed" is answered by the files, not by memory.

It only reads files. Python 3.8+, no third-party modules.
"""
import hashlib
import os
import sys

# (label, relative binary, needle, encoding, why it matters)
CHECKS = [
    ("loader.memfd-main-image", "x86_64-unix/ntdll.so", "WINE_DLL_FILE_MAP", "ascii",
     "Wine can load the main image from the decrypted descriptor (xodus memfd patch / Ferestre 0001)"),
    ("process-image-name (Ferestre 0006)", "x86_64-unix/ntdll.so", "image mapped from a memfd has no server name", "ascii",
     "ProcessImageFileName answers from the PEB for a mapped main image"),
    ("serve-image-through-file-api (Ferestre 0009)", "x86_64-unix/ntdll.so", "served from the mapped image descriptor", "ascii",
     "NtCreateFile on the game's own .exe returns the decrypted bytes, not the encrypted file"),
    ("reopen via /proc (Ferestre 0009)", "x86_64-unix/ntdll.so", "/proc/self/fd/%d", "ascii",
     "each handle gets its own file position -- on Linux only; macOS has no /proc"),
    ("reopen via F_GETPATH (this repo, wine 0001)", "x86_64-unix/ntdll.so", "cannot be reopened", "ascii",
     "same, on macOS (needs the xodus-cli 0001 half too)"),
    ("mapped-filename from PEB (Ferestre 0010)", "x86_64-unix/ntdll.so", "has no section name", "ascii",
     "MemoryMappedFilenameInformation on the image base names the .exe instead of nothing"),
    ("GlobalRoot form of the image name (Ferestre 0013)", "x86_64-unix/ntdll.so", "\\??\\GlobalRoot", "utf-16-le",
     "\\\\?\\GLOBALROOT\\??\\Z:\\...\\game.exe is matched to the decrypted descriptor"),
    ("generic GlobalRoot strip (Proton)", "x86_64-unix/ntdll.so", "Stripping off GlobalRoot prefix", "ascii",
     "\\\\?\\GLOBALROOT\\??\\X:\\ works for every other file (upstream Wine 11 does not have it)"),
    ("illegal-instruction byte dump (Ferestre 0001)", "x86_64-windows/ntdll.dll", "Code %p-32..+16", "ascii",
     "a SIGILL in the log comes with the instruction bytes"),
    ("concrt140 queue iterators (Ferestre 0015)", "x86_64-windows/concrt140.dll", "_Concurrent_queue_iterator_base_v4__Advance", "ascii",
     "FH6 aborts after compiling shaders without it (a later stage than start-up)"),
]


def find_lib_wine(root):
    for cand in (os.path.join(root, "lib", "wine"), os.path.join(root, "lib64", "wine"), root):
        if os.path.isdir(os.path.join(cand, "x86_64-unix")):
            return cand
    return None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    rc = 0
    for root in sys.argv[1:]:
        libwine = find_lib_wine(root)
        print(f"== {root}")
        if not libwine:
            print("   no lib/wine/x86_64-unix under this root")
            rc = 1
            continue
        cache = {}
        for label, rel, needle, enc, why in CHECKS:
            path = os.path.join(libwine, rel)
            if path not in cache:
                try:
                    cache[path] = open(path, "rb").read()
                except OSError:
                    cache[path] = None
            data = cache[path]
            if data is None:
                state = "MISSING FILE"
            else:
                state = "yes" if needle.encode(enc) in data else "no"
            print(f"   [{state:>12}] {label}\n                  {why}")
        print("   sha256:")
        for path, data in sorted(cache.items()):
            if data is not None:
                print(f"     {hashlib.sha256(data).hexdigest()}  {path}")
        for extra in ("x86_64-windows/xgameruntime.dll", "x86_64-unix/xgameruntime.so"):
            p = os.path.join(libwine, extra)
            if os.path.exists(p):
                print(f"     {hashlib.sha256(open(p, 'rb').read()).hexdigest()}  {p}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
