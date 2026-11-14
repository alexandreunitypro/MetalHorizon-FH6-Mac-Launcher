import Foundation

// The Doctor: MetalHorizon's own problem solver, inside the app. It looks at everything it can read by itself (the
// last runs' logs and exit codes, the components on disk, the Xbox service, the network, the disk, the app's own
// location) against a catalogue of known problems, and treats each one it finds, cheapest treatment first:
//   - automatic: safe without asking (relink, reinstall a component, restart a service, change one of its own
//     settings, clear one of its own caches), done at once and written down;
//   - one click: something the player should approve because it moves their files, quits one of their apps or asks
//     for their password; shown with a button;
//   - explain: nothing to do from here; the window says what and how.
// Each treatment has an attempt budget, so a treatment that did not cure the problem is not tried in a loop: the next
// one is, and after the last one the problem is explained. It runs when the app opens, every quarter of an hour while
// idle, before every Play, after every run and after a failed sign-in, download or Steam step.
//
// What it never does: touch the player's saves, the game's files (moving the whole game folder in one rename on the
// same disk, with a click, is the one exception), the sign-in or the Keychain, or bypass anything of the game's.

/// When the Doctor looks.
enum DoctorMoment: String {
    case launch, idle, beforePlay, afterRun, afterAction
}

/// One run, as the Doctor reads it.
struct RunRecord {
    var kind: String
    var date: Date
    var exitCode: Int?
    var duration: Int
    var findings: Set<String>
    var route: String?
    var userStopped: Bool

    init(_ s: SessionInfo) {
        kind = s.kind
        date = s.date
        exitCode = s.exitCode
        duration = s.duration ?? 0
        findings = Set(s.findings)
        route = s.route
        userStopped = s.userStopped
    }
}

/// Everything the rules read, taken once per examination.
struct Patient {
    var setup: Setup
    var facts: MachineFacts
    var moment: DoctorMoment
    var runs: [RunRecord]                 // this edition's runs, newest first (Play runs and actions)
    var gameRunning: Bool
    var serviceRunning: Bool
    var serviceSocket: Bool
    var accountSaved: Bool
    var rosetta: Bool
    var freeBytes: Int64?
    var appTranslocated: Bool
    var appQuarantined: Bool
    var appPath: String
    var online: Bool?                     // nil when not checked
    var clockSkew: TimeInterval?          // seconds between this Mac and Microsoft's servers, when checked
    var steamNativeRunning: Bool
    /// The Xbox account, tried for real by `xodus-service --check` (nil when not tried): accepted, refused (with what
    /// Xbox or Microsoft answered), no sign-in saved, or waiting on macOS's Keychain window.
    var account: AccountCheck? = nil
    var now = Date()

    var plays: [RunRecord] { runs.filter { $0.kind == "play" || $0.kind == "steam-play" } }
    var lastPlay: RunRecord? { plays.first }
    /// How many of the last `last` Play runs show a finding.
    func playsWith(_ id: String, last: Int = 5) -> Int { plays.prefix(last).filter { $0.findings.contains(id) }.count }
    /// The newest run of any kind shows a finding (and it is recent).
    func latestHas(_ id: String, within: TimeInterval = 6 * 3600) -> Bool {
        guard let run = runs.first, now.timeIntervalSince(run.date) < within else { return false }
        return run.findings.contains(id)
    }
    var freeGB: Int? { freeBytes.map { Int($0 / 1_000_000_000) } }

    /// Lines matching a pattern in the newest run's two logs (0 without a recent run).
    func newestLogs(match pattern: String) -> Int {
        guard let newest = LogStore.sessions().first(where: { s in
            setup.edition == .steam ? s.kind.hasPrefix("steam") : !s.kind.hasPrefix("steam")
        }), now.timeIntervalSince(newest.date) < 6 * 3600 else { return 0 }
        return Sys.count(of: pattern, in: newest.directory.appendingPathComponent("output.log"))
            + Sys.count(of: pattern, in: newest.directory.appendingPathComponent("game.log"))
    }
}

/// The result of trying the Xbox sign-in without the game.
enum AccountCheck: Equatable {
    case accepted
    case refused(String)        // Xbox or Microsoft said no: the reason, no secret in it
    case unreachable(String)    // the network, not the account
    case noSignIn
    case keychainWaiting        // macOS is asking to let xodus-service read the sign-in

    /// Runs the bundled service's check (at most 40 s). Nothing of the account is printed or kept.
    static func run(resources: URL?) -> AccountCheck? {
        guard let service = resources?.appendingPathComponent("xodus-service"), fileExists(service.path) else { return nil }
        let (code, out, timedOut) = Sys.capture(service.path, ["--check"], timeout: 40)
        if timedOut { return Sys.pgrep("SecurityAgent") ? .keychainWaiting : .unreachable("the check did not answer in 40 s") }
        let line = out.split(separator: "\n").last { $0.hasPrefix("CHECK ") }.map(String.init) ?? ""
        switch code {
        case 0: return .accepted
        case 3: return .noSignIn
        case 2:
            let reason = String(line.dropFirst("CHECK failed: ".count))
            let network = ["error sending request", "dns error", "timed out", "connection", "lookup"].contains { reason.lowercased().contains($0) }
            return network ? .unreachable(reason) : .refused(reason)
        default:
            // an older service without --check, or one that stopped: no verdict
            return nil
        }
    }
}

