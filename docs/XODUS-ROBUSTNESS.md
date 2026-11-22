# xodus and the Xbox connection: 50 robustness features

MetalHorizon downloads Forza Horizon 6 and talks to Xbox through xodus-cli, which ships inside the app, from the
`work/xodus` tree with `patches/xodus-cli`. Its logs and code showed what went wrong:

- **Panics.** `unwrap()` and `expect()` sit on every network and Keychain call. A cancelled Keychain prompt crashed the
  download (`Keychain(PlatformFailure(-128))`, 10 November). Xbox answering 400 crashed it eight times on 28 and
  29 October (`Failed to authenticate Xbox user`).
- **"Download finished." without the game.** xodus gave up for lack of room and exited with success (21 November,
  fixed by 0007).
- **No end to failures.** A file whose server stops answering is asked again every 5 seconds, forever, with no pause
  in between, so offline it spins. A full disk is written to again every 30 seconds, forever.
- **No resume.** A download interrupted at 90 % starts again from zero.
- **Stop counted as an error.** Pressing Stop showed "The download stopped (error 15)".

The features below answer these. The **A, B and C** features are in xodus-cli
(`patches/xodus-cli/0008-xodus-cli-robustness.patch`). The **D and E** features are in the app
(`app/Sources/MetalHorizon/XodusSupervisor.swift` and its tests).

## A. Network (xodus-cli and msixvc)
1. **A tuned HTTP client.** It gives up on connecting after 20 s, keeps TCP connections alive, and closes idle ones.
   There is no limit on a whole response, which would cut a long file.
2. **Retry with backoff.** A failed Microsoft or Xbox call is tried again, after a pause that doubles from 1 s up to
   60 s, with some randomness so retries do not land together.
3. **Transient or final.** A dropped connection, a timeout, 408, 425, 429 and 5xx are tried again. 400, 401, 403 and 404
   are not, since asking again cannot help.
4. **Retry-After.** On 429 or 503, the pause is the one the server asks for.
5. **Product lookup retried.** The Display Catalog lookup (`get_content_id`) is retried.
6. **Package lookup retried and checked.** `GetBasePackage` is retried, its HTTP status is checked, and an answer that
   is not JSON is a clear error instead of a panic.
7. **Licence retried.** The licence and its two SOAP token exchanges are retried on transient errors. This helps every
   Play too, since `xodus-cli run` asks for the licence at each start.
8. **The package index opens again.** Opening the package over HTTP, and reopening it after a cut, is retried with a
   pause instead of crashing.
9. **CDN mirrors.** Every `cdn_root_paths` of the package is used: a file that fails on one mirror moves to the next.
10. **No spinning offline.** Between two attempts at a file the pause grows from 0.5 s to 30 s, and after 10 minutes
    without a single byte the file fails properly.

## B. The download (xodus-cli streaming)
11. **No panic while downloading.** The folder, the cache, the index, the metadata and the final rename each give a
    message and a clean failure.
12. **A failed file is tried again.** It is fetched again up to 5 times, from a fresh request, instead of the whole
    download stopping.
13. **Resume.** The files already done are listed in `.xodus-streaming-done`, tied to the package. An interrupted
    download starts again where it was.
14. **Room for what is left.** The room check counts only the files still to fetch.
15. **Early room check.** Under 2 GB free, xodus stops at once, before fetching the index of about 1 GB.
16. **Size checked.** A finished file must have its exact size before it is listed as done.
17. **Written to disk.** A finished file is flushed to the disk (fsync) before it is listed as done.
18. **Full disk.** A failed write is tried three times, to give time to free room, then stops with a `no-space` error
    instead of waiting forever.
19. **Clean stop.** On SIGINT or SIGTERM, the files done stay listed and xodus exits with 130, meaning paused and
    resumable.
20. **Lines the app reads.** `status <phase>` gives the step (index, licence, files, finishing). `error <kind> <message>`
    gives why it failed: no-space, not-owned, signed-out, keychain, network, disk or package.

## C. Xbox sign-in and tokens
21. **Keychain refused.** A denied or cancelled Keychain prompt no longer crashes xodus. It gives a `keychain` error
    that says to choose Always Allow.
