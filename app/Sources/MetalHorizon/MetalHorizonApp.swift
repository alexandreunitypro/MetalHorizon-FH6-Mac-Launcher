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
    init() {
        // MH_SNAPSHOT=<file.png>: draw the open window (with MH_SNAPSHOT_SHEET=1, the AI assistant sheet) into an image
        // and quit, to check the layout. The app draws its own layers: no screen recording permission is needed.
        guard let path = ProcessInfo.processInfo.environment["MH_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
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
            LauncherView()
                .frame(minWidth: 640, minHeight: 600)
        }
    }
}

enum Activity { case idle, signIn, install, download, game }

@MainActor
final class LauncherModel: ObservableObject {
    @Published var gameDirectory = "" {
        didSet { settingsStore().set(gameDirectory, forKey: SettingKey.gameDirectory) }
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
    @Published var activity = Activity.idle
    @Published var status = "Ready."
    @Published var output = ""
    @Published var accountSaved = false
    @Published var installFraction: Double?
    @Published var licenseText: String?
    private var licenseAnswer: CheckedContinuation<Bool, Never>?

    private var process: Process?
    private var runLogFile: URL?
    private var runLogHandle: FileHandle?
    private var runOutputTimer: Timer?
    private var loginApplication: NSRunningApplication?
    private var loginObserver: NSObjectProtocol?
    private var loginStatusTimer: Timer?
    private var loginStatusFile: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("metalhorizon-xodus-login-\(ProcessInfo.processInfo.processIdentifier).status")
    }

