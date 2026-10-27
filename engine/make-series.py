#!/usr/bin/env python3
"""Regenerate engine/patches/ from the hand-built Wine tree.

    python3 engine/make-series.py <pristine sources/wine> <dev sources/wine>

<pristine> is sources/wine extracted from the tarball pinned in engine/inputs.json; <dev> is the tree the
working engine was built from. Every file that differs must belong to one group below: an unknown file
stops the script, so nothing changed in the dev tree is ever left out of the recipe by accident.
configure is not diffed (the dev tree regenerated it with another autoconf): its patch carries only the
lines that add the new DLLs, placed where the dev tree has them.
"""
import os, re, subprocess, sys

EXCLUDE_NAMES = ("*.bak", "*.pre-*", "*.orig", "*.rej", "autom4te.cache", "configure~",
                 "configure.before-xgameruntime")
# Not built (--disable-tests). The dev tree has only the test half of Highball's 0025.
SKIP_PREFIXES = ("dlls/ntdll/tests/",)

GROUPS = [
    ("0001-xgameruntime.patch", ("dlls/xgameruntime/", "configure.ac", "configure"),
     "Xbox Gaming Runtime (xgameruntime.dll): Xbox tokens through xodus-service, PlayFab cloud saves,\n"
     "XStore, XUser, XGameSave... From xodus-gaming/wine bleeding-edge @ eab6973 (through Ferestre), plus this\n"
     "project's fixes: cloud save sync, deferred XAsync completions (patches/wine/0007), pfxgamesave channel.\n"
     "LGPL-2.1-or-later (dlls/xgameruntime/LICENSE). configure carries only the lines that add the DLL."),
    ("0002-kernelbase-app-packages.patch",
     ("dlls/kernelbase/package.c", "dlls/kernelbase/Makefile.in", "dlls/kernelbase/kernelbase.spec",
      "dlls/kernelbase/loader.c", "dlls/kernelbase/main.c", "dlls/kernelbase/version.c",
      "dlls/kernel32/kernel32.spec", "loader/wine.inf.in"),
     "Package identity for MSIXVC titles (GetCurrentPackage*, from the Xodus GDK-on-Linux project), app\n"
     "package lookups answered from the registry (Highball 0024, from Proton), VCLibs package entries,\n"
     "GetIntegratedDisplaySize stub (Highball 0017: FH6 aborts without the export)."),
    ("0003-macos-teb-slots.patch", ("dlls/kernelbase/thread.c", "dlls/ntdll/error.c", "include/winbase.h"),
     "macOS: %gs points at the host thread block, not the TEB. Tib.FiberData is mirrored, and LastError is\n"
     "read where MSVC-built code reads it (%gs:0x68)."),
    ("0004-ntdll-msixvc-images-memory.patch",
     ("dlls/ntdll/loader.c", "dlls/ntdll/unix/file.c", "dlls/ntdll/unix/loader.c", "dlls/ntdll/unix/process.c",
      "dlls/ntdll/unix/virtual.c", "dlls/ntdll/unix/unix_private.h"),
     "Licensed MSIXVC executables served from xodus' file descriptors, GLOBALROOT paths (Ferestre 0006, 0009,\n"
     "0010, 0013), own file position per handle on macOS (patches/wine/0001), commit charge = phys_footprint\n"
     "(Highball 0018), data execution prevention following the main executable under Rosetta."),
    ("0005-ntdll-exceptions.patch",
     ("dlls/ntdll/exception.c", "dlls/ntdll/signal_x86_64.c", "dlls/ntdll/unix/signal_x86_64.c"),
     "Leaf unwind for code no module owns; unix-side fault report (patches/wine/0008, channel fh6fault).\n"
     "CAREFUL: the game's protection reacts to changes in the PE exception path (a trace added there crashed\n"
     "3 starts out of 3). Test in game after any change to this patch."),
    ("0006-network.patch",
     ("dlls/winhttp/", "dlls/ws2_32/socket.c", "dlls/iphlpapi/iphlpapi_main.c", "dlls/nsiproxy.sys/ip.c"),
     "Online play and cloud saves: WinHttpQueryHeaders size query as on Windows, WebSocket owns its\n"
     "connection with blocking receives (patches/wine/0002), SIO_UDP_NETRESET (0003), SendARP from the\n"
     "neighbour cache (0004), dual-stack IPv4 socket options (0006), httpreq/udpreq channels (0005, off\n"
     "unless WINEDEBUG asks for them)."),
    ("0007-audio-surround.patch", ("dlls/mmdevapi/spatialaudio.c", "dlls/winecoreaudio.drv/coreaudio.c"),
     "7.1 and 7.1.4 streams rendered through AUSpatialMixer for the Mac's speakers or headphones\n"
     "(Highball 0022, 0023). Without it the engine sound is missing."),
    ("0008-misc.patch", ("dlls/advapi32/cred.c", "dlls/winemac.drv/gdi.c", "dlls/concrt140/"),
     "Xbox sign-in kept across launches: an empty Keychain is not an error (Highball 0019); Retina\n"
     "HORZRES/VERTRES not doubled (Highball 0020); concrt140 concurrent-queue iterator ABI."),
    ("0009-diag-msgbox.patch", ("dlls/user32/msgbox.c",),
     "Diagnostic only: logs the text of the game's message boxes. Candidate to leave out of release builds."),
]
# Lines that show a diagnostic inside a patch, listed in its header.
DIAG_MARKERS = ("FHTRACE", "fh6fault", "FH6 diagnostic", "fh6: bounded stack dump", "DECLARE_DEBUG_CHANNEL")