/// What the app lets the Doctor do. The model provides these; tests provide fakes.
struct DoctorActions {
    var installComponent: (String) async throws -> Void = { _ in }
    var setMetalFX: (Bool) -> Void = { _ in }
    var setPlainSync: (Bool) -> Void = { _ in }
    var setMaxFPS: (Int) -> Void = { _ in }
    var setHUD: (Bool) -> Void = { _ in }
    var setControllerMode: (ControllerMode) -> Void = { _ in }
    var setGameDirectory: (String) -> Void = { _ in }
    var setEngineRoute: (EngineRoute) -> Void = { _ in }
    var signInAgain: () -> Void = {}
    var startDownload: () -> Void = {}
    var openURL: (URL) -> Void = { _ in }
    var relaunchApp: (String) -> Void = { _ in }
}

/// A treatment the player approves with a click.
struct PendingFix: Identifiable, Equatable {
    var id: String               // the ailment's id
    var title: String            // what is wrong, in a few words
    var detail: String           // what was seen and what the click does
    var button: String           // the button's label
    var action: () async -> String

    static func == (a: PendingFix, b: PendingFix) -> Bool { a.id == b.id && a.detail == b.detail }
}

enum Treatment {
    case automatic(title: String, run: () async throws -> String)
    case oneClick(button: String, detail: String, run: () async -> String)
    case explain
}

/// One problem the Doctor knows.
struct Ailment {
    var id: String
    var title: String
    var moments: Set<DoctorMoment>
    /// What shows the problem, or nil when it is not there.
    var detect: (Patient) -> String?
    /// The treatments, cheapest first.
    var treatments: (Patient, DoctorActions) -> [Treatment]
    var maxAttempts = 2
    var window: TimeInterval = 6 * 3600
}

/// What one examination found and did.
struct Examination {
    var repairs: [Repair] = []
    var pending: [PendingFix] = []
    var explained: [String] = []          // ailment ids seen with nothing left to do but explain
    var blocker: String?                  // before Play: why it should not start yet (the network is down)
}

/// The attempt budget, kept in doctor-state.json: for each ailment and treatment, when it was tried.
struct DoctorState: Codable {
    var attempts: [String: [Date]] = [:]

    static var file: URL { supportDirectory.appendingPathComponent("doctor-state.json") }
    static func load() -> DoctorState {
        guard let data = try? Data(contentsOf: file), let s = try? JSONDecoder.iso.decode(DoctorState.self, from: data) else { return DoctorState() }
        return s
    }
    func save() { if let data = try? JSONEncoder.iso.encode(self) { try? data.write(to: DoctorState.file, options: .atomic) } }

    func count(_ key: String, within window: TimeInterval, now: Date) -> Int {
        (attempts[key] ?? []).filter { now.timeIntervalSince($0) < window }.count
    }
    mutating func record(_ key: String, now: Date) { attempts[key] = ((attempts[key] ?? []) + [now]).suffix(10) }
}

enum Doctor {
    /// Examines the patient at a moment: applies the automatic treatments that are within budget, collects the
    /// one-click ones, and says what is only to be explained.
    static func examine(_ patient: Patient, actions: DoctorActions, catalogue: [Ailment] = Doctor.catalogue,
                        state: inout DoctorState) async -> Examination {
        var exam = Examination()
        for ailment in catalogue where ailment.moments.contains(patient.moment) {
            guard let seen = ailment.detect(patient) else { continue }
            var treated = false
            for (index, treatment) in ailment.treatments(patient, actions).enumerated() {
                let key = "\(ailment.id)#\(index)"
                switch treatment {
                case .automatic(let title, let run):
                    guard state.count(key, within: ailment.window, now: patient.now) < ailment.maxAttempts else { continue }
                    state.record(key, now: patient.now)
                    do {
                        let detail = try await run()
                        exam.repairs.append(Repair(title: title, detail: "\(seen) \(detail)", kind: .fixed))
                    } catch {
                        exam.repairs.append(Repair(title: "Tried: \(title.lowercased())", detail: "\(seen) It did not work: \(error).", kind: .note))
                    }
                    treated = true
                case .oneClick(let button, let detail, let run):
                    exam.pending.append(PendingFix(id: ailment.id, title: ailment.title, detail: "\(seen) \(detail)", button: button, action: run))
                    treated = true
                case .explain:
                    exam.explained.append(ailment.id)
                    treated = true
                }
                if treated { break }
            }
            if !treated { exam.explained.append(ailment.id) }
        }
        return exam
    }

    // MARK: - The catalogue

    static var catalogue: [Ailment] { components + app + xbox + gameFiles + runtime + steam + disk }

    private static let any: Set<DoctorMoment> = [.launch, .idle, .beforePlay, .afterRun, .afterAction]
    private static let setupMoments: Set<DoctorMoment> = [.launch, .idle, .beforePlay]

    // MARK: Components

