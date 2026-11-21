# Rosetta's translator stops, and the Blackwell Pacer

`pacer_bench.c` (a macOS x86_64 program) and `pacer_bench_win.c` (a Windows program, run inside Wine) put Forza
Horizon 6's protection's load on Rosetta: threads that trap on `ud2` and step over it, threads that rewrite small
functions in executable pages and call them. Each call is timed; a stop is a call of 20 ms or more. Both build the
pacer from `engine/src/pacer/bw_pacer.h` (the macOS bench) or get it from the engine's ntdll (the Windows bench,
with `BW_PACER_EXE=pacerbench.exe`).

## Measured on an M5 Pro (macOS 27.2), 2 trappers, 3 writers, 4,096 pages

macOS bench, 45 s each (120 s for the last row):

| BW_PACER | Stops of 20 ms or more | Traps a second | Rewrites a second |
|---|---|---|---|
| unset | 2 of 234-242 ms (one every ~18 s) | 42,186 | 65,915 |
| 40,4096 (MacGameFix's played setting) | 0 | 31,125 (-26 %) | 46,079 (-30 %) |
| 40,16384 | 0 | 29,341 | 44,795 |
| auto (settles at 10 %) | 0 | 35,497 (-16 %) | 53,519 (-19 %) |
| auto, 120 s | 0 | 37,769 (-10 %) | 57,002 (-14 %) |

Windows bench inside Wine (Blackwell Engine beta-1.3a1), 60 s each:

| BW_PACER | Stops of 20 ms or more |
|---|---|
| unset | 3 of 197-306 ms (one every ~17 s) |
| auto (settles at 10 %) | 0 |

MacGameFix's own reproducer (`trapfreeze.c`) on the same Mac: 4 stops of 297-302 ms every 12.9 s in 60 s; with its
full-time filler, none, for 58-73 % of the load's throughput.

A bench is not the game: the duty the game needs can differ, which is what `auto` is for. Nothing here was measured
in Forza Horizon 6.
