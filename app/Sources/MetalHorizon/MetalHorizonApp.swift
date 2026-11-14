import AppKit
import SwiftUI

private func keychainEntryExists(account: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", "Xodus Service", "-a", account]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

/// True when the Xbox session xodus saved is in the Keychain (names only, the secrets are never read).
func xboxAccountSaved() -> Bool {
    keychainEntryExists(account: "user-DA") && keychainEntryExists(account: "user-tokens")
}

struct MetalHorizonApp: App {
    @StateObject private var model = LauncherModel()
    @StateObject private var updater = Updater()   // Updater.swift: the check at each launch, the forced update
    @State private var showAssistant = false

    init() {
        // MH_SNAPSHOT=<file.png>: draw the open window (with MH_SNAPSHOT_SHEET=welcome, the first-launch sheet) into an
        // image and quit, to check the layout. The app draws its own layers: no screen recording permission is needed.
        guard let path = ProcessInfo.processInfo.environment["MH_SNAPSHOT"] else { return }
        DispatchQueue.main.async {
            if let look = ProcessInfo.processInfo.environment["MH_SNAPSHOT_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: look == "light" ? .aqua : .darkAqua)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        let delay = Double(ProcessInfo.processInfo.environment["MH_SNAPSHOT_DELAY"] ?? "") ?? 3.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // MH_SNAPSHOT_SCREEN=1: the window as the screen shows it (Liquid Glass is drawn by the window server,
            // which a layer render does not see); needs Screen Recording for the app that runs it.
            if ProcessInfo.processInfo.environment["MH_SNAPSHOT_SCREEN"] == "1",
               let number = (NSApp.windows.first { $0.isSheet && $0.isVisible } ?? NSApp.windows.first { $0.isVisible })?.windowNumber {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-o", "-x", "-l", String(number), path]
                try? capture.run()
                capture.waitUntilExit()
                exit(0)
            }
            let window = NSApp.windows.first { $0.isSheet && $0.isVisible } ?? NSApp.windows.first { $0.isVisible }
            if let view = window?.contentView?.superview ?? window?.contentView, let layer = view.layer {
                let scale = window?.backingScaleFactor ?? 2
                let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
                if let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.scaleBy(x: scale, y: scale)
                    layer.render(in: context)
                    if let image = context.makeImage() {
                        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: path))
                    }
                }
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("MetalHorizon") {
            LauncherView(model: model)
                .frame(minWidth: 680, minHeight: 560)
                .sheet(isPresented: $showAssistant) { AssistantSheet() }
                .appUpdates(updater, model: model)
                .tint(Theme.accent)
        }
        .defaultSize(width: 980, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MetalHorizon") { showAbout() }
                Button("Check for Updates…") { updater.checkNow(model: model) }
            }
            CommandMenu("Options") {
                Toggle("Metal Performance HUD", isOn: $model.metalHUD)
                Toggle("MetalFX Upscaling (DLSS in the Game)", isOn: $model.metalFX)
                Picker("Frame Cap", selection: $model.maxFPS) {
                    Text("None").tag(0)
                    ForEach([30, 40, 45, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Controllers", selection: $model.controllerMode) {
                    ForEach(ControllerMode.allCases) { Text($0.title).tag($0) }
                }
                Divider()
                Toggle("Relaunch After D3DMetal Start-up Failure", isOn: $model.autoRetry)
                Picker("Crash Reports", selection: $model.crashReportMode) {
                    ForEach(CrashReportMode.allCases) { Text($0.title).tag($0) }
                }
            }
            CommandMenu("Tools") {
                Button("Run Checks Again") { model.refreshChecks() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Export Diagnostics…") { model.exportDiagnostics() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Report an Issue on GitHub…") { model.reportIssue() }
                Button("Send the Last Crash Report…") { model.showLastCrashReport() }
                Divider()
                Button("Show Logs in Finder") { model.revealLogs() }
                Button("Open the Wine Prefix in Finder") { model.revealPrefix() }
                Button("Test Controllers in Wine…") { model.runTool("joycpl") }
                Button("Wine Configuration…") { model.runTool("winecfg") }
                Divider()
                Button("Open Steam") { model.openSteam() }
                    .disabled(model.edition != .steam)
                Button("Stop Steam") { model.stopSteam() }
                    .disabled(model.edition != .steam)
            }
            CommandGroup(after: .help) {
                Button("Connect an AI Assistant (MCP)…") { showAssistant = true }
                Button("MetalHorizon on GitHub") { NSWorkspace.shared.open(issuesURL.deletingLastPathComponent()) }
            }
            // The projects MetalHorizon is built on; each item opens its GitHub page.
            CommandMenu("Thanks") {
                ForEach(thanks, id: \.url) { item in
                    Button(item.name) { NSWorkspace.shared.open(URL(string: item.url)!) }
                }
                Divider()
                Button("Support MetalHorizon…") { NSWorkspace.shared.open(supportURL) }
            }
        }
        Settings {
            SettingsView(model: model)
                .tint(Theme.accent)
        }
    }

    private var thanks: [(name: String, url: String)] {
        [
            ("Highball, by Gauthier Piarrette", "https://github.com/gauthierpiarrette/highball"),
            ("highball-engine (the native arm64 route)", "https://github.com/gauthierpiarrette/highball-engine"),
            ("FEX", "https://github.com/FEX-Emu/FEX"),
            ("KosmicKrisp (Mesa)", "https://gitlab.freedesktop.org/mesa/mesa"),
            ("vkd3d-proton", "https://github.com/HansKristian-Work/vkd3d-proton"),
            ("DXVK", "https://github.com/doitsujin/dxvk"),
            ("highball-db", "https://github.com/gauthierpiarrette/highball-db"),
            ("Ferestre, by icex", "https://github.com/icex/ferestre"),
            ("xodus", "https://github.com/xodus-gaming/xodus"),
            ("xodus Wine", "https://github.com/xodus-gaming/wine"),
            ("DXMT, by 3Shain", "https://github.com/3Shain/dxmt"),
            ("Mullion", "https://github.com/dttdrv/mullion"),
            ("Wine", "https://github.com/wine-mirror/wine"),
            ("llvm-mingw", "https://github.com/mstorsjo/llvm-mingw"),
            ("mingw-w64", "https://www.mingw-w64.org"),
            ("SDL", "https://github.com/libsdl-org/SDL"),
            ("MoltenVK", "https://github.com/KhronosGroup/MoltenVK"),
            ("Blackwell Engine", "https://github.com/alexandreunitypro/blackwell-engine")
        ]
    }

    private func showAbout() {
        let credits = NSAttributedString(string: """
            1.0 Final Beta. Unofficial: not affiliated with or endorsed by Microsoft, Xbox, Valve, Playground Games, Apple or CodeWeavers. \
            Built on Highball (its native arm64 route, FEX patches and signed loader), Ferestre, xodus, Wine, FEX, KosmicKrisp, \
            vkd3d-proton, DXVK, DXMT, SDL and Apple's D3DMetal: see the Thanks menu.
            """, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum Activity { case idle, signIn, install, download, game, steam, preparing }

enum LogView: String, CaseIterable, Identifiable {
    case activity, game
    var id: String { rawValue }
    var title: String { self == .activity ? "Activity" : "Game Output" }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var edition = Edition.xbox {
        didSet {
            // a snapshot's MH_SNAPSHOT_EDITION is only for that picture
            if ProcessInfo.processInfo.environment["MH_SNAPSHOT_EDITION"] == nil {
                settingsStore().set(edition.rawValue, forKey: SettingKey.edition)
            }
            editionChanged()
        }
    }
    @Published var gameDirectory = "" {
        didSet { settingsStore().set(gameDirectory, forKey: SettingKey.gameDirectory); refreshChecks() }
    }
    @Published var steamPrefix = "" {
        didSet { settingsStore().set(steamPrefix, forKey: SettingKey.steamPrefix); refreshChecks() }
    }
    @Published var engineDirectory = "" {
        didSet { settingsStore().set(engineDirectory, forKey: SettingKey.engineDirectory) }
    }
    @Published var d3dmetalDirectory = "" {
        didSet { settingsStore().set(d3dmetalDirectory, forKey: SettingKey.d3dmetalDirectory) }
    }
    @Published var metalHUD = true {
        didSet { settingsStore().set(metalHUD, forKey: SettingKey.metalHUD) }
    }
    @Published var controllerMode = ControllerMode.automatic {
        didSet { settingsStore().set(controllerMode.rawValue, forKey: SettingKey.controllerMode) }
    }
    @Published var metalFX = false {
        didSet { settingsStore().set(metalFX, forKey: SettingKey.metalFX) }
    }
    @Published var maxFPS = 0 {
        didSet { settingsStore().set(maxFPS, forKey: SettingKey.maxFPS) }
    }
    @Published var ownership = XboxOwnership.purchase {
        didSet { settingsStore().set(ownership.rawValue, forKey: SettingKey.ownership) }
    }
    @Published var plainSync = false {
        didSet { settingsStore().set(plainSync, forKey: SettingKey.plainSync) }
    }
    @Published var engineRoute = EngineRoute.automatic {
        didSet { settingsStore().set(engineRoute.rawValue, forKey: SettingKey.engineRoute); refreshChecks() }
    }
    /// The engine the next Play uses and why (RouteDecision), recomputed by refreshChecks and after each run.
    @Published var routeDecision = RouteDecision(route: .d3dmetal, reason: "")
    /// What the Autopilot did in the last day (RepairLog).
    @Published var recentRepairs: [Repair] = []
    /// What the Doctor can fix with the player's click (moving a folder, quitting an app, a password).
    @Published var pendingFixes: [PendingFix] = []
    private var lastAccountProblem = ""
    private var doctorState = DoctorState.load()
    private var doctorTimer: Timer?
    private var examining = false
    @Published var autoRetry = true {
        didSet { settingsStore().set(autoRetry, forKey: SettingKey.autoRetry) }
    }
    @Published var activity = Activity.idle
    @Published var status = "Ready."
    @Published var accountSaved = false
    /// Xbox refused the saved sign-in during the last Play (metalhorizon-play.sh leaves this marker): the account step
    /// is to do again, and a new sign-in clears it.
    @Published var signInExpired = fileExists(signInExpiredMarker.path)
    @Published var installFraction: Double?
    @Published var steamStatus = SteamStatus()
    @Published var findings: [Finding] = []
    @Published var preflight: [PreflightItem] = []
    @Published var logView = LogView.activity { didSet { reloadLogView() } }
    @Published var errorsOnly = false
    @Published var search = ""
    @Published private(set) var logLines: [String] = []
    /// The first-launch guide; the components install once it is closed, so Apple's licence comes after it.
    @Published var showWelcome: Bool = {
        if let sheet = ProcessInfo.processInfo.environment["MH_SNAPSHOT_SHEET"] { return sheet == "welcome" }
        if ProcessInfo.processInfo.environment["MH_SNAPSHOT"] != nil { return false }
        return !settingsStore().bool(forKey: SettingKey.welcomeShown)
    }()
    @Published var licenseText: String?
    private var licenseAnswer: CheckedContinuation<Bool, Never>?
    /// A crash to show (CrashReport.swift): at launch for a run that crashed meanwhile, or right after one.
    @Published var crashReport: CrashReport?
    @Published var crashReportSending = false
    @Published var crashReportMode = CrashReport.mode {
        didSet { CrashReport.mode = crashReportMode }
    }

    private var process: Process?
    private var session: LogSession?
    private var lastSessionURLs: (output: URL, game: URL)?
    private let outputTail = LogTail()
    private let gameTail = LogTail()
    private var runOutputTimer: Timer?
    private var lastNote: String?
    private var checksGeneration = 0
    private var steamTimer: Timer?
    private var steamInstallOffered = false
    private var loginApplication: NSRunningApplication?
    private var loginObserver: NSObjectProtocol?
    private var loginStatusTimer: Timer?
    private var loginStatusFile: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("metalhorizon-xodus-login-\(ProcessInfo.processInfo.processIdentifier).status")
    }

    init() {
        var saved = Setup.load()
        if let snapshotEdition = ProcessInfo.processInfo.environment["MH_SNAPSHOT_EDITION"].flatMap(Edition.init(rawValue:)) {
            saved.edition = snapshotEdition
        }
        // A copy already on this Mac (a reinstall, a game folder on an external disk) is found without a dialog.
        if saved.edition == .xbox, !saved.xboxGameCheck.ok, let found = Setup.detectXboxGame(), found != saved.gameDirectory {
            saved.gameDirectory = found
        }
        edition = saved.edition
        gameDirectory = saved.gameDirectory
        steamPrefix = saved.steamPrefix
        engineDirectory = saved.engineDirectory
        d3dmetalDirectory = saved.d3dmetalDirectory
        metalHUD = saved.metalHUD
        controllerMode = saved.controllerMode
        metalFX = saved.metalFX
        maxFPS = saved.maxFPS
        autoRetry = saved.autoRetry
        engineRoute = saved.engineRoute
        plainSync = saved.plainSync
        ownership = saved.ownership
        loginObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "org.xodus-gaming.xodus-cli" else { return }
            Task { @MainActor in
                guard let self, self.loginApplication?.processIdentifier == app.processIdentifier else { return }
                self.finishSignIn()
            }
        }
        refreshSavedAccountStatus()
        refreshChecks()
        showLastSession()
        if ProcessInfo.processInfo.environment["MH_SNAPSHOT"] == nil, let pending = CrashReport.pending(edition: edition) {
            offerCrashReport(pending)
        }
        startSteamPolling()
        // Blackwell Engine and D3DMetal install by themselves (D3DMetal after Apple's licence is accepted); then the
        // Doctor looks at everything once, and again every quarter of an hour while nothing runs.
        if ProcessInfo.processInfo.environment["MH_SNAPSHOT"] == nil && !showWelcome {
            Task {
                await self.installComponents()
                await self.examine(.launch)
            }
        }
        if ProcessInfo.processInfo.environment["MH_SNAPSHOT"] == nil {
            doctorTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isBusy else { return }
                    await self.examine(.idle)
                }
            }
        }
    }

    func finishWelcome() {
        guard showWelcome else { return }
        showWelcome = false
        settingsStore().set(true, forKey: SettingKey.welcomeShown)
        Task { await installComponents() }
    }

    func openSupportPage() { NSWorkspace.shared.open(supportURL) }

    /// Settings › Graphics › Use It Again: the native engine is back in the automatic choice.
    func clearNativeBench() {
        var health = RouteHealth.load()
        health.clearBench(.native)
        health.save()
        nativeInstallFailed = false
        RepairLog.record(Repair(title: "Native engine back in use", detail: "Chosen in Settings › Graphics.", kind: .note))
        refreshChecks()
    }

    private func editionChanged() {
        refreshChecks()
        showLastSession()
        startSteamPolling()
        guard ProcessInfo.processInfo.environment["MH_SNAPSHOT"] == nil, !showWelcome else { return }
        Task { await installComponents() }
    }

    // MARK: - What is set up

    var setup: Setup {
        Setup(edition: edition, gameDirectory: gameDirectory, steamPrefix: steamPrefix, engineDirectory: engineDirectory,
              d3dmetalDirectory: d3dmetalDirectory, metalHUD: metalHUD, controllerMode: controllerMode,
              metalFX: metalFX, maxFPS: maxFPS, autoRetry: autoRetry, engineRoute: engineRoute, plainSync: plainSync,
              ownership: ownership)
    }
    var isBusy: Bool { activity != .idle }
    var canDownload: Bool { !isBusy && !gameDirectory.isEmpty && edition == .xbox }
    var canPlay: Bool {
        guard !isBusy else { return false }
        return edition == .xbox ? setup.gameCheck.ok : setup.steamClientCheck.ok
    }

    /// The checks before Play and what the last run left, recomputed off the main thread. A game package left behind
    /// by a move is put back first (Setup.repairXboxPackage).
    func refreshChecks() {
        if edition == .xbox, !isBusy, ProcessInfo.processInfo.environment["MH_SNAPSHOT"] == nil,
           let note = Setup.repairXboxPackage(in: gameDirectory) {
            status = note
        }
        let current = setup
        // Only the newest round counts: rounds run in parallel, and one started before the game folder was known (at
        // launch) could finish last and bring back stale warnings ("The download needs about 160 GB" for an installed game).
        checksGeneration += 1
        let generation = checksGeneration
        Task.detached(priority: .utility) {
            let items = Diagnostics.preflight(current)
            let decision = current.routeDecision()
            let repairs = RepairLog.recent()
            await MainActor.run {
                guard generation == self.checksGeneration else { return }
                self.preflight = items
                if self.routeDecision != decision { self.routeDecision = decision }
                if self.recentRepairs != repairs { self.recentRepairs = repairs }
            }
        }
        objectWillChange.send()
    }

    // MARK: - Folders

    private func pickFolder(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true   // D3DMetal may sit inside an app bundle
        return panel.runModal() == .OK ? panel.url : nil
    }

    func chooseGameDirectory() {
        if let url = pickFolder(title: "Folder for Forza Horizon 6",
                                message: "Pick a real folder with a short path, such as ~/FH6, on a drive with about 160 GB free. Not in iCloud Drive.") {
            gameDirectory = url.path
            if Setup.looksLikeSteamGameFolder(url.path) {
                status = "That folder holds the Steam copy: switch the edition to Steam at the top of the window."
            }
        }
    }

    /// The Steam prefix: MetalHorizon's own by default, or an existing bottle (Highball, CrossOver, Whisky) with Steam.
    func chooseSteamPrefix() {
        guard let url = pickFolder(title: "Steam prefix",
                                   message: "Pick an empty folder for a new Steam prefix (about 170 GB with the game), or an existing Wine bottle that already has Steam and Forza Horizon 6 (Highball, CrossOver, Whisky).") else { return }
        let path = url.path
        if Setup.looksLikeSteamPrefix(path) {
            steamPrefix = path
            status = "Using the Steam already installed in \(path)."
        } else if fileExists(path + "/drive_c") {
            steamPrefix = path
            status = "That bottle has no Steam yet: click Install Steam."
        } else {
            steamPrefix = path + "/MetalHorizon Steam"
            status = "The Steam prefix will be created in \(steamPrefix)."
        }
    }

    func useDefaultSteamPrefix() { steamPrefix = "" }

    func revealLogs() { NSWorkspace.shared.open(logDirectory) }

    func revealPrefix() {
        let drive = setup.prefix + "/drive_c"
        if fileExists(drive) { NSWorkspace.shared.open(URL(fileURLWithPath: drive)) }
        else { status = "No Wine prefix yet: it is created by the first Play (Xbox) or by Install Steam." }
    }

    // MARK: - Blackwell Engine and D3DMetal

    /// Installs what the edition is missing (its Blackwell Engine, then D3DMetal once Apple's licence is accepted) and
    /// assembles the shim from that engine.
    // MARK: - The Doctor

    /// Looks at everything the Doctor knows at a moment, applies what it may by itself, and shows what needs a click.
    @discardableResult
    func examine(_ moment: DoctorMoment) async -> Examination {
        guard !examining else { return Examination() }
        examining = true
        defer { examining = false }
        let current = setup
        let account = accountSaved
        let patient = await Task.detached(priority: .userInitiated) { () -> Patient in
            let edition = current.edition
            let runs = LogStore.sessions().filter { s in
                edition == .steam ? s.kind.hasPrefix("steam") : !s.kind.hasPrefix("steam")
            }.prefix(12).map(RunRecord.init)
            let location = Diagnostics.appLocation
            let needsNetwork = (moment == .beforePlay || moment == .afterAction) && edition == .xbox
            let net = needsNetwork ? Sys.reachMicrosoft() : (online: true, skew: nil)
            // the account itself, tried for real, when the network is there and a sign-in is saved
            let check = needsNetwork && net.online && account ? AccountCheck.run(resources: Bundle.main.resourceURL) : nil
            var patient = Patient(setup: current, facts: .current, moment: moment, runs: Array(runs),
                           gameRunning: Sys.pgrep("forzahorizon6\\.exe"),
                           serviceRunning: Sys.pgrep("xodus-service"),
                           serviceSocket: fileExists("/private/tmp/xodus-runtime-test/xodus.sock"),
                           accountSaved: account, rosetta: Diagnostics.rosettaInstalled,
                           freeBytes: Diagnostics.freeSpace(at: edition == .steam ? current.steamPrefixPath : current.gameDirectory),
                           appTranslocated: location.translocated, appQuarantined: location.quarantined,
                           appPath: Bundle.main.bundlePath,
                           online: needsNetwork ? net.online : nil, clockSkew: net.skew,
                           steamNativeRunning: edition == .steam && Diagnostics.nativeSteamRunning())
            patient.account = check
            return patient
        }.value
        var state = doctorState
        let exam = await Doctor.examine(patient, actions: doctorActions, state: &state)
        doctorState = state
        state.save()
        exam.repairs.forEach(RepairLog.record)
        recentRepairs = RepairLog.recent()
        // the one-click fixes: those of the ailments looked at now are replaced, the others stay until their moment
        let lookedAt = Set(Doctor.catalogue.filter { $0.moments.contains(moment) }.map(\.id))
        pendingFixes = pendingFixes.filter { !lookedAt.contains($0.id) } + exam.pending
        if let last = exam.repairs.last, !isBusy { status = "MetalHorizon: \(last.title)." }
        refreshChecks()
        var result = exam
        if patient.online == false { result.blocker = "offline" }
        switch patient.account {
        case .refused(let why)?: result.blocker = "account"; lastAccountProblem = "Xbox does not accept the saved sign-in (\(why)). Sign in again, then Play."
        case .noSignIn?: result.blocker = "account"; lastAccountProblem = "No Microsoft sign-in is saved. Sign in, then Play."; accountSaved = false
        case .keychainWaiting?: status = "macOS is asking to let xodus-service use your Xbox sign-in (a Keychain window, maybe behind this one): choose Always Allow."
        case .accepted?: signInExpired = false
        default: break
        }
        return result
    }

    /// Runs a one-click fix, then looks again.
    func applyFix(_ fix: PendingFix) {
        Task {
            status = "\(fix.button)…"
            let outcome = await fix.action()
            status = outcome
            pendingFixes.removeAll { $0.id == fix.id }
            await examine(.idle)
        }
    }

    /// What the Doctor may do, through the model so the window follows.
    private var doctorActions: DoctorActions {
        DoctorActions(
            installComponent: { [weak self] id in try await self?.installComponent(id) },
            setMetalFX: { [weak self] v in self?.metalFX = v },
            setPlainSync: { [weak self] v in self?.plainSync = v },
            setMaxFPS: { [weak self] v in self?.maxFPS = v },
            setHUD: { [weak self] v in self?.metalHUD = v },
            setControllerMode: { [weak self] v in self?.controllerMode = v },
            setGameDirectory: { [weak self] v in self?.gameDirectory = v },
            setEngineRoute: { [weak self] v in self?.engineRoute = v },
            signInAgain: { [weak self] in self?.connectMicrosoft() },
            startDownload: { [weak self] in self?.download() },
            openURL: { NSWorkspace.shared.open($0) },
            relaunchApp: { [weak self] path in self?.moveToApplications(from: path) })
    }

    /// One component, installed (or installed again) on its own, with the licence and progress of a normal install.
    func installComponent(_ id: String) async throws {
        guard let component = Component.named(id) else { return }
        try await Installer.install(component, confirm: { [weak self] license in
            await self?.askLicense(license) ?? false
        }, progress: { [weak self] fraction, text in
            Task { @MainActor in self?.installFraction = fraction; self?.status = text }
        })
        installFraction = nil
        if NativeEngine.filesPresent && NativeEngine.loaderPresent && !NativeEngine.linked { try NativeEngine.linkLoader() }
        let current = setup
        if id != "engine-native" && id != "wineloader",
           fileExists(current.engine + "/renderers/tsshim/x86_64-windows/d3d12.dll"), fileExists(current.d3dmetal + "/wine/x86_64-windows/d3d12.dll") {
            try Installer.prepareShim(engine: current.engine, d3dmetal: current.d3dmetal)
        }
    }

    /// Moves MetalHorizon from where macOS translocated it (or Downloads) to /Applications and opens it there.
    func moveToApplications(from path: String) {
        let original = Diagnostics.appLocation.path   // the real location behind a translocated copy
        let source = fileExists(original) ? original : path
        let target = "/Applications/MetalHorizon.app"
        do {
            if fileExists(target) { try FileManager.default.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil) }
            try FileManager.default.moveItem(atPath: source, toPath: target)
            Sys.removeQuarantine(target)
            RepairLog.record(Repair(title: "MetalHorizon moved to Applications", detail: "From \(Setup.tildePath(source)).", kind: .fixed))
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: target), configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } catch {
            status = "MetalHorizon could not be moved to Applications: \(error). Move it in the Finder."
        }
    }

    /// Whether this Mac's next Play may use the native engine, so its pieces are worth installing now.
    private var wantsNative: Bool {
        guard edition == .xbox, !nativeInstallFailed else { return false }
        switch engineRoute {
        case .d3dmetal: return false
        case .native: return MachineFacts.current.nativeSupported
        case .automatic: return MachineFacts.current.nativeRecommended && !RouteHealth.load().isBenched(.native)
        }
    }
    /// A native piece that would not install: not tried again until the next launch, D3DMetal runs the game.
    private var nativeInstallFailed = false

    /// Installs what the edition is missing (its Blackwell Engine, then D3DMetal once Apple's licence is accepted, and
    /// on a Mac that can run it the native engine with Highball's signed loader) and assembles the shim from that
    /// engine. D3DMetal is always installed: it is what the game falls back to.
    func installComponents() async {
        guard !isBusy else { return }
        let steam = edition == .steam
        let native = wantsNative
        let order = ["engine": 0, "engine-steam": 0, "d3dmetal": 1, "wineloader": 2, "engine-native": 3]
        let missing = Component.all().filter { component in
            guard !component.isInstalled else { return false }
            switch component.id {
            case "engine": return !steam && engineDirectory.isEmpty
            case "engine-steam": return steam && engineDirectory.isEmpty
            case "d3dmetal": return d3dmetalDirectory.isEmpty
            case "wineloader", "engine-native": return native
            default: return false
            }
        }.sorted { (order[$0.id] ?? 9) < (order[$1.id] ?? 9) }
        let shimFrom = setup.engine + "/renderers/tsshim/x86_64-windows/d3d12.dll"
        let shimStale = (try? FileManager.default.contentsEqual(atPath: shimFrom, andPath: shimDirectory + "/x86_64-windows/d3d12.dll")) == false
        let relink = native && NativeEngine.filesPresent && NativeEngine.loaderPresent && !NativeEngine.linked
        if missing.isEmpty && setup.shimReady && !shimStale && !relink { return }
        activity = .install
        defer { activity = .idle; installFraction = nil; refreshChecks() }
        var failure: String?
        for component in missing {
            do {
                try await Installer.install(component, confirm: { [weak self] license in
                    await self?.askLicense(license) ?? false
                }, progress: { [weak self] fraction, text in
                    Task { @MainActor in self?.installFraction = fraction; self?.status = text }
                })
            } catch {
                if component.id == "engine-native" || component.id == "wineloader" {
                    // never a reason not to play: D3DMetal runs the game, and the next launch tries again
                    nativeInstallFailed = true
                    var health = RouteHealth.load()
                    health.bench(.native, for: 6 * 3600, reason: "The native engine could not be installed (\(error)); D3DMetal runs the game.")
                    health.save()
                    RepairLog.record(Repair(title: "Native engine postponed", detail: "\(component.name) could not be installed: \(error). D3DMetal runs the game; MetalHorizon tries again later.", kind: .switchedEngine))
                    continue
                }
                failure = "\(error)"
                break
            }
        }
        do {
            if relink || (NativeEngine.filesPresent && NativeEngine.loaderPresent && !NativeEngine.linked) { try NativeEngine.linkLoader() }
            let current = setup
            if fileExists(current.engine + "/renderers/tsshim/x86_64-windows/d3d12.dll"),
               fileExists(current.d3dmetal + "/wine/x86_64-windows/d3d12.dll") {
                try Installer.prepareShim(engine: current.engine, d3dmetal: current.d3dmetal)
            }
        } catch {
            failure = failure ?? "\(error)"
        }
        let current = setup
        if let failure {
            status = failure
        } else {
            status = current.componentsReady
                ? (current.edition == .xbox ? (current.gameCheck.ok ? "Ready." : "The engines are installed. Download the game.")
                   : (current.steamClientCheck.ok ? "Ready." : "Blackwell Engine Steam and D3DMetal are installed. Install Steam."))
                : "Some components are missing; see what needs attention."
        }
    }

    private func askLicense(_ file: URL) async -> Bool {
        let text = (try? NSAttributedString(url: file, options: [:], documentAttributes: nil))?.string
            ?? "Apple's licence could not be read (\(file.lastPathComponent))."
        return await withCheckedContinuation { continuation in
            licenseAnswer = continuation
            licenseText = text
        }
    }

    func answerLicense(_ accepted: Bool) {
        licenseText = nil
        licenseAnswer?.resume(returning: accepted)
        licenseAnswer = nil
    }

    // MARK: - Microsoft account

    private func refreshSavedAccountStatus(continueAfterSignIn: Bool = false) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let saved = xboxAccountSaved()
            Task { @MainActor in
                guard let self else { return }
                self.accountSaved = saved
                if continueAfterSignIn && saved { self.continueAfterSignIn() }
            }
        }
    }

    /// Right after a successful sign-in, the game's download starts by itself when it is the next step and the disk
    /// has room for it: one click less, and nothing to find in the window.
    private func continueAfterSignIn() {
        guard edition == .xbox, !isBusy, next.action == .download else { return }
        if let free = Diagnostics.freeSpace(at: gameDirectory), free < 170_000_000_000 {
            status = "Signed in. The game needs about 170 GB free where it goes (\(Setup.tildePath(gameDirectory))); "
                + "\(free / 1_000_000_000) GB are free. Free some space or choose another folder, then Download the Game."
            return
        }
        try? FileManager.default.createDirectory(atPath: gameDirectory, withIntermediateDirectories: true)
        download()
    }

    func connectMicrosoft() {
        guard !isBusy else { return }
        guard let loginApp = Bundle.main.resourceURL?.appendingPathComponent("Xodus Login.app") else {
            status = "The sign-in helper is missing from this app."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["login"]
        try? FileManager.default.removeItem(at: loginStatusFile)
        // xodus-cli reports its sign-in progress in this file (the variable name comes from the prototype).
        configuration.environment = ["BLACKWELL_LOGIN_STATUS_FILE": loginStatusFile.path]
        configuration.activates = true
        activity = .signIn
        status = "Opening Microsoft sign-in…"
        loginStatusTimer?.invalidate()
        loginStatusTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLogin() }
        }
        NSWorkspace.shared.openApplication(at: loginApp, configuration: configuration) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.activity = .idle
                    self.loginStatusTimer?.invalidate()
                    self.loginStatusTimer = nil
                    self.status = "Could not open Microsoft sign-in: \(error.localizedDescription)"
                    return
                }
                self.loginApplication = app
                self.status = "Microsoft sign-in is open."
            }
        }
    }

    /// Ends the sign-in, whichever comes first: the helper reporting an end state (complete, cancelled, refused),
    /// or its window closing. The helper does not always quit after "complete", and its quit is not always seen:
    /// waiting for it alone left the button on "Signing In…" after a successful sign-in.
    private func finishSignIn() {
        guard activity == .signIn else { return }
        loginStatusTimer?.invalidate()
        loginStatusTimer = nil
        readLoginStatus()
        if let app = loginApplication, !app.isTerminated { app.terminate() }
        loginApplication = nil
        activity = .idle
        let connected = status == "Xbox account connected."
        if !connected
            && status != "Microsoft sign-in returned a response Xbox could not accept."
            && status != "Xbox token exchange failed; the sign-in window has stopped."
            && status != "Microsoft sign-in was cancelled." {
            status = "The sign-in window closed before Xbox accepted the account."
        }
        if connected {
            try? FileManager.default.removeItem(at: signInExpiredMarker)
            signInExpired = false
            // the running xodus-service still holds the old session: the next Play starts a fresh one
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            stop.arguments = ["-f", "xodus-service"]
            try? stop.run()
        }
        refreshSavedAccountStatus(continueAfterSignIn: connected)
        // after a sign-in, the account is tried for real (and a failed sign-in looked at: clock, network)
        Task { await examine(.afterAction) }   // a wrong clock or no network fails a sign-in too
    }

    /// The helper's end states: the sign-in is over whether or not its window is still open.
    private static let loginEndStates: Set<String> = ["complete", "cancelled", "exchange_rejected", "exchange_failed"]

    private func pollLogin() {
        readLoginStatus()
        let raw = (try? String(contentsOf: loginStatusFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Self.loginEndStates.contains(raw) || loginApplication?.isTerminated == true {
            finishSignIn()
        }
    }

    private func readLoginStatus() {
        guard let rawStatus = try? String(contentsOf: loginStatusFile, encoding: .utf8) else { return }
        switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "starting": status = "Preparing Xbox sign-in…"
        case "waiting_for_microsoft": status = "Enter your Microsoft account in the sign-in window."
        case "received_response": status = "Microsoft responded; checking the Xbox account…"
        case "exchange_pending": status = "Exchanging the Microsoft response for Xbox access…"
        case "exchange_failed": status = "Xbox token exchange failed; the sign-in window has stopped."
        case "approval_required": status = "Microsoft requires an additional approval step."
        case "account_accepted": status = "Xbox accepted the account; saving the sign-in…"
        case "complete": status = "Xbox account connected."
        case "exchange_rejected": status = "Microsoft sign-in returned a response Xbox could not accept."
        case "cancelled": status = "Microsoft sign-in was cancelled."
        default: break
        }
    }

    // MARK: - Steam

    private var steamScript: URL? { Bundle.main.resourceURL?.appendingPathComponent("metalhorizon-steam.sh") }

    private func startSteamPolling() {
        steamTimer?.invalidate()
        steamTimer = nil
        guard edition == .steam, ProcessInfo.processInfo.environment["MH_SNAPSHOT"] == nil else { return }
        refreshSteamStatus()
        steamTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSteamStatus() }
        }
    }

    /// What runs in the Steam prefix (metalhorizon-steam.sh status), read off the main thread.
    func refreshSteamStatus() {
        guard edition == .steam, let script = steamScript, fileExists(script.path) else { return }
        let env = ProcessInfo.processInfo.environment.merging(setup.steamEnvironment()) { _, new in new }
        Task.detached(priority: .utility) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = [script.path, "status"]
            task.environment = env
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            guard (try? task.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let parsed = SteamStatus.parse(String(decoding: data, as: UTF8.self))
            await MainActor.run {
                if self.steamStatus != parsed { self.steamStatus = parsed }
                self.objectWillChange.send()
                self.continueAfterSteamSignIn()
            }
        }
    }

    /// Once the player has signed in in Steam's window and the game is not in the library, Steam's install window
    /// for it opens by itself, once per launch of MetalHorizon.
    private func continueAfterSteamSignIn() {
        guard edition == .steam, !isBusy, !steamInstallOffered, steamStatus.clientRunning, steamStatus.clientMode == "window" else { return }
        let files = setup.steam
        guard files.signedInOnce, files.manifest == nil else { return }
        installGameInSteam()
    }

    private func runSteam(_ action: String, activity newActivity: Activity, statusText: String,
                          extra: [String: String] = [:], finished: @escaping (Int32) -> String) {
        guard let script = steamScript else { return }
        let gameInput = Controllers.gameInputEnabled(mode: controllerMode, connected: Controllers.connected())
        run(executable: URL(fileURLWithPath: "/bin/bash"), arguments: [script.path, action],
            environment: setup.steamEnvironment(gameInput: gameInput).merging(extra) { _, new in new },
            activity: newActivity, statusText: statusText,
            logName: "steam-\(action)", finished: finished)
    }

    func installSteam() {
        Task {
            await installComponents()
            guard setup.engineCheck.ok else { status = "Blackwell Engine Steam did not install: see what needs attention below."; return }
            runSteam("install", activity: .steam, statusText: "Installing Steam…") { [weak self] code in
                guard code == 0 else { return "Steam's installation stopped (error \(code)). What to do shows under the button; the log is in Activity." }
                // straight on to Steam's window: its first start updates it, then the player signs in there
                DispatchQueue.main.async { self?.openSteam() }
                return "Steam installed; opening it. Its first start updates Steam (it can look frozen for a while), then sign in."
            }
        }
    }

    func openSteam() {
        guard edition == .steam else { return }
        // signed in and the game not in the library yet: Steam opens straight on its install window for the game
        let files = setup.steam
        if files.signedInOnce && files.manifest == nil {
            installGameInSteam()
            return
        }
        runSteam("open", activity: .steam, statusText: "Opening Steam…") { code in
            code == 0 ? "Steam is open. Sign in: its install window for Forza Horizon 6 then opens by itself." : "Steam did not open (error \(code)). What to do shows under the button."
        }
    }

    /// Steam's own install window for Forza Horizon 6 (steam://install/<appid>): Steam checks the licence and
    /// downloads; the player only confirms there.
    func installGameInSteam() {
        guard edition == .steam else { return }
        steamInstallOffered = true
        runSteam("open", activity: .steam, statusText: "Opening Steam's install window for Forza Horizon 6…",
                 extra: ["MH_STEAM_URL": "steam://install/\(steamAppID)"]) { code in
            code == 0 ? "In Steam's window, click Install. Play lights up when the download is done (about 160 GB)."
                      : "Steam did not open (error \(code)). What to do shows under the button."
        }
    }

    func stopSteam() {
        guard edition == .steam else { return }
        runSteam("stop", activity: .steam, statusText: "Stopping Steam…") { code in
            code == 0 ? "Steam stopped." : "Steam did not stop cleanly (error \(code))."
        }
    }

    // MARK: - Download and Play

    func download() {
        guard canDownload, let resources = Bundle.main.resourceURL else { return }
        let cli = Setup.xodusCLI(resources: resources)
        // xodus checks the licence on the signed-in account: only an owned game downloads.
        run(executable: cli, arguments: ["streaming", storeProductID, gameDirectory], environment: ["RUST_BACKTRACE": "1"],
            activity: .download, statusText: "Downloading Forza Horizon 6 from the Xbox servers…", logName: "download") { code in
            code == 0 ? "Download finished." : "The download stopped (error \(code)). See the activity log."
        }
    }

    /// The engine the running game uses (nil when nothing runs), the Play click's one automatic relaunch, and
    /// whether the player stopped the run (then nothing about it counts as a failure).
    private var runRoute: ResolvedRoute?
    private var relaunchedThisPlay = false
    private var userStoppedRun = false

    func play() {
        guard canPlay else { return }
        relaunchedThisPlay = false
        Task {
            // what the next run needs, installed first (the native engine's pieces when this Mac takes it)
            let wanted = setup.routeDecision().route
            if !setup.componentsReady(for: wanted) || !setup.componentsReady || (edition == .steam && !setup.readyToPlay) {
                await installComponents()
            }
            if edition == .steam {
                guard setup.readyToPlay else {
                    status = setup.steamGameCheck.ok ? (setup.steamClientCheck.fix ?? "Install Steam first.")
                                                     : (setup.steamGameCheck.fix ?? "Install Forza Horizon 6 in Steam first.")
                    return
                }
                startGame(route: .d3dmetal)
                return
            }
            // The Doctor before Play: what it can repair, repaired; and the network, which the licence needs at
            // every start (a Game Pass lease even more): a minute of waiting for it rather than a failed start.
            activity = .preparing
            let exam = await examine(.beforePlay)
            if exam.blocker == "offline" {
                var online = false
                for second in stride(from: 60, to: 0, by: -5) {
                    status = "Waiting for the network (\(second) s): Microsoft checks the game's licence at every start."
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    online = await Task.detached { Sys.reachMicrosoft().online }.value
                    if online { break }
                }
                if !online {
                    activity = .idle
                    status = "No connection to Microsoft's licence server, so the game cannot start. Connect to the internet and press Play."
                    return
                }
            }
            if exam.blocker == "account" {
                // the game would only say Initialization Failed: stop here, with the way out under the button
                activity = .idle
                signInExpired = true
                status = lastAccountProblem
                return
            }
            activity = .idle
            var route = setup.routeDecision().route
            if route == .native && !setup.componentsReady(for: .native) { route = .d3dmetal }
            guard setup.gameCheck.ok, setup.componentsReady(for: route) else {
                status = setup.gameCheck.ok ? "Some components are missing; see what needs attention." : (setup.gameCheck.fix ?? "Download the game first.")
                return
            }
            startGame(route: route)
        }
    }

    private func startGame(route: ResolvedRoute) {
        guard let resources = Bundle.main.resourceURL else { return }
        let connected = Controllers.connected()
        let gameInput = Controllers.gameInputEnabled(mode: controllerMode, connected: connected)
        userStoppedRun = false
        if edition == .steam {
            runRoute = .d3dmetal
            runSteam("play", activity: .game, statusText: "Playing through Steam. Quit from the game's own menu; Steam stays open in the background.") { code in
                code == 0 ? "Game closed." : "The game did not start or stopped (error \(code)). What to do shows under the button."
            }
            return
        }
        // what can be repaired without asking, repaired now and written down
        for repair in Autopilot.beforePlay(setup: setup, route: route) { RepairLog.record(repair) }
        recentRepairs = RepairLog.recent()
        runRoute = route
        let first = route == .native && !fileExists(setup.nativePrefix + "/system.reg")
        let playing = route == .native
            ? (first ? "First start on the native engine: the game spends about 10 minutes on Optimizing for your PC, once."
                     : "Playing on the native engine\(gameInput ? " (controllers on)" : ""). Quit from the game's menu; the cloud save uploads as it closes.")
            : "Playing\(gameInput ? " (controllers on)" : ""). Quit from the game's menu; the cloud save uploads as it closes."
        run(executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [resources.appendingPathComponent("metalhorizon-play.sh").path],
            environment: setup.playEnvironment(resources: resources, gameInput: gameInput, route: route),
            activity: .game, statusText: playing, logName: "play") { code in
            code == 0 ? "Game closed." : "The game stopped (error \(code)). What to do shows under the button."
        }
    }

    /// Stops a download or the sign-in; for the game, ends it (Xbox: every Wine process of its prefix; Steam: the game
    /// only, Steam stays).
    func stop() {
        if activity == .game {
            userStoppedRun = true
            if edition == .steam {
                let kill = Process()
                kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                kill.arguments = ["-f", "forzahorizon6\\.exe"]
                try? kill.run()
                status = "Force-quitting the game (Steam stays open)…"
                return
            }
            let native = runRoute == .native
            let engine = native ? NativeEngine.engine : setup.engine
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: engine + "/bin/wineserver")
            kill.arguments = ["-k"]
            kill.environment = ProcessInfo.processInfo.environment.merging(native ? [
                "WINEPREFIX": setup.nativePrefix
            ] : [
                "WINEPREFIX": setup.prefix,
                "CX_ROOT": setup.engine,
                "DYLD_LIBRARY_PATH": setup.engine + "/lib"
            ]) { _, new in new }
            try? kill.run()
            status = "Force-quitting the game…"
            return
        }
        process?.terminate()
        loginApplication?.terminate()
        loginApplication = nil
        if activity == .signIn { activity = .idle }
        status = "Stopped."
    }

    /// A Wine tool in the current prefix: Wine's game controller panel or winecfg.
    func runTool(_ tool: String) {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("metalhorizon-tool.sh") else { return }
        var env = setup.optionsEnvironment(gameInput: true)
        env["MH_PREFIX"] = setup.prefix
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path, tool]
        task.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let log = logDirectory.appendingPathComponent("tool-\(tool).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: log) { task.standardOutput = handle; task.standardError = handle }
        do { try task.run(); status = tool == "joycpl" ? "Wine's Game Controllers panel is opening: move the sticks to test." : "Opening \(tool)…" }
        catch { status = "Could not start \(tool): \(error.localizedDescription)" }
    }

    // MARK: - Runs, logs and diagnosis

    private func run(executable: URL, arguments: [String], environment: [String: String], activity newActivity: Activity,
                     statusText: String, logName: String, finished: @escaping (Int32) -> String) {
        guard !isBusy else { return }
        let newSession: LogSession
        do { newSession = try LogSession.create(kind: logName) } catch {
            status = "Could not create the log in \(logDirectory.path)."
            return
        }
        guard let logHandle = try? FileHandle(forWritingTo: newSession.output) else {
            status = "Could not write \(newSession.output.path)."
            return
        }
        var env = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        env["MH_GAME_LOG"] = newSession.game.path
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = logHandle
        task.standardError = logHandle
        task.environment = env
        process = task
        session = newSession
        lastSessionURLs = (newSession.output, newSession.game)
        outputTail.reset(newSession.output)
        gameTail.reset(newSession.game)
        logLines = []
        activity = newActivity
        status = statusText
        findings = []
        runOutputTimer?.invalidate()
        runOutputTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunOutput() }
        }
        task.terminationHandler = { [weak self] done in
            DispatchQueue.main.async {
                guard let self else { return }
                self.runOutputTimer?.invalidate()
                self.runOutputTimer = nil
                try? logHandle.close()
                self.refreshRunOutput()
                self.activity = .idle
                self.process = nil
                let code = done.terminationStatus
                let duration = Date().timeIntervalSince(newSession.started)
                let route = self.runRoute
                self.findings = newSession.finish(exitCode: code, extra: [
                    "route": route?.rawValue ?? "", "user_stopped": self.userStoppedRun, "edition": self.edition.rawValue
                ])
                self.status = finished(code)
                if let first = self.findings.first, first.issue.severity >= .warning, code != 0 || first.issue.severity == .error {
                    self.status += " Diagnosis: \(first.issue.title)."
                }
                self.session = nil
                // The Autopilot reads the run: it records how the engine fared, changes what it must, and may start
                // the game again once, on the engine the next Play would use.
                var relaunch: ResolvedRoute?
                if logName == "play", let route {
                    let outcome = RunOutcome(route: route, exitCode: code, duration: duration, findings: self.findings,
                                             userStopped: self.userStoppedRun, options: (self.metalFX, self.maxFPS))
                    var health = RouteHealth.load()
                    let decision = Autopilot.afterRun(outcome, health: &health,
                                                      nativeAvailable: NativeEngine.filesPresent && NativeEngine.loaderPresent,
                                                      facts: .current, preference: self.engineRoute,
                                                      alreadyRelaunched: self.relaunchedThisPlay)
                    health.save()
                    decision.repairs.forEach(RepairLog.record)
                    if decision.disableMetalFX { self.metalFX = false }
                    if decision.syncOff { self.plainSync = true }
                    if decision.restartXboxService {
                        NativeEngine.run("/usr/bin/pkill", ["-f", "xodus-service"])
                    }
                    if decision.reassembleShim {
                        try? Installer.prepareShim(engine: self.setup.engine, d3dmetal: self.setup.d3dmetal)
                    }
                    relaunch = self.autoRetry ? decision.relaunch : nil
                    if let last = decision.repairs.last, relaunch == nil { self.status += " MetalHorizon: \(last.title)." }
                }
                self.runRoute = nil
                // the Doctor reads the run too (caches, memory, the prefix, the service...), before any relaunch
                let failedAction = logName != "play" && logName != "steam-play" && code != 0
                if logName == "play" || logName == "steam-play" || failedAction {
                    Task { await self.examine(failedAction ? .afterAction : .afterRun) }
                }
                if let next = relaunch {
                    self.relaunchedThisPlay = true
                    self.status = "The game stopped early; MetalHorizon starts it again\(next == route ? "" : " on the \(next.title) engine")…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                        guard let self, !self.isBusy else { return }
                        self.startGame(route: next)
                    }
                } else if logName == "play" || logName == "steam-play",
                   let info = LogStore.sessions().first(where: { $0.id == newSession.id }),
                   let report = CrashReport.make(info, edition: self.edition) {
                    self.offerCrashReport(report)
                }
                self.refreshSavedAccountStatus()
                self.refreshChecks()
                self.refreshSteamStatus()
            }
        }
        do {
            try task.run()
        } catch {
            runOutputTimer?.invalidate()
            runOutputTimer = nil
            try? logHandle.close()
            process = nil
            session = nil
            activity = .idle
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    /// The last session's logs and findings, when the app opens.
    private func showLastSession() {
        // the last run of this edition: a Steam run's problems do not belong under the Xbox edition, nor the reverse
        let mine = LogStore.sessions().first { session in
            edition == .steam ? session.kind.hasPrefix("steam") : !session.kind.hasPrefix("steam")
        }
        guard let last = mine else { lastSessionURLs = nil; findings = []; outputTail.reset(nil); gameTail.reset(nil); logLines = []; return }
        let output = last.directory.appendingPathComponent("output.log")
        let game = last.directory.appendingPathComponent("game.log")
        lastSessionURLs = (output, game)
        outputTail.reset(output)
        gameTail.reset(game)
        findings = Diagnostics.scan(files: [output, game])
        refreshRunOutput()
    }

    private func refreshRunOutput() {
        let changed = logView == .activity ? outputTail.poll() : gameTail.poll()
        if logView == .activity { gameTail.poll() } else { outputTail.poll() }
        if changed || logLines.isEmpty { reloadLogView() }
        // A script's NOTE line is something the player has to do now (a macOS dialog waiting): it becomes the status.
        if isBusy, let note = outputTail.lines.last(where: { $0.hasPrefix("NOTE: ") }), note != lastNote {
            lastNote = note
            status = String(note.dropFirst(6))
        }
    }

    private func reloadLogView() {
        let source = logView == .activity ? outputTail.lines : gameTail.lines
        let shown = LogFilter.apply(source, errorsOnly: errorsOnly, search: search)
        logLines = Array(shown.suffix(1500))
    }

    func filterChanged() { reloadLogView() }

    var logPlaceholder: String {
        switch edition {
        case .xbox: return "MetalHorizon installs Blackwell Engine and D3DMetal by itself. Sign in, download the game, then click Play."
        case .steam: return "Install Steam, open it and sign in, install Forza Horizon 6 from your Steam Library, then click Play."
        }
    }

    func exportDiagnostics() {
        let current = setup
        status = "Writing the diagnostics bundle…"
        Task.detached(priority: .userInitiated) {
            do {
                let url = try Diagnostics.exportBundle(current)
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    self.status = "Diagnostics saved on the Desktop: \(url.lastPathComponent). Secrets are removed; attach it to a GitHub issue."
                }
            } catch {
                await MainActor.run { self.status = "Could not write the diagnostics: \(error)" }
            }
        }
    }

    func reportIssue() {
        NSWorkspace.shared.open(Diagnostics.issueURL(setup, findings: findings))
    }

    // MARK: - Crash reports

    private func offerCrashReport(_ report: CrashReport) {
        switch CrashReport.mode {
        case .never: return
        case .automatic where CrashReport.endpoint != nil: sendCrashReport(report)
        default: crashReport = report
        }
    }

    func sendCrashReport(_ report: CrashReport) {
        let current = setup
        crashReportSending = true
        status = "Sending the crash report…"
        Task {
            let result = await report.send(setup: current)
            crashReportSending = false
            crashReport = nil
            status = result
        }
    }

    func dismissCrashReport() {
        if let report = crashReport { CrashReport.markHandled(report.id) }
        crashReport = nil
    }

    /// Tools › Send the Last Crash Report…: the newest play run, even if it was dismissed before.
    func showLastCrashReport() {
        guard let session = LogStore.sessions().first(where: { $0.kind == "play" || $0.kind == "steam-play" }) else {
            status = "No game run yet."
            return
        }
        if let report = CrashReport.make(session, edition: edition) { crashReport = report }
        else { status = "The last game run did not crash. Export Diagnostics sends its logs anyway." }
    }

    func copyRosettaCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("softwareupdate --install-rosetta --agree-to-license", forType: .string)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        status = "The command is copied: paste it in Terminal and press Return."
    }
}

