/* udpopts.c (2026-11-13): IPv4 options on a dual-stack UDP socket, for patches/0034 and 0035 (arm64 0059 and 0060).
 * Opens a UDP socket as Forza Horizon 6 does before matchmaking (AF_INET6, IPV6_V6ONLY 0, bound to [::],
 * SIO_UDP_CONNRESET and SIO_UDP_NETRESET), reads three of the IPv4 options before anything sets them (Windows reports
 * its defaults), then sets and reads back all four, sends to an IPv4 socket through ::ffff:127.0.0.1, and checks
 * that an AF_INET socket's own IPv4 options still work. 26 checks; every one should pass, as on Windows. Under Wine on
 * macOS without the patches, SIO_UDP_NETRESET fails with 10045 and the IPv4 options on the dual-stack socket with
 * 10022 (WSAEINVAL): 12 of 26. Prints a FAIL line per failed check and "N of 26 checks failed"; exits 1 on any. */

#include <winsock2.h>
#include <ws2tcpip.h>
#include <mstcpip.h>
#include <stdio.h>

#ifndef SIO_UDP_CONNRESET
#define SIO_UDP_CONNRESET _WSAIOW(IOC_VENDOR, 12)
#endif
#ifndef SIO_UDP_NETRESET
#define SIO_UDP_NETRESET _WSAIOW(IOC_VENDOR, 15)
#endif

static int failures, checks;

static void check(int ok, const char *what)
{
    checks++;
    if (ok) return;
    failures++;
    printf("FAIL: %s (%d)\n", what, WSAGetLastError());
}

/* An IPPROTO_IP option: set, then read back as set. */
static void check_option(SOCKET s, int option, DWORD value, const char *what)
{
    DWORD got = 0xdeadbeef;
    int length = sizeof(got);

    check(!setsockopt(s, IPPROTO_IP, option, (const char *)&value, sizeof(value)), what);
    check(!getsockopt(s, IPPROTO_IP, option, (char *)&got, &length) && got == value, what);
}

/* An IPPROTO_IP option read before anything set it: a value from low to high, as Windows reports its defaults
 * (macOS's IPv6 counterparts read -1 until set, which a program would see as 4294967295). */
static void check_default(SOCKET s, int option, DWORD low, DWORD high, const char *what)
{
    DWORD got = 0xdeadbeef;
    int length = sizeof(got);

    check(!getsockopt(s, IPPROTO_IP, option, (char *)&got, &length) && got >= low && got <= high, what);
    printf("%s: %lu\n", what, (unsigned long)got);
}

int main(void)
{
    struct sockaddr_in6 any6, mapped;
    struct sockaddr_in loopback;
    DWORD off = 0, returned, timeout = 2000;  /* a lost datagram fails the check, not hangs */
    int length = sizeof(loopback);
    SOCKET dual, ipv4;
    WSADATA wsa;
    char data[16];

    WSAStartup(MAKEWORD(2, 2), &wsa);

    dual = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
    check(dual != INVALID_SOCKET, "socket AF_INET6");
    check(!setsockopt(dual, IPPROTO_IPV6, IPV6_V6ONLY, (const char *)&off, sizeof(off)), "IPV6_V6ONLY 0");
    memset(&any6, 0, sizeof(any6));
    any6.sin6_family = AF_INET6;
    any6.sin6_addr = in6addr_any;
    check(!bind(dual, (struct sockaddr *)&any6, sizeof(any6)), "bind [::]");
    check(!WSAIoctl(dual, SIO_UDP_CONNRESET, &off, sizeof(off), NULL, 0, &returned, NULL, NULL), "SIO_UDP_CONNRESET");
    check(!WSAIoctl(dual, SIO_UDP_NETRESET, &off, sizeof(off), NULL, 0, &returned, NULL, NULL), "SIO_UDP_NETRESET");

    check_default(dual, IP_TTL, 1, 255, "IP_TTL default on the dual-stack socket");
    check_default(dual, IP_MULTICAST_TTL, 1, 1, "IP_MULTICAST_TTL default on the dual-stack socket");
    check_default(dual, IP_DONTFRAGMENT, 0, 0, "IP_DONTFRAGMENT default on the dual-stack socket");
    check_option(dual, IP_DONTFRAGMENT, 1, "IP_DONTFRAGMENT on the dual-stack socket");
    check_option(dual, IP_TTL, 255, "IP_TTL on the dual-stack socket");
    check_option(dual, IP_MULTICAST_TTL, 4, "IP_MULTICAST_TTL on the dual-stack socket");
    check_option(dual, IP_MULTICAST_LOOP, 0, "IP_MULTICAST_LOOP on the dual-stack socket");

    ipv4 = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    check(ipv4 != INVALID_SOCKET, "socket AF_INET");
    check(!setsockopt(ipv4, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout, sizeof(timeout)), "SO_RCVTIMEO");
    memset(&loopback, 0, sizeof(loopback));
    loopback.sin_family = AF_INET;
    loopback.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    check(!bind(ipv4, (struct sockaddr *)&loopback, sizeof(loopback)), "bind 127.0.0.1");
    check(!getsockname(ipv4, (struct sockaddr *)&loopback, &length), "getsockname");

    memset(&mapped, 0, sizeof(mapped));
    mapped.sin6_family = AF_INET6;
    mapped.sin6_port = loopback.sin_port;
    inet_pton(AF_INET6, "::ffff:127.0.0.1", &mapped.sin6_addr);
    check(sendto(dual, "fh6", 3, 0, (struct sockaddr *)&mapped, sizeof(mapped)) == 3, "send to ::ffff:127.0.0.1");
    check(recv(ipv4, data, sizeof(data), 0) == 3, "receive on 127.0.0.1");

    check_option(ipv4, IP_TTL, 77, "IP_TTL on an AF_INET socket");
    check_option(ipv4, IP_DONTFRAGMENT, 1, "IP_DONTFRAGMENT on an AF_INET socket");

    closesocket(ipv4);
    closesocket(dual);
    WSACleanup();
    printf("%d of %d checks failed\n", failures, checks);
    return failures != 0;
}