    static var components: [Ailment] {[
        Ailment(id: "engine-files-missing", title: "Blackwell Engine is damaged", moments: setupMoments,
                detect: { p in
                    let id = p.setup.edition == .steam ? "engine-steam" : "engine"
                    guard p.setup.engineDirectory.isEmpty, let c = Component.named(id), c.isInstalled,
                          !fileExists(p.setup.engine + "/bin/wine") || !fileExists(p.setup.engine + "/lib/wine/x86_64-unix/ntdll.so")
                    else { return nil }
                    return "Its files are missing although it was installed (something deleted part of it)."
                },
                treatments: { p, a in [.automatic(title: "Blackwell Engine reinstalled") {
                    let id = p.setup.edition == .steam ? "engine-steam" : "engine"
                    Component.named(id)?.forget()
                    try await a.installComponent(id)
                    return "It was installed again from its release (or the copy already on this Mac)."
                }] }),
        Ailment(id: "d3dmetal-files-missing", title: "D3DMetal is damaged", moments: setupMoments,
                detect: { p in
                    guard p.setup.d3dmetalDirectory.isEmpty, let c = Component.named("d3dmetal"), c.isInstalled,
                          !fileExists(p.setup.d3dmetal + "/external/libd3dshared.dylib") else { return nil }
                    return "Apple's D3DMetal is marked installed but its library is gone."
                },
                treatments: { _, a in [.automatic(title: "D3DMetal reinstalled") {
                    Component.named("d3dmetal")?.forget()
                    try await a.installComponent("d3dmetal")
                    return "Installed again (Apple's licence is asked again)."
                }] }),
        Ailment(id: "shim-missing", title: "The DirectX 12 shim is missing", moments: setupMoments,
                detect: { p in
                    p.setup.engineCheck.ok && p.setup.d3dmetalCheck.ok && !p.setup.shimReady ? "The shim in front of D3DMetal is not assembled." : nil
                },
                treatments: { p, _ in [.automatic(title: "DirectX 12 shim assembled") {
                    try Installer.prepareShim(engine: p.setup.engine, d3dmetal: p.setup.d3dmetal)
                    return "Put together from the engine's shim and Apple's d3d12."
                }] }),
        Ailment(id: "native-unlinked", title: "The native engine's loader link is broken", moments: setupMoments,
                detect: { _ in
                    NativeEngine.filesPresent && NativeEngine.loaderPresent && !NativeEngine.linked
                        ? "The engine's wine does not point at the signed loader (the app or the loader moved)." : nil
                },
                treatments: { _, _ in [.automatic(title: "Native engine's loader linked again") {
                    try NativeEngine.linkLoader(); return "It points at Highball's signed loader again."
                }] }),
        Ailment(id: "native-loader-invalid", title: "The native engine's signed loader is not valid", moments: [.launch, .beforePlay],
                detect: { _ in
                    NativeEngine.loaderPresent && !NativeEngine.loaderSignatureValid()
                        ? "WineLoader.app is there but its signature is not Highball's (damaged or replaced)." : nil
                },
                treatments: { _, a in [.automatic(title: "Signed loader reinstalled") {
                    Component.named("wineloader")?.forget()
                    try? FileManager.default.removeItem(atPath: wineLoaderAppDirectory)
                    try await a.installComponent("wineloader")
                    return "Taken again from Highball's release and checked."
                }] }),
        Ailment(id: "native-files-missing", title: "The native engine is damaged", moments: setupMoments,
                detect: { _ in
                    guard let c = Component.named("engine-native"), c.isInstalled, !NativeEngine.filesPresent else { return nil }
                    return "Blackwell Engine Native is marked installed but some of its files are gone."
                },
                treatments: { _, a in [.automatic(title: "Native engine reinstalled") {
                    Component.named("engine-native")?.forget()
                    try await a.installComponent("engine-native")
                    return "Installed again and linked to the signed loader."
                }] }),
        Ailment(id: "components-quarantined", title: "Components carry the download quarantine", moments: [.launch],
                detect: { _ in
                    let dirs = [installedEngineDirectory, installedSteamEngineDirectory, installedD3DMetalDirectory, installedNativeDirectory]
                    let hit = dirs.filter { fileExists($0) && Sys.isQuarantined($0) }
                    return hit.isEmpty ? nil : "macOS's quarantine is on \(hit.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")): their programs could be stopped."
                },
                treatments: { _, _ in [.automatic(title: "Quarantine removed from the components") {
                    for d in [installedEngineDirectory, installedSteamEngineDirectory, installedD3DMetalDirectory, installedNativeDirectory] where fileExists(d) {
                        Sys.removeQuarantine(d)
                    }
                    return "They were checked against their SHA-256 when installed."
                }] }),
        Ailment(id: "engine-not-executable", title: "The engine's programs lost their permission to run", moments: setupMoments,
                detect: { p in
                    let bins = [p.setup.engine + "/bin/wine", p.setup.engine + "/bin/wineserver"].filter(fileExists)
                    let bad = bins.filter { !FileManager.default.isExecutableFile(atPath: $0) }
                    return bad.isEmpty ? nil : "\(bad.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")) cannot be run (a copy dropped their permissions)."
                },
                treatments: { p, _ in [.automatic(title: "Permissions restored") {
                    for f in [p.setup.engine + "/bin/wine", p.setup.engine + "/bin/wineserver"] where fileExists(f) {
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f)
                    }
                    return "wine and wineserver can run again."
                }] }),
    ]}

    // MARK: The app itself

    static var app: [Ailment] {[
        Ailment(id: "app-translocated", title: "MetalHorizon runs from a temporary copy", moments: [.launch],
                detect: { p in p.appTranslocated ? "macOS runs it from a hidden temporary copy (App Translocation): its helpers can be blocked and updates cannot land." : nil },
                treatments: { p, a in [.oneClick(button: "Move to Applications",
                                                 detail: "One click moves MetalHorizon to the Applications folder and opens it from there.") {
                    a.relaunchApp(p.appPath); return "Moving to Applications…"
                }] }),
        Ailment(id: "app-quarantined", title: "MetalHorizon still carries the download quarantine", moments: [.launch],
                detect: { p in p.appQuarantined && !p.appTranslocated ? "The app's helpers (xodus) may be stopped by macOS." : nil },
                treatments: { p, _ in [.automatic(title: "Quarantine removed from MetalHorizon") {
                    Sys.removeQuarantine(p.appPath); return "You opened it already, so macOS no longer needs to ask."
                }] }),
        Ailment(id: "app-damaged", title: "MetalHorizon's own helpers are missing", moments: [.launch],
                detect: { _ in
                    guard let r = Bundle.main.resourceURL, Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
                    let missing = ["xodus-cli", "xodus-service", "metalhorizon-play.sh", "metalhorizon-common.sh", "components.json"]
                        .filter { !fileExists(r.appendingPathComponent($0).path) }
                    return missing.isEmpty ? nil : "\(missing.joined(separator: ", ")) are not in the app (a damaged copy)."
                },
                treatments: { _, a in [.oneClick(button: "Download MetalHorizon Again",
                                                 detail: "Opens the releases page; your settings, sign-in, engines and game stay.") {
                    a.openURL(issuesURL.deletingLastPathComponent().appendingPathComponent("releases")); return "The releases page is open."
                }] }),
        Ailment(id: "small-memory-defaults", title: "Settings for a Mac with little memory", moments: [.launch],
                detect: { p in
                    p.facts.memoryGB <= 16 && p.setup.maxFPS == 0 ? "This Mac has \(p.facts.memoryGB) GB: the game holds better with a frame cap." : nil
                },
                treatments: { _, a in [.automatic(title: "Frame cap set to 30") {
                    a.setMaxFPS(30); return "Once, for this Mac; Settings › Graphics changes it."
                }] }, maxAttempts: 1, window: 3650 * 86_400),
        Ailment(id: "rosetta-missing", title: "Rosetta is not installed", moments: setupMoments,
                detect: { p in
                    guard !p.rosetta else { return nil }
                    let route = p.setup.routeDecision(facts: p.facts)
                    return route.route == .d3dmetal || p.setup.edition == .steam
                        ? "D3DMetal's engine runs under Rosetta, which this Mac does not have yet." : nil
                },
                treatments: { p, a in
                    var list: [Treatment] = []
                    if p.setup.edition == .xbox && p.facts.nativeSupported && p.setup.engineRoute != .native {
                        list.append(.automatic(title: "The native engine runs the game") {
                            a.setEngineRoute(.native)
                            return "It needs no Rosetta. Settings › Graphics › Engine goes back to Automatic once Rosetta is installed."
                        })
                    }
                    list.append(.oneClick(button: "Install Rosetta",
                                          detail: "Apple's Rosetta installs with your Mac password (macOS asks for it, not MetalHorizon).") {
                        Sys.installRosetta()
                    })
                    return list
                }),
    ]}

    // MARK: Xbox account, licence and service

    static var xbox: [Ailment] {[
        Ailment(id: "xbox-account-refused", title: "Xbox does not accept the saved sign-in", moments: [.beforePlay, .afterAction],
                detect: { p in
                    guard case .refused(let why)? = p.account else { return nil }
                    return "MetalHorizon tried the account before starting the game: \(why)."
                },
                treatments: { _, a in [.oneClick(button: "Sign In Again",
                                                 detail: "A new sign-in on Microsoft's page gives Xbox a fresh ticket; the game is not started until the account is accepted.") {
                    a.signInAgain(); return "Microsoft's sign-in is opening."
                }] }),
        Ailment(id: "xbox-no-sign-in", title: "No Microsoft sign-in is saved", moments: [.beforePlay, .afterAction],
                detect: { p in p.account == .noSignIn ? "The Keychain holds no sign-in for xodus (it was removed, or never finished)." : nil },
                treatments: { _, a in [.oneClick(button: "Sign In", detail: "On Microsoft's own page.") {
                    a.signInAgain(); return "Microsoft's sign-in is opening."
                }] }),
        Ailment(id: "xodus-service-stale", title: "The Xbox service is stuck", moments: [.launch, .idle, .beforePlay],
                detect: { p in
                    p.setup.edition == .xbox && p.serviceRunning && !p.serviceSocket && !p.gameRunning
                        ? "xodus-service runs without its socket: the game could not reach the Xbox account." : nil
                },
                treatments: { _, _ in [.automatic(title: "Xbox service restarted") {
                    Sys.run("/usr/bin/pkill", ["-f", "xodus-service"]); return "A fresh one starts with Play."
                }] }),
        Ailment(id: "xodus-service-crashing", title: "The Xbox service keeps failing", moments: [.afterRun, .beforePlay],
                detect: { p in
                    guard p.setup.edition == .xbox, !p.gameRunning else { return nil }
                    let panics = Sys.count(of: "panicked", in: logDirectory.appendingPathComponent("xodus-service.log"))
                    return panics >= 8 ? "xodus-service logged \(panics) failures since it started." : nil
                },
                treatments: { _, _ in [.automatic(title: "Xbox service restarted") {
                    Sys.run("/usr/bin/pkill", ["-f", "xodus-service"]); return "Its next start reads the sign-in again."
                }] }),
        Ailment(id: "licence-timeout", title: "The Xbox licence request did not answer", moments: [.afterRun],
                detect: { p in p.latestHas("xodus-licence-timeout") ? "The last Play waited 3 minutes for Microsoft's licence servers." : nil },
                treatments: { _, _ in [.automatic(title: "Xbox service restarted") {
                    Sys.run("/usr/bin/pkill", ["-f", "xodus-service"]); return "The next Play starts a fresh one."
                }] }),
        Ailment(id: "licence-not-entitled", title: "Microsoft gave no licence for this account", moments: [.afterRun, .afterAction, .launch],
                detect: { p in p.latestHas("licence-not-entitled", within: 24 * 3600)
                    ? (p.setup.ownership == .gamePass
                       ? "The Game Pass plan on this account does not cover Forza Horizon 6 on PC right now (PC Game Pass or Ultimate does), or it ended."
                       : "This account does not own Forza Horizon 6 on the Microsoft Store.")
                    : nil },
                treatments: { p, a in
                    [.oneClick(button: p.setup.ownership == .gamePass ? "Open My Subscriptions" : "Open My Microsoft Account",
                               detail: "Opens Microsoft's page for this account; MetalHorizon asks for the licence again at the next Play.") {
                        a.openURL(URL(string: "https://account.microsoft.com/services")!); return "Microsoft's page is open."
                    }]
                }),
        Ailment(id: "keychain-denied", title: "macOS refused the Xbox sign-in to xodus", moments: [.afterRun, .afterAction],
                detect: { p in p.latestHas("keychain-denied") ? "The Keychain did not let xodus read the sign-in (Deny was chosen, or the Keychain is locked)." : nil },
                treatments: { _, a in [.oneClick(button: "Sign In Again",
                                                 detail: "A new sign-in stores it again; choose Always Allow if macOS asks.") {
                    a.signInAgain(); return "Microsoft's sign-in is opening."
                }] }),
        Ailment(id: "keychain-locked", title: "The login Keychain is locked", moments: [.afterRun, .afterAction],
                detect: { p in
                    p.newestLogs(match: "User interaction is not allowed|errSecInteractionNotAllowed|-25308") > 0
                        ? "xodus could not read the sign-in: the login Keychain is locked." : nil
                },
                treatments: { _, a in [.oneClick(button: "Open Keychain Access",
                                                 detail: "Unlock the login keychain with your Mac password, then press Play.") {
                    a.openURL(URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app")); return "Keychain Access is open."
                }] }),
        Ailment(id: "dns-failure", title: "Microsoft's servers could not be found", moments: [.afterRun, .afterAction],
                detect: { p in
                    p.newestLogs(match: "dns error|failed to lookup address|nodename nor servname|Could not resolve host") > 0
                        ? "The network did not resolve Microsoft's server names (DNS)." : nil
                },
                treatments: { _, a in [.oneClick(button: "Open Network Settings",
                                                 detail: "Check the connection or the DNS servers (a VPN or a filtering DNS can block Xbox's servers).") {
                    a.openURL(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!); return "System Settings is open."
                }] }),
        Ailment(id: "offline", title: "This Mac is offline", moments: [.beforePlay],
                detect: { p in
                    guard p.setup.edition == .xbox, p.online == false else { return nil }
                    return p.setup.ownership == .gamePass
                        ? "Game Pass gives the game a licence at every start, and Microsoft's licence server cannot be reached."
                        : "The game's licence is checked at every start, and Microsoft's licence server cannot be reached."
                },
                treatments: { _, _ in [.explain] }),
        Ailment(id: "clock-skew", title: "This Mac's clock is wrong", moments: [.beforePlay, .afterAction],
                detect: { p in
                    guard let skew = p.clockSkew, abs(skew) > 300 else { return nil }
                    return "It is \(Int(abs(skew) / 60)) minutes \(skew > 0 ? "ahead of" : "behind") Microsoft's servers: sign-in and licences fail with a wrong clock."
                },
                treatments: { _, a in [.oneClick(button: "Open Date & Time",
                                                 detail: "Turn on Set time and date automatically in System Settings.") {
                    a.openURL(URL(string: "x-apple.systempreferences:com.apple.Date-Time-Settings.extension")!); return "System Settings is open."
                }] }),
    ]}

    // MARK: The game's files

    static var gameFiles: [Ailment] {[
        Ailment(id: "game-folder-moved", title: "The game is not where MetalHorizon looks", moments: setupMoments,
                detect: { p in
                    guard p.setup.edition == .xbox, !p.setup.xboxGameCheck.ok,
                          !fileExists(p.setup.gameDirectory + "/forzahorizon6.exe") || (try? FileManager.default.destinationOfSymbolicLink(atPath: p.setup.gameDirectory + "/forzahorizon6.exe")) != nil,
                          let found = Setup.detectXboxGame(), found != p.setup.gameDirectory else { return nil }
                    return "The game folder set (\(Setup.tildePath(p.setup.gameDirectory))) has no game, but a complete copy is in \(Setup.tildePath(found))."
                },
                treatments: { _, a in [.automatic(title: "Game folder found") {
                    guard let found = Setup.detectXboxGame() else { return "It was gone again." }
                    a.setGameDirectory(found); return "MetalHorizon now uses \(Setup.tildePath(found))."
                }] }),
        Ailment(id: "package-missing", title: "The game's package is missing", moments: setupMoments,
                detect: { p in
                    guard p.setup.edition == .xbox, fileExists(p.setup.gameDirectory + "/forzahorizon6.exe"),
                          !fileExists(p.setup.gameDirectory + "/.xodus-streaming.msixvc"),
                          Setup.findXboxPackage(besides: p.setup.gameDirectory) != nil else { return nil }
                    return "The hidden package .xodus-streaming.msixvc was left behind when the game files moved."
                },
                treatments: { p, _ in [.automatic(title: "Game package put back") {
                    Setup.repairXboxPackage(in: p.setup.gameDirectory) ?? "Nothing was moved."
                }] }),
        Ailment(id: "download-interrupted", title: "The game's download was interrupted", moments: [.launch, .afterAction],
                detect: { p in
                    guard p.setup.edition == .xbox, p.accountSaved, !fileExists(p.setup.gameDirectory + "/forzahorizon6.exe"),
                          fileExists(p.setup.gameDirectory + "/.xodus-streaming-tmp.msixvc") else { return nil }
                    return "A partial download is in \(Setup.tildePath(p.setup.gameDirectory))."
                },
                treatments: { _, a in [.oneClick(button: "Resume the Download", detail: "It goes on from where it stopped.") {
                    a.startDownload(); return "Download resumed."
                }] }),
        Ailment(id: "game-path-long", title: "The game's path is long", moments: [.launch],
                detect: { p in
                    guard p.setup.edition == .xbox, p.setup.gameCheck.ok, !p.gameRunning, p.setup.gameDirectory.count > 60,
                          !Sys.syncedFolder(p.setup.gameDirectory), Sys.canRename(p.setup.gameDirectory, to: Sys.home + "/FH6") else { return nil }
                    return "\(p.setup.gameDirectory.count) characters: Forza Horizon 6 refuses long installation paths."
                },
                treatments: { p, a in [.oneClick(button: "Move to ~/FH6", detail: "One rename on the same disk, nothing is copied.") {
                    do {
                        try FileManager.default.moveItem(atPath: p.setup.gameDirectory, toPath: Sys.home + "/FH6")
                        a.setGameDirectory(Sys.home + "/FH6"); return "The game is now in ~/FH6."
                    } catch { return "It could not be moved: \(error)." }
                }] }),
        Ailment(id: "game-in-icloud-folder", title: "The game is in a folder iCloud syncs", moments: [.launch],
                detect: { p in
                    guard p.setup.edition == .xbox, p.setup.gameCheck.ok, !p.gameRunning, Sys.syncedFolder(p.setup.gameDirectory),
                          Sys.canRename(p.setup.gameDirectory, to: Sys.home + "/FH6") else { return nil }
                    return "\(Setup.tildePath(p.setup.gameDirectory)) is under Desktop or Documents, which iCloud can sync: loading is slower and files can be evicted."
                },
                treatments: { p, a in [.oneClick(button: "Move to ~/FH6",
                                                 detail: "One rename on the same disk (instant, nothing is copied); the prefix and the saves move with it.") {
                    do {
                        try FileManager.default.moveItem(atPath: p.setup.gameDirectory, toPath: Sys.home + "/FH6")
                        a.setGameDirectory(Sys.home + "/FH6")
                        RepairLog.record(Repair(title: "Game moved to ~/FH6", detail: "From \(Setup.tildePath(p.setup.gameDirectory)), by one rename.", kind: .fixed))
                        return "The game is now in ~/FH6."
                    } catch { return "It could not be moved: \(error)." }
                }] }),
    ]}

    // MARK: Runs

    static var runtime: [Ailment] {[
        Ailment(id: "ane-repeated", title: "D3DMetal's Neural Engine failure keeps coming back", moments: [.afterRun],
                detect: { p in
                    guard p.setup.edition == .xbox, p.setup.engineRoute == .automatic, p.facts.nativeSupported,
                          p.playsWith("ane-init") >= 3 else { return nil }
                    return "D3DMetal stopped at start-up on the Neural Engine in \(p.playsWith("ane-init")) of the last runs."
                },
                treatments: { _, _ in [.automatic(title: "The native engine takes over") {
                    var h = RouteHealth.load()
                    h.bench(.d3dmetal, for: 3 * 86_400, reason: "D3DMetal kept failing on the Neural Engine at start-up; the native engine, which does not use it, runs the game.")
                    h.clearBench(.native); h.save()
                    return "The native engine does not use D3DMetal's Neural Engine model."
                }] }),
        Ailment(id: "gpu-refused-repeated", title: "The game keeps refusing D3DMetal's graphics card", moments: [.afterRun],
                detect: { p in
                    guard p.setup.edition == .xbox, p.facts.nativeSupported, p.setup.engineRoute == .automatic,
                          p.playsWith("fh205") + p.playsWith("fhe21") >= 2 else { return nil }
                    return "FH205 / FHE21 came back after the shim was rebuilt."
                },
                treatments: { _, _ in [.automatic(title: "The native engine takes over") {
                    var h = RouteHealth.load()
                    h.bench(.d3dmetal, for: 3 * 86_400, reason: "The game kept refusing D3DMetal's card (FH205/FHE21); the native engine presents another GPU.")
                    h.clearBench(.native); h.save()
                    return "The native engine reports an Intel Arc through DXVK, which the game accepts."
                }] }),
        Ailment(id: "out-of-memory", title: "macOS stopped the game for memory", moments: [.afterRun],
                detect: { p in
                    guard let last = p.lastPlay, !last.userStopped,
                          last.findings.contains("killed-9") || last.exitCode == 137 || last.exitCode == 9 else { return nil }
                    return "The game was killed (signal 9), what macOS does when memory runs out."
                },
                treatments: { p, a in
                    var list: [Treatment] = []
                    if p.setup.maxFPS == 0 || p.setup.maxFPS > 30 {
                        list.append(.automatic(title: "Frame cap set to 30") {
                            a.setMaxFPS(30); a.setHUD(false)
                            return "Less work per second and no HUD; quit other apps before playing (Settings › Graphics changes it back)."
                        })
                    }
                    list.append(.explain)
                    return list
                }),
        Ailment(id: "native-device-lost", title: "The graphics device was lost", moments: [.afterRun],
                detect: { p in p.lastPlay?.findings.contains("native-device-lost") == true ? "vkd3d-proton lost its Vulkan device during the last run." : nil },
                treatments: { p, _ in [.automatic(title: "Shader caches cleared") {
                    Sys.trashContents(of: p.setup.nativePrefix + "/drive_c/metalhorizon/cache/vkd3d")
                    Sys.trashContents(of: p.setup.nativePrefix + "/.mesa-cache")
                    return "A damaged cache is a common cause; they fill again on the next start."
                }] }),
        Ailment(id: "shader-cache-errors", title: "The pipeline cache could not be read", moments: [.afterRun],
                detect: { p in
                    guard p.lastPlay?.route == "native",
                          Sys.count(of: "Failed to load pipeline|corrupt.*cache|cache.*corrupt", in: LogStore.sessions().first(where: { $0.kind == "play" })?.directory.appendingPathComponent("game.log")) > 0
                    else { return nil }
                    return "vkd3d-proton found its pipeline cache unreadable."
                },
                treatments: { p, _ in [.automatic(title: "Pipeline cache rebuilt") {
                    Sys.trashContents(of: p.setup.nativePrefix + "/drive_c/metalhorizon/cache/vkd3d")
                    return "It fills again on the next start."
                }] }),
        Ailment(id: "controllers-crash", title: "The game stopped in the controllers' code", moments: [.afterRun],
                detect: { p in
                    guard let last = p.lastPlay, !last.userStopped, last.exitCode != 0,
                          Sys.count(of: "gameinput\\.dll|GameInput.*(fault|exception)", in: LogStore.sessions().first(where: { $0.kind == "play" })?.directory.appendingPathComponent("game.log")) > 0
                    else { return nil }
                    return "The crash points at GameInput, the controllers' layer."
                },
                treatments: { _, a in [.oneClick(button: "Turn GameInput Off",
                                                 detail: "The game then gets the keyboard and the mouse only; Settings › Controllers turns it back on.") {
                    a.setControllerMode(.off); return "GameInput is off for the next run."
                }] }),
        Ailment(id: "wineserver-mismatch", title: "An old Wine server holds the prefix", moments: [.afterRun, .beforePlay],
                detect: { p in
                    !p.gameRunning && p.newestLogs(match: "version mismatch|wineserver binary was not upgraded") > 0
                        ? "A wineserver from another engine version was still running for the prefix." : nil
                },
                treatments: { _, _ in [.automatic(title: "Old Wine servers stopped") {
                    Sys.run("/usr/bin/pkill", ["-x", "wineserver"]); return "The next Play starts the engine's own."
                }] }),
        Ailment(id: "prefix-damaged", title: "The Wine prefix is damaged", moments: [.afterRun],
                detect: { p in
                    guard let last = p.lastPlay, last.exitCode != 0,
                          Sys.count(of: "could not load kernel32|failed to initialize|c0000135|wineboot failed", in: LogStore.sessions().first(where: { $0.kind == "play" })?.directory.appendingPathComponent("game.log")) > 0
                    else { return nil }
                    return "Wine could not start its own programs in the game's prefix."
                },
                treatments: { p, _ in [.automatic(title: "Wine prefix updated") {
                    let native = p.lastPlay?.route == "native"
                    let engine = native ? NativeEngine.engine : p.setup.engine
                    let prefix = native ? p.setup.nativePrefix : p.setup.prefix
                    var env = ["WINEPREFIX": prefix, "WINEDEBUG": "-all"]
                    if native { env["DYLD_FALLBACK_LIBRARY_PATH"] = NativeEngine.directory + "/frameworks" }
                    else { env["DYLD_LIBRARY_PATH"] = engine + "/lib"; env["CX_ROOT"] = engine }
                    Sys.run(engine + "/bin/wine", ["wineboot", "-u"], env: env, timeout: 180)
                    return "wineboot -u rebuilt the prefix's system files; the saves were not touched."
                }] }),
    ]}

    // MARK: Steam

    static var steam: [Ailment] {[
        Ailment(id: "steam-webhelper-hung", title: "Steam's window stopped answering", moments: [.afterAction, .afterRun],
                detect: { p in p.setup.edition == .steam && p.latestHas("steam-unresponsive") && !p.gameRunning ? "steamwebhelper hung." : nil },
                treatments: { p, _ in [.automatic(title: "Steam stopped") {
                    guard let script = Bundle.main.resourceURL?.appendingPathComponent("metalhorizon-steam.sh") else { return "" }
                    Sys.run("/bin/bash", [script.path, "stop"], env: p.setup.steamEnvironment(), timeout: 60)
                    return "Open Steam starts a fresh one."
                }] }),
        Ailment(id: "steam-32bit-missing", title: "The Steam engine has no 32-bit half", moments: setupMoments,
                detect: { p in
                    p.setup.edition == .steam && fileExists(p.setup.engine + "/bin/wine") && !fileExists(p.setup.engine + "/lib/wine/i386-windows/ntdll.dll")
                        ? "Steam is a 32-bit program and this engine cannot run it." : nil
                },
                treatments: { _, a in [.automatic(title: "Blackwell Engine Steam reinstalled") {
                    Component.named("engine-steam")?.forget()
                    try await a.installComponent("engine-steam")
                    return "The 1.1 Steam engine carries the 32-bit half."
                }] }),
        Ailment(id: "steam-signin-needed", title: "Steam is not signed in yet", moments: [.beforePlay],
                detect: { p in
                    p.setup.edition == .steam && p.setup.steam.installed && !p.setup.steam.signedInOnce ? "Steam has never been signed in here." : nil
                },
                treatments: { _, _ in [.explain] }),
        Ailment(id: "steam-game-downloading", title: "Steam is still downloading the game", moments: [.beforePlay, .idle],
                detect: { p in
                    p.setup.edition == .steam && p.setup.steam.manifest != nil && !p.setup.steamGameCheck.ok ? "Forza Horizon 6 is not fully installed in Steam yet." : nil
                },
                treatments: { _, _ in [.explain] }),
        Ailment(id: "steam-native-running", title: "Steam for macOS is running", moments: [.beforePlay, .launch],
                detect: { p in p.setup.edition == .steam && p.steamNativeRunning ? "It holds the account's session: MetalHorizon's Steam then shows NO CONNECTION." : nil },
                treatments: { _, _ in [.oneClick(button: "Quit Steam for macOS", detail: "Your Steam for macOS games are not affected.") {
                    Sys.quitApp(bundleID: "com.valvesoftware.steam"); return "Steam for macOS is quitting."
                }] }),
    ]}

    // MARK: Disk

    static var disk: [Ailment] {[
        Ailment(id: "disk-low", title: "The disk is almost full", moments: [.launch, .beforePlay, .afterRun],
                detect: { p in
                    guard let gb = p.freeGB, gb < 15 else { return nil }
                    return "\(gb) GB free where the game is."
                },
                treatments: { p, _ in [.automatic(title: "MetalHorizon's own leftovers cleared") {
                    let freed = Sys.cleanOwnLeftovers(keepSessions: 10, nativePrefix: p.setup.nativePrefix)
                    return "\(freed / 1_000_000) MB of old downloads, logs and shader caches went to the Trash. The game needs about 20 GB free to play."
                }, .explain] }),
    ]}
}

