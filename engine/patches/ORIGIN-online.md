# The online fix (engine 1.2): from Highball, by prsloan (LGPL-2.1-or-later)

`0014-ntdll-dualstack-ipv4-options.patch` (Rosetta engines, CrossOver 26.3 sources) and
`../patches-arm64-xbox/0101-ntdll-dualstack-ipv4-options.patch` (Blackwell Engine Native, Wine 11.18) are copied
verbatim from highball-engine pull request #40 (https://github.com/gauthierpiarrette/highball-engine/pull/40,
`patches/0034-ntdll-dualstack-ipv4-options.patch` and `patches-arm64/0059-ntdll-dualstack-ipv4-options.patch`
there), by prsloan. Highball's patches are LGPL-2.1-or-later; these two files keep that license.

What they fix: before matchmaking, Forza Horizon 6 opens its UDP game socket as `[::]:3074` with `IPV6_V6ONLY` 0 and
sets `IP_DONTFRAGMENT` and `IP_TTL` on it. Windows applies such IPv4 options to a dual-stack socket's IPv4 traffic;
macOS refuses every `IPPROTO_IP` option on an `AF_INET6` socket with `EINVAL`, so Wine answered `WSAEINVAL` (10022),
the game closed the socket, tried two other ports the same way, and never joined an online session. With the patch,
ntdll sets the IPv6 counterpart (`IPV6_DONTFRAG`, `IPV6_UNICAST_HOPS`, `IPV6_MULTICAST_HOPS`, `IPV6_MULTICAST_LOOP`)
when the host refuses the IPv4 option with `EINVAL`; nothing changes for an `AF_INET` socket or any other failure.

The second patch of that pull request (`SIO_UDP_NETRESET`, upstream Wine 19d5fbd382) is not needed here: Blackwell
Engine's network patch (`0006-network.patch`, and its port in `0100`) already accepts `SIO_UDP_NETRESET`.

## Verified (2026-11-20, M5 Pro, macOS 27.2)

`engine/tests/dualstack-udp/udpopts.c` (from the same pull request, MacGameFix's test: 26 checks, the socket opened
the way the game opens it), built with llvm-mingw as an x86-64 program, each engine in a fresh prefix:

| Engine | Failed |
|---|---|
| Blackwell Engine 1.1 (Rosetta, Xbox) | 7 of 26 (the seven dual-stack IPv4 options, 10022) |
| Blackwell Engine 1.2 (Rosetta, Xbox) | 0 of 26 |
| Blackwell Engine steam-1.2 (Rosetta, Steam) | 0 of 26 |
| Blackwell Engine Native 1.1 (FEX, signed loader) | 7 of 26 |
| Blackwell Engine Native 1.2 (FEX, signed loader) | 0 of 26 |