def changed_files(a, b):
    cmd = ["diff", "-rq"] + [x for n in EXCLUDE_NAMES for x in ("-x", n)] + [a, b]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    files = []
    for line in out.splitlines():
        m = re.match(r"Files (.+) and (.+) differ$", line)
        if m:
            files.append(os.path.relpath(m.group(1), a)); continue
        m = re.match(r"Only in (.+): (.+)$", line)
        if not m:
            sys.exit("unexpected diff output: " + line)
        top, name = m.group(1), m.group(2)
        if not top.startswith(b):
            sys.exit("file removed in the dev tree (not handled): " + os.path.join(top, name))
        path = os.path.join(top, name)
        if os.path.isdir(path):
            for root, _, names in os.walk(path):
                files += [os.path.relpath(os.path.join(root, n), b) for n in names]
        else:
            files.append(os.path.relpath(path, b))
    return sorted(f for f in files if not f.startswith(SKIP_PREFIXES))


def file_diff(a, b, f):
    r = subprocess.run(["diff", "-uN", "--label", "a/" + f, "--label", "b/" + f,
                        os.path.join(a, f), os.path.join(b, f)], capture_output=True)
    if r.returncode > 1:
        sys.exit("diff failed on %s: %s" % (f, r.stderr.decode(errors="replace")))
    return r.stdout


def configure_diff(a, b):
    """The configure lines for DLLs that configure.ac adds, inserted after the same neighbour as in b."""
    new = re.findall(r"^\+WINE_CONFIG_MAKEFILE\((dlls/[^),]+)", file_diff(a, b, "configure.ac").decode(), re.M)
    names = [d.split("/")[-1] for d in new]
    if not names:
        return b""
    pristine = open(os.path.join(a, "configure"), encoding="latin-1").read().split("\n")
    dev = open(os.path.join(b, "configure"), encoding="latin-1").read().split("\n")
    have = set(pristine)
    out = list(pristine)
    for i, line in enumerate(dev):
        if line in have or not any(re.search(r"(?<![A-Za-z0-9])%s(?![A-Za-z0-9])" % re.escape(n), line) for n in names):
            continue
        j = i - 1
        while j >= 0 and dev[j] not in have:
            j -= 1
        if j < 0:
            sys.exit("configure: no anchor for " + line)
        out.insert(out.index(dev[j]) + 1, line)
        have.add(line)
    tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "metalhorizon-configure")
    open(tmp, "w", encoding="latin-1").write("\n".join(out))
    r = subprocess.run(["diff", "-u", "--label", "a/configure", "--label", "b/configure",
                        os.path.join(a, "configure"), tmp], capture_output=True)
    os.unlink(tmp)
    return r.stdout


def group_of(f):
    for name, members, _ in GROUPS:
        if any(f == m or (m.endswith("/") and f.startswith(m)) for m in members):
            return name
    return None


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = (os.path.abspath(p) for p in sys.argv[1:])
    here = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(here, "patches")
    os.makedirs(outdir, exist_ok=True)
    files = changed_files(a, b)
    unknown = [f for f in files if group_of(f) is None]
    if unknown:
        sys.exit("files in no group (add them to GROUPS):\n  " + "\n  ".join(unknown))
    for name, _, header in GROUPS:
        members = [f for f in files if group_of(f) == name]
        body = b"".join(configure_diff(a, b) if f == "configure" else file_diff(a, b, f) for f in members)
        if not body:
            print("%-36s (nothing)" % name); continue
        added = [l for l in body.decode("utf-8", "replace").split("\n") if l.startswith("+") and not l.startswith("+++")]
        diags = sorted({m for m in DIAG_MARKERS for l in added if m in l})
        text = header + "\n"
        if diags:
            text += "Diagnostics inside: " + ", ".join(diags) + "\n"
        text += "Files: " + ", ".join(members) + "\nGenerated by engine/make-series.py; apply with patch -p1.\n\n"
        open(os.path.join(outdir, name), "wb").write(text.encode() + body)
        print("%-36s %3d files, +%d lines%s" % (name, len(members), len(added),
                                                 "  [diagnostics: %s]" % ", ".join(diags) if diags else ""))


if __name__ == "__main__":
    main()