// MARK: - System helpers

enum Sys {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 30) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        if !env.isEmpty { task.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new } }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if task.isRunning { task.terminate() }
        return task.terminationStatus
    }

    /// As `run`, keeping what the program printed; `timedOut` when it was stopped at the deadline.
    static func capture(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String, timedOut: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return (-1, "", false) }
        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        let timedOut = task.isRunning
        if timedOut { task.terminate() }
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self), timedOut)
    }

    static func pgrep(_ pattern: String) -> Bool { run("/usr/bin/pgrep", ["-f", pattern]) == 0 }

    static func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    static func removeQuarantine(_ path: String) { run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", path], timeout: 60) }

    /// Lines of a file matching an extended regular expression (case-insensitive), 0 when there is no file.
    static func count(of pattern: String, in url: URL?) -> Int {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 8_000_000 ? size - 8_000_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// Under Desktop or Documents (iCloud's "Desktop & Documents Folders") or iCloud Drive itself.
    static func syncedFolder(_ path: String) -> Bool {
        [home + "/Desktop", home + "/Documents", home + "/Library/Mobile Documents"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// A rename (same volume, free target, not a link) would move the folder.
    static func canRename(_ from: String, to: String) -> Bool {
        guard fileExists(from), !fileExists(to),
              let a = try? URL(fileURLWithPath: from).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
              let b = try? URL(fileURLWithPath: (to as NSString).deletingLastPathComponent).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        else { return false }
        return a.isEqual(b)
    }

    /// Moves a folder's contents to the Trash (caches MetalHorizon's engines made; they rebuild themselves).
    static func trashContents(of path: String) {
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(atPath: path)) ?? [] {
            let url = URL(fileURLWithPath: path).appendingPathComponent(item)
            if (try? fm.trashItem(at: url, resultingItemURL: nil)) == nil { try? fm.removeItem(at: url) }
        }
    }

    /// Superseded downloads, old sessions and oversized shader caches, all MetalHorizon's own: to the Trash. Returns
    /// the bytes freed.
    static func cleanOwnLeftovers(keepSessions: Int, nativePrefix: String) -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        func size(_ url: URL) -> Int64 {
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
                return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            var total: Int64 = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return total
        }
        func trash(_ url: URL) {
            let s = size(url)
            if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil || (try? fm.removeItem(at: url)) != nil { freed += s }
        }
        // downloads no pinned component uses any more
        let wanted = Set(Component.all().compactMap { URL(string: $0.url)?.lastPathComponent })
        for file in (try? fm.contentsOfDirectory(at: downloadCache, includingPropertiesForKeys: nil)) ?? [] where !wanted.contains(file.lastPathComponent) {
            trash(file)
        }
        for session in LogStore.sessions().dropFirst(keepSessions) { trash(session.directory) }
        let mesa = URL(fileURLWithPath: nativePrefix + "/.mesa-cache")
        if fileExists(mesa.path), size(mesa) > 3_000_000_000 { trash(mesa) }
        return freed
    }

    static func installRosetta() -> String {
        let script = "do shell script \"/usr/sbin/softwareupdate --install-rosetta --agree-to-license\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script], timeout: 900) == 0 ? "Rosetta is installed." : "Rosetta was not installed (cancelled, or no network)."
    }

    static func quitApp(bundleID: String) {
        run("/usr/bin/osascript", ["-e", "tell application id \"\(bundleID)\" to quit"], timeout: 30)
    }

    /// Microsoft's licence server answers (any HTTP status counts) and the clock offset from its Date header.
    static func reachMicrosoft(timeout: TimeInterval = 5) -> (online: Bool, skew: TimeInterval?) {
        var request = URLRequest(url: URL(string: "https://licensing.mp.microsoft.com/")!, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Bool, TimeInterval?) = (false, nil)
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                var skew: TimeInterval?
                if let date = http.value(forHTTPHeaderField: "Date") {
                    let f = DateFormatter()
                    f.locale = Locale(identifier: "en_US_POSIX")
                    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let server = f.date(from: date) { skew = Date().timeIntervalSince(server) }
                }
                result = (true, skew)
            } else {
                result = (error == nil, nil)
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout + 1)
        return result
    }
}

extension Component {
    /// Drops the install record, so the next install puts the component back even though its version matches.
    func forget() {
        let markers = [destination + "/.metalhorizon-component.json",
                       supportDirectory.appendingPathComponent(".\(folder).metalhorizon-component.json").path]
        for m in markers { try? FileManager.default.removeItem(atPath: m) }
    }
}