/// A crashed run: the error as the player would have read it, what MetalHorizon recognized, and Send.
struct CrashReportSheet: View {
    let report: CrashReport
    let sending: Bool
    var send: () -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundColor(.red).font(.title2)
                Text(report.headline).font(.headline)
            }
            Text("Forza Horizon 6 stopped during the run of \(report.date.formatted(date: .abbreviated, time: .shortened)) (\(report.gameVersion)).")
                .fixedSize(horizontal: false, vertical: true)
            if !report.message.isEmpty {
                GroupBox(label: Text("Error message")) {
                    Text(report.message + (report.backtrace.isEmpty ? "" : "\n" + report.backtrace.prefix(8).joined(separator: "\n")))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            }
            ForEach(report.findings.prefix(3)) { finding in
                VStack(alignment: .leading, spacing: 2) {
                    Text(finding.issue.title).fontWeight(.medium)
                    Text("What to do: " + finding.issue.fix).font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(CrashReport.endpoint == nil
                 ? "Send to the Developer opens a GitHub issue with this report filled in and shows a zip of the logs to attach. Passwords, tokens, e-mail addresses, Xbox and Steam IDs are removed first."
                 : "Send to the Developer uploads this report and a zip of the logs. Passwords, tokens, e-mail addresses, Xbox and Steam IDs are removed first.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button("Not Now", action: dismiss)
                    .disabled(sending)
                Button("Send to the Developer", action: send)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(sending)
            }
        }
        .padding(20)
        .frame(width: 560)
        .tint(Theme.accent)
    }
}

