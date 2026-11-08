import Foundation

// What MetalHorizon knows about the problems players have met: each known problem has the log lines that show it,
// what it means in plain words, and what to do. After every run the session's logs are scanned and the findings
// shown under Diagnosis; the MCP server reads the same table. The checks before Play (preflight) live here too, and
// the diagnostics bundle a player can attach to a GitHub issue.

enum Severity: String, Comparable {
    case info, warning, error
    static func < (a: Severity, b: Severity) -> Bool {
        let order: [Severity] = [.info, .warning, .error]
        return order.firstIndex(of: a)! < order.firstIndex(of: b)!
    }
}

struct KnownIssue {
    let id: String
    let title: String
    let patterns: [String]          // regular expressions, case-insensitive, matched line by line
    let explanation: String
    let fix: String
    var severity: Severity = .error
    var edition: Edition? = nil     // nil: both editions
}

struct Finding: Identifiable, Hashable {
    let issue: KnownIssue
    let evidence: String            // the first matching line, secrets removed
    let source: String              // which file it came from
    var count = 1
    var id: String { issue.id }

    static func == (a: Finding, b: Finding) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PreflightItem: Identifiable {
    let id: String
    let title: String
    let check: Check
    var severity: Severity { check.ok ? (check.fix == nil ? .info : .warning) : .error }
}

enum Diagnostics {
    static let issues: [KnownIssue] = [
        // Steam edition
        KnownIssue(id: "steam-download-blocked", title: "Steam's installer could not be downloaded",
                   patterns: [#"curl: \(60\).*steampowered"#, #"no alternative certificate subject name matches target host name '[^']*steam"#,
                              #"could not be downloaded from any of Valve's servers"#],
                   explanation: "A server answered for Steam with the wrong certificate. On some networks cdn.steampowered.com lands on a generic Akamai server that returns the Steam store page instead of the installer. A VPN, a proxy, a captive portal or a DNS filter can do the same.",
                   fix: "MetalHorizon 0.4 downloads from Valve's other servers (akamai, media, cloudflare, fastly). If all of them fail, try another network or turn off the VPN or filter, then Install Steam again.",
                   edition: .steam),
        KnownIssue(id: "no-32bit-engine", title: "The engine has no 32-bit half",
                   patterns: [#"syswow64.ntdll\.dll.*c0000135"#, #"has no 32-bit half"#],
                   explanation: "Steam's installer and the Steam client are 32-bit programs. Blackwell Engine Steam 1.0 was built without the 32-bit half (lib/wine/i386-windows), so every 32-bit program stops with error c0000135.",
                   fix: "Install Blackwell Engine Steam 1.1 or later: MetalHorizon 0.4 installs it by itself (Install the Engine). Do not copy CrossOver's 32-bit files into it.",
                   edition: .steam),
        KnownIssue(id: "steam-window-d3dmetal", title: "Steam's web views were given D3DMetal",
                   patterns: [#"NSViewBackingLayer setDisplaySyncEnabled"#],
                   explanation: "D3DMetal cannot draw Steam's own web views: the Steam client aborts on macOS 27 (setDisplaySyncEnabled on a plain layer). In MetalHorizon 0.4.0 the silent Steam client that starts the game hit this.",
                   fix: "Update to MetalHorizon 0.4.1 or later (it updates itself): the silent client's web views run without the GPU, and if Steam still cannot start the game, MetalHorizon starts it itself with Steam beside it.",
                   edition: .steam),
        KnownIssue(id: "steam-black-window", title: "Steam's window stays black",
                   patterns: [#"Browser requested transparent background, but it is not supported"#, #"Invalid browser dimensions: 0 x 0"#,
                              #"skia_output_surface_impl.*surface_size=1x1"#, #"Reinitialized the GPU process after a crash"#],
                   explanation: "Steam's web views did not reach the window. On Wine 11 this happens when Steam's GPU acceleration is off, when it runs under D3DMetal, or with an engine without Highball's cross-process swap-chain patch (0011).",
                   fix: "Open Steam from MetalHorizon (DXMT, sync off). In Steam's Settings › Interface, leave 'GPU accelerated rendering in web views' on. Do not start Steam with -cef-disable-gpu.",
                   severity: .warning, edition: .steam),
        KnownIssue(id: "msync-mismatch", title: "Two programs in one prefix with different sync modes",
                   patterns: [#"msync_init Failed bootstrap_look_up"#, #"err:sync:msync_init"#],
                   explanation: "Wine fixes the sync mode when a prefix's server starts. A program started with msync while the server runs without it (or the reverse) dies at once.",
                   fix: "Let MetalHorizon start Steam and the game: it joins the running mode or restarts Steam first. If you start programs by hand, stop the prefix first (Stop Steam).",
                   edition: .steam),
        KnownIssue(id: "steam-interstitial", title: "Steam is waiting for an answer before starting the game",
                   patterns: [#"LaunchApp waiting for user response to ShowInterstitials"#, #"waiting for user response"#],
                   explanation: "Steam shows a dialog before the first launch (a licence agreement, a cloud-save choice, an update). In game mode its window is hidden, so it waits.",
                   fix: "Click Open Steam, answer the dialog (start the game once from Steam's Library if needed), then use Play again.",
                   severity: .warning, edition: .steam),
        KnownIssue(id: "steam-auth", title: "The game got no sign-in (E:0-0-L-8)",
                   patterns: [#"E:0-0-L-8"#, #"Initialization failed"#, #"初始化失败"#],
                   explanation: "The game started without receiving its account: on Steam, the ticket the Steam client hands it; on Xbox, the session xodus-service passes on. It then shows its own sign-in prompt and fails with E:0-0-L-8, or stays on 'Welcome, Player'.",
                   fix: "Start it with Play in MetalHorizon. Steam: when a run started the game beside Steam gets this, MetalHorizon goes back to letting Steam start it at the next Play; sign in once in Steam's window first. Xbox: sign in again with Microsoft. If it stays, send the diagnostics (Activity › Export Diagnostics)."),
        KnownIssue(id: "steam-unresponsive", title: "Steam's web helper hung",
                   patterns: [#"killing unresponsive browser"#, #"steamwebhelper is not responding"#],
                   explanation: "Steam's interface hangs under msync or esync.",
                   fix: "Stop Steam, then Open Steam from MetalHorizon: the window runs with sync off.",
                   severity: .warning, edition: .steam),
        KnownIssue(id: "steam-first-update", title: "Steam quit after its first update",
                   patterns: [#"BMainLoop appears to have stalled"#, #"fatal stalled cross-thread pipe"#, #"nested exception on signal stack"#],
                   explanation: "A Steam client regression (also on Linux): a brand-new client can quit during or right after its first self-update. A client that has signed in once is stable.",
                   fix: "Click Open Steam again: the update resumes where it stopped. Sign in once it shows the window.",
                   severity: .warning, edition: .steam),
        KnownIssue(id: "steam-service", title: "Steam Client Service did not start",
                   patterns: [#"Steam Client Service.*(GLE 126|failed)"#],
                   explanation: "steamservice.exe does not run under Wine. Forza Horizon 6 does not need it.",
                   fix: "Nothing to do.", severity: .info, edition: .steam),
        KnownIssue(id: "steam-native-running", title: "Steam for macOS holds the session",
                   patterns: [#"NO CONNECTION"#],
                   explanation: "Steam for macOS and the Steam in MetalHorizon's prefix cannot both be signed in to the same account.",
                   fix: "Quit Steam for macOS, then Open Steam in MetalHorizon again.", severity: .warning, edition: .steam),

        // Both editions: the engine and D3DMetal
        KnownIssue(id: "ane-init", title: "D3DMetal stopped while preparing the Neural Engine",
                   patterns: [#"com\.apple\.appleneuralengine.*Code=26"#, #"doCompileModel:csIdentity"#],
                   explanation: "Apple's D3DMetal compiles a Core ML model for its frame interpolator when the game starts. Wine processes have no code-signing identity for it, and depending on timing it aborts the game.",
                   fix: "MetalHorizon relaunches the game by itself (twice at most; Options › Relaunch After D3DMetal Start-up Failure). If it keeps happening, quit other apps that use the Neural Engine and try again.",
                   severity: .warning),
        KnownIssue(id: "path-too-long", title: "The game refused its installation path",
                   patterns: [#"Installation path is too long"#],
                   explanation: "Forza Horizon 6 checks the length of the folder it runs from.",
                   fix: "Xbox edition: use a short, real folder such as ~/FH6. Steam edition: let Steam start the game (Play), which runs it from C:\\Program Files (x86)\\Steam, and keep the Steam prefix MetalHorizon creates."),
        KnownIssue(id: "fh205", title: "The game says the graphics card is not supported",
                   patterns: [#"FH20[56]"#, #"graphics card is not supported"#],
                   explanation: "Without Highball's DirectX 12 shim, or with D3DMetal 3, the game sees an unknown shader model.",
                   fix: "Keep the installed Blackwell Engine and D3DMetal 4: MetalHorizon assembles the shim by itself. Click Install on any red line."),
        KnownIssue(id: "fhe21", title: "The game crashed in its AMD code (FHE21)",
                   patterns: [#"FHE21"#],
                   explanation: "D3DMetal reports an AMD GPU by default, and the game then crashes in its AMD-only path.",
                   fix: "Use MetalHorizon's Play: it reports an NVIDIA RTX 4070, as Highball's recipe does."),
        KnownIssue(id: "concrt140", title: "The game crashed writing to a tiny address",
                   patterns: [#"(write|writing) (access )?(to )?(0x0*9|0x0*29|0000000000000009|0000000000000029)\b"#],
                   explanation: "Since the game's update of 3 November 2026 it fills a concurrent_vector from several threads, and Wine's own concrt140 can hand out memory too early.",
                   fix: "MetalHorizon 0.4 loads Microsoft's concrt140 for the game. If the crash stays, the game folder is missing Microsoft's Visual C++ runtime: verify the game's files."),
        KnownIssue(id: "no-ntdll-so", title: "Wine could not find its own files",
                   patterns: [#"could not load ntdll\.so"#, #"wine: could not load"#],
                   explanation: "The engine was started from a place it was not installed in (a Terminal with a relative path, or a moved or damaged engine folder).",
                   fix: "Start everything from MetalHorizon. If it happens there too, delete ~/Library/Application Support/MetalHorizon/Blackwell Engine* and let the app install it again."),
        KnownIssue(id: "no-freetype", title: "The engine has no FreeType",
                   patterns: [#"Wine cannot find the FreeType font library"#],
                   explanation: "An older engine relied on CrossOver.app's libraries: message boxes have no text.",
                   fix: "Use the Blackwell Engine MetalHorizon installs (clear any custom engine folder).", severity: .warning),
        KnownIssue(id: "no-gnutls", title: "The engine has no encryption support",
                   patterns: [#"no encryption support"#, #"bcrypt.*(no|without) gnutls"#],
                   explanation: "Without GnuTLS, sign-in and cloud saves fail ('Cloud save synchronization failed').",
                   fix: "Use the Blackwell Engine MetalHorizon installs (clear any custom engine folder)."),
        KnownIssue(id: "rosetta-missing", title: "Rosetta is not installed",
                   patterns: [#"Bad CPU type in executable"#],
                   explanation: "Blackwell Engine is an Intel (x86_64) program; Apple silicon Macs run it through Rosetta.",
                   fix: "In Terminal: softwareupdate --install-rosetta --agree-to-license (MetalHorizon's Diagnosis can open it for you)."),
        KnownIssue(id: "killed-9", title: "macOS killed a program at start",
                   patterns: [#"Killed: 9"#, #"killed: 9"#, #"Code Signature Invalid"#],
                   explanation: "macOS stopped a binary it would not run: usually the app still carries the quarantine of the download, or it runs from the Downloads folder (App Translocation).",
                   fix: "Move MetalHorizon to Applications, then right-click › Open once. Diagnosis shows whether the quarantine is still there."),
        KnownIssue(id: "disk-full", title: "The disk is full",
                   patterns: [#"No space left on device"#, #"ENOSPC"#, #"disk full"#],
                   explanation: "A download, the shader cache or a save could not be written.",
                   fix: "Free some space on the game's disk (the game needs about 160 GB, plus 20 GB to play)."),
        KnownIssue(id: "forza-invalid-profile", title: "Forza says \"Invalid profile\" (E:43-1b-4)",
                   patterns: [#"E:43-1b-4"#],
                   explanation: "Forza's servers say the profile the game tries to load is no longer available. It comes from the profile on Microsoft's side, not from the Mac: signing in again does not change it. A profile saved by a newer build of the game (played on an Xbox or a PC since) is one known reason.",
                   fix: "If you played on another device recently, update the game here first (Download the Game again: it only fetches what changed). Otherwise the game's own Try rollback to previous save loads your previous cloud save; the progress since that save may be lost.",
                   severity: .warning, edition: .xbox),
        KnownIssue(id: "licence-not-entitled", title: "Microsoft gave no licence for this account",
                   patterns: [#"not entitled to this content"#, #"satisfactionFailure"#],
                   explanation: "Microsoft's licence server answered that the signed-in account has no licence for Forza Horizon 6: the game was not bought with this account, or its Game Pass plan does not include PC games (PC Game Pass or Game Pass Ultimate does; Essential and Premium do not include this game on PC), or the subscription has ended.",
                   fix: "Check the account: account.microsoft.com/services shows the Game Pass plan and its renewal date. Sign in with the account that owns the game or has the plan (Settings › General › Sign In Again). After renewing a plan, Microsoft can take a few minutes: MetalHorizon asks again at the next Play.",
                   edition: .xbox),
        KnownIssue(id: "xodus-licence-timeout", title: "The Xbox licence request did not answer",
                   patterns: [#"the Xbox licence request did not answer"#],
                   explanation: "xodus asked Microsoft for the game's licence and got no answer for 3 minutes: the network was down or slow, or the Xbox service was stuck.",
                   fix: "MetalHorizon restarts the Xbox service and tries once more by itself. If it keeps happening, check the network (System Settings › Network) and sign in again with Microsoft.",
                   severity: .warning, edition: .xbox),
        KnownIssue(id: "native-emulator-crash", title: "The native engine's x86-64 emulator stopped",
                   patterns: [#"xtajit64\.dll\+0x"#, #"xtajit\.dll\+0x"#, #"libarm64ecfex"#, #"FEX.*(abort|SIGILL|unhandled)"#],
                   explanation: "FEX, which runs the game's x86-64 code on the native engine, stopped the game. Highball's FEX patches cover the copy protection's rewriting; a crash here is new.",
                   fix: "MetalHorizon relaunches the game once, and after two stops in a day runs it on D3DMetal for three days. Send the diagnostics (Activity › Export Diagnostics) so the engine can be fixed."),
        KnownIssue(id: "native-device-lost", title: "The graphics device was lost (native engine)",
                   patterns: [#"VK_ERROR_DEVICE_LOST"#, #"DXGI_ERROR_DEVICE_REMOVED"#, #"[Dd]evice lost"#],
                   explanation: "vkd3d-proton lost its Vulkan device on KosmicKrisp (Metal 4): the GPU stopped a command buffer.",
                   fix: "MetalHorizon relaunches the game once. If it keeps happening, lower the graphics preset in the game; the Autopilot moves the game to D3DMetal after two stops."),
        KnownIssue(id: "native-vulkan-driver", title: "The native engine found no Vulkan driver",
                   patterns: [#"vkCreateInstance failed"#, #"Failed to create Vulkan instance"#, #"No Vulkan device"#, #"kosmickrisp_icd\.json"#, #"Failed to load (the )?Vulkan"#],
                   explanation: "The native engine draws through KosmicKrisp, Mesa's Vulkan driver on Metal 4; Vulkan did not start, so Direct3D 12 had no device.",
                   fix: "MetalHorizon reinstalls the native engine by itself when its files are incomplete; meanwhile D3DMetal runs the game."),
        KnownIssue(id: "native-loader", title: "The native engine's signed loader did not start",
                   patterns: [#"the native engine's (signed loader is missing|loader is not linked)"#, #"Bad CPU type in executable"#, #"cross-architecture"#],
                   explanation: "A Wine that runs natively on Apple silicon needs Highball's signed loader (WineLoader.app), which carries Apple's cross-architecture entitlement. It was missing, moved or not linked.",
                   fix: "MetalHorizon relinks or reinstalls the loader before the next Play, and runs the game on D3DMetal meanwhile."),
        KnownIssue(id: "page-fault", title: "A program crashed (page fault)",
                   patterns: [#"Unhandled page fault"#, #"Unhandled exception"#],
                   explanation: "A Windows program crashed inside Wine. The line names the program and the address.",
                   fix: "Send the diagnostics bundle (Activity › Export Diagnostics) in a GitHub issue: the crash line and the run's settings are what is needed.",
                   severity: .warning),
        KnownIssue(id: "macos-abort", title: "A macOS framework aborted the program",
                   patterns: [#"Terminating app due to uncaught exception"#, #"libc\+\+abi: terminating"#],
                   explanation: "An Objective-C exception ended the Wine process (often a graphics API used on the wrong kind of window).",
                   fix: "Export the diagnostics and open an issue; the exception's name is in the evidence.", severity: .warning),

        // Xbox edition
        KnownIssue(id: "xodus-service-down", title: "xodus-service did not start",
                   patterns: [#"xodus-service did not start"#],
                   explanation: "xodus-service holds the Xbox sign-in and gives the game its tokens. Without it the game cannot sign in, and it may close right away.",
                   fix: "Click Sign In Again…; when macOS asks to let xodus-service use the 'Xodus Service' Keychain item, choose Always Allow. If the app runs from Downloads, move it to Applications first.",
                   edition: .xbox),
        KnownIssue(id: "cloud-save", title: "Cloud saves could not sync",
                   patterns: [#"Cloud save synchronization failed"#],
                   explanation: "The game could not reach Xbox Live through xodus-service.",
                   fix: "Sign in again in MetalHorizon and keep 'Always Allow' for the Keychain item. Then Play.", edition: .xbox),
        KnownIssue(id: "keychain-denied", title: "The Keychain refused xodus the Xbox sign-in",
                   patterns: [#"errSecInteractionNotAllowed"#, #"User interaction is not allowed"#, #"errSecAuthFailed"#,
                              #"Keychain\(PlatformFailure"#, #"User canceled the operation"#],
                   explanation: "macOS did not let xodus read the saved Xbox sign-in: its Keychain window was answered Deny or Cancel (or closed), or the Keychain is locked. xodus then stops at once (exit 101).",
                   fix: "Press Play again and answer Always Allow when macOS asks; if it does not ask any more, Sign In Again (Settings › General).", edition: .xbox),
        KnownIssue(id: "broken-game-link", title: "The game folder points to a game that is gone",
                   patterns: [#"is a link to .*which is gone"#],
                   explanation: "forzahorizon6.exe in the game folder is a link to a folder that was moved or deleted.",
                   fix: "Choose the folder the game is really in (Game folder › Choose…), or move the game back.", edition: .xbox),
        KnownIssue(id: "xodus-package-missing", title: "The game's package is missing from its folder",
                   patterns: [#"\.xodus-streaming\.msixvc is not in"#, #"panicked at crates/xodus-cli/src/commands/run\.rs"#],
                   explanation: "xodus reads the game from its package, the hidden file .xodus-streaming.msixvc in the game folder. When the game files are moved without it, xodus-cli stops at once (\"No such file or directory\").",
                   fix: "Move .xodus-streaming.msixvc into the game folder with the other files (in Finder, Cmd-Shift-. shows hidden files), or Download the Game again into that folder.",
                   edition: .xbox),
        KnownIssue(id: "xbox-not-downloaded", title: "The game is not downloaded",
                   patterns: [#"no forzahorizon6\.exe in"#],
                   explanation: "The game folder has no game in it.",
                   fix: "Sign in, then Download the Game, or choose the folder the game is in.", edition: .xbox),
        KnownIssue(id: "stop-message", title: "Play stopped before starting the game",
                   patterns: [#"^STOP: "#],
                   explanation: "A check before launching found a missing piece; the line says which.",
                   fix: "Do what the line says, or click Install on the red line of the Setup.", severity: .warning)
    ]

    private static let compiled: [(KnownIssue, [NSRegularExpression])] = issues.map { issue in
        (issue, issue.patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) })
    }

    /// The known problems in `text`, most serious first, each once with the first line that shows it.
    static func scan(text: String, source: String) -> [Finding] {
        var found: [String: Finding] = [:]
        var order: [String] = []
        text.enumerateLines { line, _ in
            guard line.count < 4000, !line.contains("(retried)"), !line.contains("(harmless)") else { return }
            let range = NSRange(line.startIndex..., in: line)
            for (issue, regexes) in compiled where regexes.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                if found[issue.id] != nil {
                    found[issue.id]!.count += 1
                } else {
                    found[issue.id] = Finding(issue: issue, evidence: MCPServer.redact(String(line.prefix(300))), source: source)
                    order.append(issue.id)
                }
            }
        }
        return order.compactMap { found[$0] }.sorted { $0.issue.severity > $1.issue.severity }
    }

    /// Scans the end of each file (the last 6 MB, where a crash is).
    static func scan(files: [URL]) -> [Finding] {
        var merged: [String: Finding] = [:]
        for url in files {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 6_000_000 ? size - 6_000_000 : 0)
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            for finding in scan(text: text, source: url.lastPathComponent) where merged[finding.id] == nil {
                merged[finding.id] = finding
            }
        }
        return merged.values.sorted { ($0.issue.severity, $0.issue.id) > ($1.issue.severity, $1.issue.id) }
    }

    static func issue(_ id: String) -> KnownIssue? { issues.first { $0.id == id } }

    // MARK: - Before Play

    static var rosettaInstalled: Bool { fileExists("/Library/Apple/usr/libexec/oah/libRosettaRuntime") }

    /// Whether this copy of the app runs from a translocated (read-only, randomized) path, and still carries the
    /// download's quarantine: both make macOS refuse or kill the bundled xodus binaries.
    static var appLocation: (translocated: Bool, quarantined: Bool, path: String) {
        let path = Bundle.main.bundlePath
        let quarantined = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0
        return (path.contains("/AppTranslocation/"), quarantined, path)
    }

    static func nativeSteamRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "steam_osx"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    static func freeSpace(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path)
        while !fileExists(url.path), url.path != "/" { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    static func preflight(_ setup: Setup) -> [PreflightItem] {
        var items: [PreflightItem] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        items.append(PreflightItem(id: "macos", title: "macOS", check: os.majorVersion >= 27 ? Check(ok: true, text: osText)
            : Check(ok: false, text: osText, fix: "Forza Horizon 6 needs macOS 27: D3DMetal 4's DirectX 12 barriers are not in older versions.")))
        items.append(PreflightItem(id: "rosetta", title: "Rosetta", check: rosettaInstalled ? Check(ok: true, text: "installed")
            : Check(ok: false, text: "not installed", fix: "Run in Terminal: softwareupdate --install-rosetta --agree-to-license")))
        let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        items.append(PreflightItem(id: "memory", title: "Memory", check: memoryGB >= 16 ? Check(ok: true, text: "\(memoryGB) GB")
            : Check(ok: true, text: "\(memoryGB) GB", fix: memoryGB < 12
                ? "8 GB is very likely too little for Forza Horizon 6 under Rosetta: expect it to close or freeze. Quit every other app."
                : "Below 16 GB the game is likely to stutter: use low texture settings and quit other apps.")))
        let location = appLocation
        if location.translocated {
            items.append(PreflightItem(id: "app-location", title: "App location", check: Check(ok: false, text: "running from a temporary copy (App Translocation)",
                fix: "Quit MetalHorizon, move it to Applications, then open it from there: macOS blocks its helpers otherwise.")))
        } else if location.quarantined {
            items.append(PreflightItem(id: "app-location", title: "App location", check: Check(ok: true, text: location.path,
                fix: "The app still carries the download's quarantine. If xodus-service does not start, right-click MetalHorizon › Open once, or move it to Applications.")))
        }
        switch setup.edition {
        case .xbox:
            let game = setup.gameDirectory
            if !game.isEmpty {
                let link = game + "/forzahorizon6.exe"
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link), !fileExists(link) {
                    items.append(PreflightItem(id: "game-link", title: "Game files", check: Check(ok: false, text: "forzahorizon6.exe points to \(target), which is gone",
                        fix: "Choose the folder the game is really in, or move the game back.")))
                }
                if game.count > 60 {
                    items.append(PreflightItem(id: "game-path", title: "Game path", check: Check(ok: true, text: "\(game.count) characters",
                        fix: "Forza Horizon 6 refuses long installation paths: a short folder such as ~/FH6 is safest.")))
                }
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                if game.hasPrefix(home + "/Desktop") || game.hasPrefix(home + "/Documents") || game.hasPrefix(home + "/Library/Mobile Documents") {
                    items.append(PreflightItem(id: "icloud", title: "iCloud", check: Check(ok: true, text: "the game is in a folder iCloud may sync",
                        fix: "Desktop and Documents may sync to iCloud: loading gets slower. A folder like ~/FH6 is better.")))
                }
            }
            if let free = freeSpace(at: game.isEmpty ? NSHomeDirectory() : game) {
                let gb = Int(free / 1_000_000_000)
                let downloaded = setup.gameCheck.ok
                items.append(PreflightItem(id: "disk", title: "Free space", check: (downloaded ? gb >= 20 : gb >= 170)
                    ? Check(ok: true, text: "\(gb) GB") : Check(ok: true, text: "\(gb) GB", fix: downloaded
                        ? "Keep at least 20 GB free for the shader cache and saves." : "The download needs about 160 GB.")))
            }
        case .steam:
            if nativeSteamRunning() {
                items.append(PreflightItem(id: "native-steam", title: "Steam for macOS", check: Check(ok: true, text: "running",
                    fix: "Quit Steam for macOS: it holds the account's session and the Steam in MetalHorizon then shows NO CONNECTION.")))
            }
            if let free = freeSpace(at: setup.steamPrefixPath) {
                let gb = Int(free / 1_000_000_000)
                items.append(PreflightItem(id: "disk", title: "Free space", check: gb >= 20 ? Check(ok: true, text: "\(gb) GB")
                    : Check(ok: true, text: "\(gb) GB", fix: "Forza Horizon 6 needs about 160 GB in the Steam prefix's disk, plus 20 GB to play.")))
            }
        }
        return items
    }

    // MARK: - Report and bundle

    /// Everything a helper needs, no secrets: versions, setup, checks, recent sessions and their findings.
    static func report(_ setup: Setup) -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func row(_ name: String, _ check: Check) -> [String: Any] {
            var r: [String: Any] = ["item": name, "ok": check.ok, "detail": MCPServer.redact(check.text)]
            if let fix = check.fix { r["fix"] = fix }
            return r
        }
        var checks = [row("game", setup.gameCheck), row("engine", setup.engineCheck), row("d3dmetal", setup.d3dmetalCheck),
                      row("shim", setup.shimReady ? Check(ok: true, text: "assembled") : Check(ok: false, text: "not assembled"))]
        if setup.edition == .steam { checks.append(row("steam client", setup.steamClientCheck)) }
        return [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "edition": setup.edition.rawValue,
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "chip": sysctlValue("machdep.cpu.brand_string"),
            "model": sysctlValue("hw.model"),
            "memory_gb": Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            "rosetta": rosettaInstalled,
            "checks": checks,
            "preflight": preflight(setup).map { row($0.title, $0.check) },
            "components": Component.all().map { ["id": $0.id, "version": $0.version, "installed": $0.installedVersion ?? "no"] },
            "options": ["metal_hud": setup.metalHUD, "controllers": setup.controllerMode.rawValue, "metalfx": setup.metalFX,
                        "max_fps": setup.maxFPS, "auto_retry": setup.autoRetry, "engine_route": setup.engineRoute.rawValue,
                        "plain_sync": setup.plainSync],
            "engine": {
                let facts = MachineFacts.current
                let health = RouteHealth.load()
                let decision = setup.routeDecision(facts: facts, health: health)
                let native = NativeEngine.check(facts: facts)
                return ["next_play": decision.route.rawValue, "reason": decision.reason,
                        "native": ["ok": native.ok, "detail": native.text, "loader_linked": NativeEngine.linked],
                        "native_kept_aside": health.isBenched(.native), "native_failures_last_day": health.recentFailures(.native),
                        "d3dmetal_failures_last_day": health.recentFailures(.d3dmetal)] as [String: Any]
            }(),
            "recent_sessions": LogStore.sessions().prefix(8).map { s -> [String: Any] in
                ["id": s.id, "kind": s.kind, "exit_code": s.exitCode as Any? ?? NSNull(), "findings": s.findings]
            }
        ]
    }

    static func sysctlValue(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// A zip on the Desktop for a GitHub issue: report.json, the last sessions' logs and xodus-service.log, each
    /// with tokens, e-mail addresses, XUIDs and gamertags removed, and summaries of the latest crash reports.
    static func exportBundle(_ setup: Setup, to folder: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let stamp = LogStore.stampFormatter.string(from: Date())
        let staging = fm.temporaryDirectory.appendingPathComponent("MetalHorizon-diagnostics-\(stamp)")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let report = try JSONSerialization.data(withJSONObject: Self.report(setup), options: [.prettyPrinted, .sortedKeys])
        try report.write(to: staging.appendingPathComponent("report.json"))
        func copyRedacted(_ source: URL, as name: String) {
            guard let handle = try? FileHandle(forReadingFrom: source) else { return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 4_000_000 ? size - 4_000_000 : 0)
            let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
            let kept = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !LogFilter.isNoise($0) }
            try? MCPServer.redact(kept.joined(separator: "\n")).write(to: staging.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for session in LogStore.sessions().prefix(5) {
            for file in ["output.log", "game.log", "summary.json"] {
                copyRedacted(session.directory.appendingPathComponent(file), as: "\(session.id)-\(file)")
            }
        }
        for name in ["xodus-service.log", "steam-window.log", "steam-install.log", "steam-prefix.log", "updater.log",
                     "repairs.log", "repairs.json"] {
            copyRedacted(logDirectory.appendingPathComponent(name), as: name)
        }
        let crashes = MCPServer.recentCrashSummaries(limit: 3)
        if !crashes.isEmpty {
            try? MCPServer.redact(crashes.joined(separator: "\n\n----\n\n")).write(to: staging.appendingPathComponent("crash-reports.txt"),
                                                                                  atomically: true, encoding: .utf8)
        }
        let destination = (folder ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"))
            .appendingPathComponent("MetalHorizon-diagnostics-\(stamp).zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", staging.path, destination.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw InstallError.tool("Could not write \(destination.path)") }
        return destination
    }

    /// A new GitHub issue with the report's essentials filled in (the bundle itself is attached by the player).
    static func issueURL(_ setup: Setup, findings: [Finding]) -> URL {
        let report = Self.report(setup)
        let title = findings.first.map { "[\(setup.edition.rawValue)] \($0.issue.title)" } ?? "[\(setup.edition.rawValue)] "
        var body = """
            **What happens** (what you clicked, what you saw):


            **Setup** (filled in by MetalHorizon)
            - MetalHorizon \(report["app_version"] ?? "?"), \(setup.edition == .steam ? "Steam" : "Xbox / Microsoft Store") edition
            - macOS \(report["macos"] ?? "?"), \(report["chip"] ?? "?"), \(report["memory_gb"] ?? "?") GB
            - Components: \((report["components"] as? [[String: Any]] ?? []).map { "\($0["id"] ?? "?") \($0["installed"] ?? "?")" }.joined(separator: ", "))

            **What MetalHorizon recognized**

            """
        body += findings.isEmpty ? "- nothing known\n" : findings.prefix(6).map { "- \($0.issue.title): `\($0.evidence.prefix(160))`" }.joined(separator: "\n")
        body += "\n\nPlease attach the zip from Diagnosis › Export Diagnostics (logs with secrets removed)."
        var components = URLComponents(string: "https://github.com/alexandreunitypro/MetalHorizon-FH6-Mac-Launcher/issues/new")!
        components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: String(body.prefix(5000)))]
        return components.url!
    }
}
