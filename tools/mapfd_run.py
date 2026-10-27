#!/usr/bin/env python3
"""Run tools/selfread/selfread.exe the way Xodus runs an MSIXVC title.

Xodus (crates/xodus-cli/src/commands/run.rs) decrypts the title's executable
into a file descriptor, leaves the encrypted bytes at the real path, and starts
Wine with WINE_DLL_FILE_MAP="<fd>:\\??\\Z:<path>" and the NT path as argument.
This script reproduces exactly that with a test program instead of a game:

  <workdir>/game/selfread.exe   garbage of the same size (the "encrypted" copy)
  descriptor <fd>               the real selfread.exe (the "decrypted" copy)

--fd-kind chooses how the descriptor is made:
  memfd     Linux memfd_create (what Xodus does on Linux)
  unlinked  a temporary file deleted right after creation (what Xodus does on
            macOS today: tempfile_in() on its RAM disk)
  named     a temporary file that keeps its name until the run ends (what the
            proposed Xodus change does on macOS)

The probe prints PASS/FAIL lines; the exit code is the number of failures.
Nothing outside --workdir is written. Python 3.8+, no third-party modules.
"""
import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def make_fd(kind, data, tmpdir):
    if kind == "memfd":
        fd = os.memfd_create("selfread", 0)
        path = None
    else:
        fd, path = tempfile.mkstemp(prefix="selfread-image-", dir=tmpdir)
        if kind == "unlinked":
            os.unlink(path)
            path = None
    os.write(fd, data)
    os.lseek(fd, 0, os.SEEK_SET)
    os.set_inheritable(fd, True)
    return fd, path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wine", default=os.environ.get("WINE", "wine"), help="wine binary (default: $WINE or wine)")
    ap.add_argument("--exe", default=os.path.join(HERE, "selfread", "selfread.exe"))
    ap.add_argument("--fd-kind", choices=["memfd", "unlinked", "named"],
                    default="memfd" if sys.platform.startswith("linux") else "unlinked")
    ap.add_argument("--workdir", default=None, help="where the fake game folder goes (default: a new temp dir)")
    ap.add_argument("--keep", action="store_true", help="keep the work directory")
    ap.add_argument("--log", default=None, help="also write the combined output here")
    ap.add_argument("--dyld-library-path", default=None,
                    help="DYLD_LIBRARY_PATH for Wine (macOS). Needed because macOS strips DYLD_* variables "
                         "when a system binary such as /usr/bin/python3 starts, so an exported value never "
                         "reaches Wine. Default on macOS: <wine root>/lib, next to bin/wine.")
    ap.add_argument("--prefix", default=None,
                    help="WINEPREFIX to use (default: a throw-away one inside the work directory, so your "
                         "game prefix is never touched)")
    ap.add_argument("probe_args", nargs="*", help="passed to selfread.exe (--no-files / --no-traps)")
    args = ap.parse_args()

    data = open(args.exe, "rb").read()
    workdir = args.workdir or tempfile.mkdtemp(prefix="selfread-run-")
    game = os.path.join(os.path.abspath(workdir), "game")
    os.makedirs(game, exist_ok=True)
    target = os.path.join(game, "selfread.exe")
    # the copy on disk is unreadable as a program, like an encrypted MSIXVC payload
    rnd = random.Random(1)
    with open(target, "wb") as f:
        f.write(bytes(rnd.getrandbits(8) for _ in range(len(data))))
    with open(os.path.join(game, "selfread-plain.txt"), "w") as f:
        f.write("an ordinary file next to the image\n")

    fd, fd_path = make_fd(args.fd_kind, data, workdir)
    nt_path = "\\??\\Z:" + target.replace("/", "\\")
    env = dict(os.environ)
    env["WINE_DLL_FILE_MAP"] = f"{fd}:{nt_path}"
    env.setdefault("WINEDEBUG", "err+all")
    # a new prefix otherwise stops on the hidden "install Mono/Gecko?" prompt
    env.setdefault("WINEDLLOVERRIDES", "mscoree,mshtml=")
    dyld = args.dyld_library_path
    if dyld is None and sys.platform == "darwin":
        dyld = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(args.wine))), "lib")
    if dyld:
        env["DYLD_LIBRARY_PATH"] = dyld
        print(f"# DYLD_LIBRARY_PATH={dyld}")
    env["WINEPREFIX"] = os.path.abspath(args.prefix or os.path.join(workdir, "prefix"))
    print(f"# fd-kind={args.fd_kind} fd={fd} fd-path={fd_path} image-bytes={len(data)}")
    print(f"# WINE_DLL_FILE_MAP={env['WINE_DLL_FILE_MAP']}")
    print(f"# WINEPREFIX={env['WINEPREFIX']}")
    sys.stdout.flush()

    proc = subprocess.run([args.wine, nt_path] + args.probe_args, env=env, pass_fds=(fd,),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = proc.stdout.decode("utf-8", "replace")
    sys.stdout.write(out)
    print(f"# exit code {proc.returncode}")
    if args.log:
        with open(args.log, "w") as f:
            f.write(out)
            f.write(f"# exit code {proc.returncode}\n")

    os.close(fd)
    if not args.keep and not args.workdir:
        shutil.rmtree(workdir, ignore_errors=True)
    return proc.returncode


if __name__ == "__main__":
    sys.exit(main())
