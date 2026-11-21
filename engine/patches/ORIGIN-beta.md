# Blackwell Engine Beta (alpha): what is in it, and where it comes from

The beta engine is the public Rosetta engine (`series`, `series-steam`) plus the patches after `# --- Beta` in
`series-beta` and `series-steam-beta`, built by `engine/build-beta.sh`. MetalHorizon installs it only in beta mode
(Settings › Advanced › Beta engine), beside the public engine, and removes it when the player goes back to Public.

## Highball's Rosetta-line patches (LGPL-2.1-or-later)

Copied verbatim from https://github.com/gauthierpiarrette/highball-engine/tree/main/patches (Gauthier Piarrette and
the contributors named in each header), file names prefixed `hb-`:

| File | What it does |
|---|---|
| `hb-0005-ntdll-yield-after-auto-event-set.patch` | msync: the thread that sets an auto-reset event yields, so the one it wakes runs at once |
| `hb-0014-msync-unregister-early-return.patch` | msync: a multi-object wait that returns early takes its registration back (highball#224) |
| `hb-0015-winecoreaudio-io-buffer-under-half-a-period.patch` | winecoreaudio: each pull from the device stays under half a period (highball#127) |
| `hb-0025-ntdll-threadpool-io-release-once.patch` | CloseThreadpoolIo and the I/O completion thread no longer both free the object |
| `hb-0028-ntdll-crash-on-faults-in-foreign-threads.patch` | a fault on a thread Wine did not create ends the program instead of hanging it |

## The Blackwell Pacer (Blackwell Engine's own code)

`0016-ntdll-blackwell-pacer.patch` adds `engine/src/pacer/bw_pacer.h` to ntdll's Unix side. The problem it answers,
and the countermeasure's principle (a thread running large functions never seen before), were found by Mathias
Kowoll for MacGameFix (https://github.com/MathiasKowoll/MacGameFix, GPL-3.0: `fixes/fh6-d3d12/pacer.h`,
`tools/rosetta-store-stop/trapfreeze.c`), after Gauthier Piarrette (Highball) first reported Forza Horizon 6's
protection under Rosetta. The code here is written for Blackwell Engine and differs in where it lives (ntdll, so no
DLL has to be loaded by the game), in how it starts (only in `BW_PACER_EXE`, only when Rosetta translates the
process, signals blocked) and in `BW_PACER=auto`, which tunes its duty from the stops it sees itself. Measured in
`engine/tests/rosetta-pacer/README.md`.

## The Blackwell Trap Boost (since 1.3a2, Blackwell Engine's own code)

The same patch adds `engine/src/pacer/bw_trapboost.h`: Rosetta's exception server (`com.apple.rosetta.exceptionserver`,
the one thread that services every trap of a translated process) raised to the latency and throughput tiers and the
precedence of a highest-priority thread, when `BW_TRAP_BOOST=1` (set by MetalHorizon in beta mode). The finding is
MacGameFix's (NotProton's `rosetta-trap-boost` plugin, `engine/sources/fh6-20261111/rosetta-trap-boost.c`, a library
injected into the process); here a thread in ntdll does it, only in `BW_PACER_EXE`, only under Rosetta. MetalHorizon's
beta mode also shows the game at most 8 processors (`WINENCPU=8`, which this engine's ntdll understands), as
MacGameFix recommends: fewer of its worker threads compete for the translator.

MacGameFix's other Forza Horizon 6 change, a fast path in ntdll's exception dispatcher that executes the simple
instructions between the protection's traps itself (its `0023`, about 1,800 lines of x86 instruction emulation for
Wine 11.21), is not in this alpha: on this engine's base it cannot be checked without the game, and an emulation
mistake would change the game's state silently.