    init() {
        let saved = Setup.load()
        gameDirectory = saved.gameDirectory
        engineDirectory = saved.engineDirectory
        d3dmetalDirectory = saved.d3dmetalDirectory
        metalHUD = saved.metalHUD
        loginObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "org.xodus-gaming.xodus-cli" else { return }
            Task { @MainActor in
                guard let self, self.loginApplication?.processIdentifier == app.processIdentifier else { return }
                self.loginApplication = nil
                self.activity = .idle
                self.readLoginStatus()
                self.loginStatusTimer?.invalidate()
                self.loginStatusTimer = nil
                if self.status != "Xbox account connected."
                    && self.status != "Microsoft sign-in returned a response Xbox could not accept."
                    && self.status != "Xbox token exchange failed; the sign-in window has stopped."
                    && self.status != "Microsoft sign-in was cancelled." {
                    self.status = "The sign-in window closed before Xbox accepted the account."
                }
                self.refreshSavedAccountStatus()
            }
        }
        refreshSavedAccountStatus()
        // Blackwell Engine and D3DMetal install by themselves (D3DMetal after Apple's licence is accepted).
        if ProcessInfo.processInfo.environment["MH_SNAPSHOT"] == nil {
            Task { await self.installComponents() }
        }
    }

    // MARK: - What is set up

    var setup: Setup {
        Setup(gameDirectory: gameDirectory, engineDirectory: engineDirectory,
              d3dmetalDirectory: d3dmetalDirectory, metalHUD: metalHUD)
    }
    var isBusy: Bool { activity != .idle }
    var canDownload: Bool { !isBusy && !gameDirectory.isEmpty }
    var canPlay: Bool { !isBusy && setup.gameCheck.ok }   // missing components install on the way

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
        }
    }

    // MARK: - Blackwell Engine and D3DMetal

    /// Installs what is missing (Blackwell Engine, then D3DMetal once Apple's licence is accepted) and the shim.
    func installComponents() async {
        guard !isBusy else { return }
        let missing = Component.all().filter { component in
            !component.isInstalled && (component.id == "engine" ? engineDirectory.isEmpty : d3dmetalDirectory.isEmpty)
        }
        if missing.isEmpty && setup.shimReady { return }
        activity = .install
        defer { activity = .idle; installFraction = nil; objectWillChange.send() }
        do {
            for component in missing {
                try await Installer.install(component, confirm: { [weak self] license in
                    await self?.askLicense(license) ?? false
                }, progress: { [weak self] fraction, text in
                    Task { @MainActor in self?.installFraction = fraction; self?.status = text }
                })
            }
            let current = setup
            if fileExists(current.engine + "/renderers/tsshim/x86_64-windows/d3d12.dll"),
               fileExists(current.d3dmetal + "/wine/x86_64-windows/d3d12.dll") {
                try Installer.prepareShim(engine: current.engine, d3dmetal: current.d3dmetal)
            }
            status = setup.gameCheck.ok ? "Ready." : "Blackwell Engine and D3DMetal are installed. Download the game."
        } catch {
            status = "\(error)"
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

    private func refreshSavedAccountStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let saved = xboxAccountSaved()
            Task { @MainActor in self?.accountSaved = saved }
        }
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
            Task { @MainActor in self?.readLoginStatus() }
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

    // MARK: - Download and Play

    func download() {
        guard canDownload, let cli = Bundle.main.resourceURL?.appendingPathComponent("xodus-cli") else { return }
        // xodus checks the licence on the signed-in account: only an owned game downloads.
        run(executable: cli, arguments: ["streaming", storeProductID, gameDirectory], environment: ["RUST_BACKTRACE": "1"],
            activity: .download, statusText: "Downloading Forza Horizon 6 from the Xbox servers…", logName: "download") { code in
            code == 0 ? "Download finished." : "The download stopped (error \(code)). See the activity log."
        }
    }

    func play() {
        guard canPlay else { return }
        if !setup.readyToPlay {
            Task {
                await installComponents()
                if setup.readyToPlay { startGame() }
            }
            return
        }
        startGame()
    }

    private func startGame() {
        guard let resources = Bundle.main.resourceURL else { return }
        run(executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [resources.appendingPathComponent("metalhorizon-play.sh").path],
            environment: setup.playEnvironment(resources: resources),
            activity: .game, statusText: "Playing. Quit from the game's menu; the cloud save uploads as it closes.",
            logName: "play") { code in
            code == 0 ? "Game closed." : "The game stopped (error \(code)). See the activity log."
        }
    }

    /// Stops a download or the sign-in; for the game, ends every Wine process of its prefix.
    func stop() {
        if activity == .game {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: setup.engine + "/bin/wineserver")
            kill.arguments = ["-k"]
            kill.environment = ProcessInfo.processInfo.environment.merging([
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

    private func run(executable: URL, arguments: [String], environment: [String: String], activity newActivity: Activity,
                     statusText: String, logName: String, finished: @escaping (Int32) -> String) {
        guard !isBusy else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logFile = logDirectory.appendingPathComponent("\(logName)-\(stamp).log")
        guard FileManager.default.createFile(atPath: logFile.path, contents: nil),
              let logHandle = try? FileHandle(forWritingTo: logFile) else {
            status = "Could not create the log in \(logDirectory.path)."
            return
        }
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.standardOutput = logHandle
        task.standardError = logHandle
        task.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process = task
        runLogFile = logFile
        runLogHandle = logHandle
        activity = newActivity
        status = statusText
        output = ""
        runOutputTimer?.invalidate()
        runOutputTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRunOutput() }
        }
        task.terminationHandler = { [weak self] done in
            DispatchQueue.main.async {
                guard let self else { return }
                self.runOutputTimer?.invalidate()
                self.runOutputTimer = nil
                try? self.runLogHandle?.close()
                self.runLogHandle = nil
                self.refreshRunOutput()
                self.activity = .idle
                self.process = nil
                self.status = finished(done.terminationStatus)
            }
        }
        do {
            try task.run()
        } catch {
            runOutputTimer?.invalidate()
            runOutputTimer = nil
            try? runLogHandle?.close()
            runLogHandle = nil
            process = nil
            activity = .idle
            status = "Could not start: \(error.localizedDescription)"
        }
    }

    private func refreshRunOutput() {
        guard let runLogFile, let contents = try? String(contentsOf: runLogFile, encoding: .utf8) else { return }
        let tail = String(contents.suffix(20_000))   // a download writes a lot of progress lines
        if output != tail { output = tail }
    }

    func revealLogs() { NSWorkspace.shared.open(logDirectory) }

}

// MARK: - Window

/// The status lights of macOS's own lists: green ready, yellow works with a caveat, red missing.
private func statusLight(_ check: Check) -> some View {
    let name = !check.ok ? NSImage.statusUnavailableName
        : (check.fix == nil ? NSImage.statusAvailableName : NSImage.statusPartiallyAvailableName)
    return Image(nsImage: NSImage(named: name) ?? NSImage())
}

struct LauncherView: View {
    @StateObject private var model: LauncherModel
    @State private var showAssistant = ProcessInfo.processInfo.environment["MH_SNAPSHOT_SHEET"] != nil
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    @MainActor init(model: LauncherModel? = nil) {
        _model = StateObject(wrappedValue: model ?? LauncherModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox(label: Text("Xbox Account")) {
                HStack(spacing: 8) {
                    statusLight(Check(ok: model.accountSaved, text: ""))
                    Text(model.accountSaved
                         ? "Signed in. The session is kept in the macOS Keychain."
                         : "Not signed in. You sign in on Microsoft's own page; MetalHorizon never sees your password.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(model.accountSaved ? "Sign In Again…" : "Sign In with Microsoft…") { model.connectMicrosoft() }
                        .disabled(model.isBusy)
                }
                .padding(6)
            }

            GroupBox(label: Text("Setup")) {
                VStack(alignment: .leading, spacing: 8) {
                    settingRow("Game folder:", model.setup.gameCheck, title: "Choose…", action: model.chooseGameDirectory)
                    settingRow("Engine:", model.setup.engineCheck, title: "Install",
                               action: model.setup.engineCheck.ok ? nil : { Task { await model.installComponents() } })
                    settingRow("D3DMetal 4:", model.setup.d3dmetalCheck, title: "Install…",
                               action: model.setup.d3dmetalCheck.ok ? nil : { Task { await model.installComponents() } })
                    HStack {
                        Spacer().frame(width: labelWidth + 8)
                        Toggle("Show the Metal performance HUD in the game", isOn: $model.metalHUD)
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(6)
            }

            HStack(spacing: 8) {
                if model.activity == .install, let fraction = model.installFraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(model.status)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                if model.isBusy {
                    Button(model.activity == .game ? "Force Quit" : "Stop") { model.stop() }
                        .help(model.activity == .game ? "Quit from the game's menu when you can: force-quitting skips the cloud save upload." : "")
                }
                Button("Download from Xbox") { model.download() }
                    .disabled(!model.canDownload)
                Button("Play") { model.play() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canPlay)
            }

            GroupBox(label: Text("Activity")) {
                ScrollView {
                    Text(model.output.isEmpty
                         ? "MetalHorizon installs Blackwell Engine and D3DMetal by itself. Sign in, download the game, then click Play."
                         : model.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(model.output.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(4)
                }
                .frame(minHeight: 110, maxHeight: .infinity)
            }

            HStack {
                Button("Show Logs in Finder") { model.revealLogs() }
                Button("AI Assistant…") { showAssistant = true }
                Spacer()
                Text("MetalHorizon \(version) · prototype · not affiliated with Microsoft or Apple")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(20)
        .sheet(isPresented: $showAssistant) { AssistantSheet() }
        .sheet(isPresented: Binding(get: { model.licenseText != nil }, set: { if !$0 { model.answerLicense(false) } })) {
            LicenseSheet(text: model.licenseText ?? "", answer: model.answerLicense)
        }
    }

    private let labelWidth: CGFloat = 92

    private func settingRow(_ label: String, _ check: Check, title: String, action: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: labelWidth, alignment: .trailing)
            statusLight(check)
            Text(check.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(check.fix ?? check.text)
            Spacer(minLength: 8)
            if let action {
                Button(title, action: action)
                    .disabled(model.isBusy)
            }
        }
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
            }
        }
        .padding(20)
        .frame(width: 600)
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
            Text("MetalHorizon includes an MCP server. An assistant such as Claude can then check your setup, read the logs (tokens and e-mail addresses removed), explain errors and change MetalHorizon's settings with you. It never sees your password and cannot start the game or a download.")
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
            }
        }
        .padding(20)
        .frame(width: 560)
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
