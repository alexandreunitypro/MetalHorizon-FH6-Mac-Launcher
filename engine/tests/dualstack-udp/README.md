# Dual-stack UDP socket options

`udpopts.c`: the regression test for `patches/0034` and `0035` (arm64 `0059` and `0060`). It opens a UDP socket the
way Forza Horizon 6 opens its game socket before matchmaking: AF_INET6, `IPV6_V6ONLY` 0, bound to `[::]`, then
`SIO_UDP_CONNRESET` and `SIO_UDP_NETRESET`. On that socket it reads `IP_TTL`, `IP_MULTICAST_TTL` and
`IP_DONTFRAGMENT` before anything sets them, then sets and reads back `IP_DONTFRAGMENT`, `IP_TTL`, `IP_MULTICAST_TTL`
and `IP_MULTICAST_LOOP`, sends a datagram to an AF_INET socket through `::ffff:127.0.0.1`, and checks that the AF_INET
socket's own `IP_TTL` and `IP_DONTFRAGMENT` still work. 26 checks.

Windows applies IPPROTO_IP options on a dual-stack socket to its IPv4 traffic, so every check should pass there. macOS
refuses every IPPROTO_IP option on an AF_INET6 socket with EINVAL, so without `0034` the eleven checks on the
dual-stack socket's IPv4 options fail with 10022 (WSAEINVAL), and without `0035` `SIO_UDP_NETRESET` fails with 10045.
The game gives up on the socket at the first of these, so it never joins a session.

Output: a `FAIL: <check> (<WSAGetLastError>)` line per failed check, the three defaults read back as `<check>: <value>`,
then `N of 26 checks failed`. Exit status 0 when all pass, 1 otherwise.

```sh
x86_64-w64-mingw32-clang -O2 -Wall -Wextra -Werror udpopts.c -lws2_32 -o udpopts.exe
aarch64-w64-mingw32-clang -O2 -Wall -Wextra -Werror udpopts.c -lws2_32 -o udpopts-arm64.exe   # arm64 line, native
wine udpopts.exe
```

Run on 2026-11-18 (llvm-mingw, clang 23.1.4; M5 Pro, macOS 27.3 beta), each in a fresh prefix:

| Engine | Program | Failed |
|---|---|---|
| x64-crossover26.3-r33 as shipped | udpopts.exe | 12 of 26 (`SIO_UDP_NETRESET` and the eleven dual-stack IPv4 options) |
| x64-crossover26.3-r32 with 0034 and 0035 | udpopts.exe | 0 of 26 |
| arm64-kk-wine11.18-r4 with 0059 and 0060 | udpopts-arm64.exe | 0 of 26 |
| arm64-kk-wine11.18-r4 with 0059 and 0060 | udpopts.exe (x86-64, through FEX) | 0 of 26 |

On 2026-11-14 the same program failed 12 of 26 on arm64-kk-wine11.18-r4 as shipped.

On real Windows, built with the pinned llvm-mingw 20260922 as `x64-fidelity.yml` builds its tests (GitHub Actions,
2026-11-18):

| Windows | Program | Failed | Defaults read (IP_TTL, IP_MULTICAST_TTL, IP_DONTFRAGMENT) |
|---|---|---|---|
| Server 2022 (10.0.20348) | udpopts.exe | 0 of 26 | 128, 1, 0 |
| Server 2025 (10.0.26100) | udpopts.exe | 0 of 26 | 128, 1, 0 |
| 11 ARM64 (10.0.26200) | udpopts-arm64.exe | 0 of 26 | 128, 1, 0 |
| 11 ARM64 (10.0.26200) | udpopts.exe (x64 emulation) | 0 of 26 | 128, 1, 0 |

Read before anything sets it, `IP_TTL` reports macOS's `net.inet.ip.ttl` (64) with the patch, where Windows reports
128; the check accepts 1 to 255.

What it does not cover: `IP_TOS`, which the patch leaves alone; the side effect noted in `0034`'s header, where after
`IP_DONTFRAGMENT` a datagram larger than the path MTU to an IPv6 peer fails with WSAEMSGSIZE; and the game itself,
which was checked separately (FH6 online on both lines, 2026-11-14).