/// Apple's licence for D3DMetal, shown before it is installed. Declining installs nothing.
struct LicenseSheet: View {
    var text: String
    var answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple's Licence for D3DMetal")
                .font(.headline)
            Text("Forza Horizon 6 draws through Apple's D3DMetal (Game Porting Toolkit). Apple lets it be shared separately for free, non-commercial use. MetalHorizon installs it, unmodified, only if you accept Apple's licence:")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(text)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
            }
            .frame(height: 300)
            .background(Color(nsColor: .textBackgroundColor))
            .border(Color(nsColor: .separatorColor))
            HStack {
                Spacer()
                Button("Decline") { answer(false) }
                Button("Accept") { answer(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 600)
        .tint(Theme.accent)
    }
}

/// How to plug an AI assistant into MetalHorizon's MCP server (the same binary, started with --mcp).
struct AssistantSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let executable = Bundle.main.executablePath ?? "/Applications/MetalHorizon.app/Contents/MacOS/MetalHorizon"

    private var claudeCode: String { "claude mcp add metalhorizon -- \"\(executable)\" --mcp" }
    private var desktopConfig: String {
        """
        {
          "mcpServers": {
            "metalhorizon": {
              "command": "\(executable)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect an AI Assistant")
                .font(.headline)
            Text("MetalHorizon includes an MCP server. An assistant such as Claude can then run the checks, read the logs (tokens and e-mail addresses removed), recognize known errors, look at the controllers and Steam, change MetalHorizon's settings with you and export the diagnostics. It never sees your password and cannot start the game or a download.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Move MetalHorizon to the Applications folder first: the path below follows the app.")
                .font(.callout)
                .foregroundColor(.secondary)

            GroupBox(label: Text("Claude Code (Terminal)")) {
                snippet(claudeCode)
            }
            GroupBox(label: Text("Claude Desktop: Settings › Developer › Edit Config")) {
                snippet(desktopConfig)
            }
            Text("Other MCP apps: run \"\(executable)\" with the argument --mcp (stdio).")
                .font(.callout)
                .foregroundColor(.secondary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 560)
        .tint(Theme.accent)
    }

    private func snippet(_ text: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        .padding(6)
    }
}