22. **No account.** With no sign-in saved, xodus gives a `signed-out` error instead of crashing.
23. **The device token's expiry is checked.** Before, only whether it existed was checked. An expired one is renewed
    before use.
24. **Renewal on refusal.** When Microsoft refuses a token exchange, the device token is renewed once and the exchange
    tried again, as xodus-service has done since 0005.
25. **Expired sign-in.** A user token that has expired or is refused gives `signed-out`, "sign in again", instead of
    `panic!("TODO")`.
26. **Device registration.** Registering the Mac with Microsoft is retried on network errors and fails cleanly
    otherwise.
27. **Clock.** When Xbox authentication fails, xodus compares the Mac's clock with Microsoft's `Date` header and says
    when it is more than 5 minutes off.
28. **Atomic sign-in status.** The sign-in status file is written to a temporary file, then renamed, so the app never
    reads half a status.
29. **The exchange after sign-in is retried.** A network blip right after the player signs in no longer wastes the
    sign-in. If it still fails, the status is `network_error`.
30. **Not owned.** "Package was not found" becomes a `not-owned` error, saying the account must own the game.

## D. The app: download supervisor
31. **The Mac stays awake.** Idle sleep is held off while the game downloads.
32. **Automatic resume.** After a transient failure (network, servers, a file that would not come), the download
    starts again by itself, up to 5 times, waiting 30 s, then 1, 2, 4 and 8 minutes.
33. **Waits for the network.** Offline, the resume waits for the network to come back instead of failing.
34. **Watchdog.** With no progress for 10 minutes, xodus is restarted, and resumes where it was.
35. **Stop is a pause.** Stop asks xodus to stop cleanly (SIGINT), and the window says the download is paused and that
    Download the Game resumes it.
36. **Checks before starting.** The window checks that the folder can be written to, is not in iCloud Drive, and has
    room, and that Microsoft can be reached.
37. **Clear failures.** xodus' `error` lines become a sentence with the next step: free room, sign in again, Always
    Allow, own the game, or the network.
38. **Steps shown.** xodus' `status` lines show: "Reading the package's index…", "Checking the licence…",
    "Finishing…".
39. **Resume announced.** When files are already done, the window says the download resumes and how many files are
    there.
40. **Checked at the end.** If xodus ends without error but the game is not complete, the window resumes once by
    itself.

## E. The app: Xbox connection
41. **Microsoft reachable.** Before the sign-in window opens, Microsoft must be reachable, so the window is not empty.
42. **Clock checked.** Before signing in, a clock more than 5 minutes off is reported with how to fix it.
43. **Clean start.** The previous status file and a leftover Xodus Login window are cleared before signing in.
44. **The helper starts again.** If the sign-in helper fails to open, it is tried once more.
45. **Sign-in watchdog.** With no change for 15 minutes, the sign-in ends cleanly with a message, instead of
    "Signing In…" forever.
46. **New states understood.** `network_error` and `keychain_denied` from xodus become clear messages.
47. **Keychain checked again.** After `complete`, the saved account is looked for again in the Keychain three times,
    since it can lag, before saying it failed.
48. **Account check retried.** The account check is tried again on a network error, after 5 s and then 15 s, before
    giving a verdict.
49. **Accepted account remembered.** An accepted account check is kept for 5 minutes: Play starts faster and asks
    Microsoft less.
50. **No download while signed out.** Without a saved account, the download does not start: the window points to
    Sign In.

## How it is tested
None of these could be tried on a real download or sign-in: there was no room for the game on the test Mac, and the
sign-in is the player's. Each one is tested without them:
- **xodus-cli: 17 tests.** The retry, backoff, Retry-After and clock logic; the typed errors and their lines; the
  journal; the mirrors; the sizes. Two of them run against a local HTTP server: 503 then 429 with `Retry-After: 1`
  then 200, and a final 404 that is not asked again.
- **msixvc: 20 tests, one new.** The package is opened again after a dropped connection, and the pause doubles up to
  30 s.
- **xodus.** A device token is renewed when it has expired or is about to.
- **The app: XodusSupervisorTests, 15 tests.** xodus' lines, every decision at the end of a download, the watchdog's
  limits, the checks before a download and before a sign-in, the sign-in states and watchdog, and the account check
  retried then kept. The whole suite is 112 tests.
