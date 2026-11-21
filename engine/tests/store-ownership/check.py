#!/usr/bin/env python3
"""Checks what ownership_test.exe printed (engine/tests/store-ownership).

  python3 -I check.py normal <run log> <owned.txt>    the stand-in service answers
  python3 -I check.py fallback <run log>              it fails, or there is none: everything as before 1.1.1
"""
import sys

GAME = "9NR1R1XWLCNB"


def lines(path, prefix):
    with open(path, errors="replace") as f:
        return [l.split() for l in f if l.startswith(prefix + " ")]


def field(parts, name):
    return next(p.split("=", 1)[1] for p in parts if p.startswith(name + "="))


def hr(path, name):
    with open(path, errors="replace") as f:
        for l in f:
            if l.startswith(name + "-hr "):
                return int(l.split()[1], 16)
    raise SystemExit(f"FAIL: no {name}-hr line")


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    return ok


def main():
    mode, log = sys.argv[1], sys.argv[2]
    good = True
    pictures = lines(log, "picture")
    entitled = {p[1]: p for p in lines(log, "entitled")}
    licences = {p[1].split("/")[0] for p in lines(log, "licence")}
    good &= check(hr(log, "entitled") == 0, "the entitled products are answered (never an error)")
    good &= check(GAME in entitled and field(entitled[GAME], "owned") == "1", "the game is among them, owned")
    good &= check(len(pictures) == 4 and all(p[3] == "0" for p in pictures), "four gamer pictures, never an error")
    if mode == "normal":
        owned = set(open(sys.argv[3]).read().split())
        listing = lines(log, "listing")
        mine = {p[1] for p in listing if field(p, "owned") == "1"}
        good &= check(hr(log, "listing") == 0 and len(listing) > len(mine) > 0, f"the store lists {len(listing)} add-ons, {len(mine)} owned")
        good &= check(mine <= owned, "only what the account owns is marked owned")
        good &= check(all(field(p, "owned_skus") == field(p, "skus") for p in listing if p[1] in mine), "with their SKUs (quantity 1)")
        good &= check(licences == mine, f"one add-on licence for each owned add-on ({len(licences)})")
        durables = {i for i, p in entitled.items() if field(p, "kind") == "2"}
        good &= check(durables == mine, "the entitled products are the game and the owned add-ons")
        sides = [p[-1] for p in pictures]
        good &= check(sides == ["64x64", "208x208", "424x424", "1080x1080"], "the profile's picture, in the size asked: " + " ".join(sides))
    else:
        good &= check(set(entitled) == {GAME}, "the entitled products: the game alone")
        good &= check(not licences and hr(log, "licences") == 0, "no add-on licence, and no error")
        good &= check(all(p[-1] == "64x64" for p in pictures), "the plain 64x64 picture stands in")
    print("PASS" if good else "FAILED")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
