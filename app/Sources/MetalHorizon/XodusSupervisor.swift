import AppKit
import Foundation
import Network

// MetalHorizon's half of the robustness of xodus and the Xbox connection (docs/XODUS-ROBUSTNESS.md, D and E). The
// other half is xodus-cli itself (patches/xodus-cli/0008): it retries, resumes, never panics, and says where it is
// and why it stops on `status` and `error` lines, which this file reads.

// MARK: - xodus' lines

/// A line xodus-cli prints for the app (with XODUS_PROGRESS=lines), besides the `progress` lines.
enum XodusLine: Equatable {
    /// The step: package, index, licence, files, finishing, paused, or `resume <files done>`.
    case status(String)
    /// Why it stopped: no-space, not-owned, signed-out, keychain, network, disk, package, clock or other.
    case error(kind: String, message: String)

    /// Left out of the activity log: the message is printed for people just before an error line.
    static let patterns = [#"^status [a-z]+( \d+)?$"#, #"^error [a-z-]+( .*)?$"#]

    static func parse(_ line: String) -> XodusLine? {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("status ") {
            let phase = String(text.dropFirst("status ".count))
            return phase.isEmpty ? nil : .status(phase)
        }
        if text.hasPrefix("error ") {
            let rest = text.dropFirst("error ".count)
            guard !rest.isEmpty else { return nil }
            guard let space = rest.firstIndex(of: " ") else { return .error(kind: String(rest), message: "") }
            return .error(kind: String(rest[..<space]), message: String(rest[rest.index(after: space)...]))
        }
        return nil
    }
}

enum XodusMessages {
    /// What the window says for a step, or nil to keep what it says (the files: the bar shows them).
    static func phase(_ phase: String) -> String? {
        if phase.hasPrefix("resume "), let files = Int(phase.dropFirst("resume ".count)) {
            return "Resuming the download: \(files) files are already there…"
        }
        switch phase {
        case "package": return "Asking Xbox for the game's package…"
        case "index": return "Reading the package's index (about 1 GB)…"
        case "licence": return "Checking the game's licence on your account…"
        case "files": return "Downloading Forza Horizon 6 from the Xbox servers…"
        case "finishing": return "Finishing the download…"
        default: return nil
        }
    }

    /// The failures no retry fixes: the window says what to do instead.
    static let finalKinds: Set<String> = ["no-space", "not-owned", "signed-out", "keychain", "clock", "disk", "package"]

    /// What the window says when xodus stopped for `kind`, with the next step.
    static func failure(kind: String, detail: String, folder: String) -> String {
        switch kind {
        case "no-space":
            if let space = DownloadProgress.notEnoughSpace(detail) {
                return DownloadProgress.notEnoughSpaceMessage(need: space.need, free: space.free, folder: folder)
            }
            return "The disk is full: free some space, then press Download the Game. The download resumes where it was."
        case "not-owned":
            return "This Microsoft account does not own Forza Horizon 6, or its Game Pass plan does not include PC games. "
                + "Sign in with the account that owns it (Settings › General › Xbox account › Sign In Again), then Download the Game."
        case "signed-out":
            return "Xbox no longer accepts the saved sign-in: press Sign In Again, then Download the Game. What is downloaded stays."
        case "keychain":
            return "macOS's Keychain did not let MetalHorizon use your Xbox sign-in. Press Download the Game again and, when "
                + "macOS asks about \"Xodus Service\", choose Always Allow."
        case "clock":
            return detail.isEmpty
                ? "This Mac's clock is off and Microsoft refuses its sign-in: turn on Set time and date automatically in System Settings › General › Date & Time."
                : detail
        case "disk":
            return "The game's folder could not be written (\(detail)). Choose another folder, then Download the Game."
        case "package":
            return "Xbox sent something unexpected for the game's package (\(detail)). Try again later; if it keeps happening, Report an Issue."
        case "network":
            return "The Xbox servers could not be reached. Check the network; the download resumes where it was."
        default:
            return detail.isEmpty ? "The download stopped. See the activity log." : detail
        }
    }
}

// MARK: - The download

/// What to do when xodus-cli's download ends.
enum DownloadDecision: Equatable {
    case finished(String)
    case paused(String)
    case retry(after: TimeInterval, String)
    /// xodus ended without error but the game is not all there: resume once to fetch what is missing.
    case fetchMissing(String)
    case failed(String)
}

/// What is known when a download ends.
struct DownloadEnd {
    var exitCode: Int32
    var gameReady: Bool
    var log: [String]
    var folder: String
    var retriesDone: Int = 0
    var userStopped = false
    var stalled = false
    var missingFetched = false
}

/// Keeps a download going: the Mac awake, a resume after a transient failure (once the network is back), a restart
/// when nothing moves for too long, and Stop as a pause.
@MainActor
final class DownloadSupervisor {
    static let shared = DownloadSupervisor()

    /// The pauses before the automatic resumes: 30 s, then 1, 2, 4 and 8 minutes.
    nonisolated static let retryDelays: [TimeInterval] = [30, 60, 120, 240, 480]
    /// Without a progress line for this long while the files download, xodus is restarted.
    nonisolated static let stallLimit: TimeInterval = 600
    /// Before the files (the package's index, the licence) xodus prints no progress: a longer limit then.
    nonisolated static let quietLimit: TimeInterval = 1800

    private(set) var retriesDone = 0
    private(set) var missingFetched = false
    private(set) var userStopped = false
    private(set) var stalled = false
    private var filesStarted = false
    private var lastSign = Date()
    private var interrupt: (() -> Void)?
    private var watchdog: Timer?
    private var awake: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    nonisolated static func decide(_ end: DownloadEnd) -> DownloadDecision {
        if end.userStopped {
            return .paused("Download paused. Press Download the Game to resume it: what is downloaded stays.")
        }
        if let space = end.log.lazy.compactMap(DownloadProgress.notEnoughSpace).last {
            return .failed(DownloadProgress.notEnoughSpaceMessage(need: space.need, free: space.free, folder: end.folder))
        }
        if end.exitCode == 0 && end.gameReady { return .finished("Download finished.") }
        let lastError = end.log.reversed().lazy.compactMap { line -> (kind: String, message: String)? in
            if case let .error(kind, message)? = XodusLine.parse(line) { return (kind, message) }
            return nil
        }.first
        if let lastError, XodusMessages.finalKinds.contains(lastError.kind) {
            return .failed(XodusMessages.failure(kind: lastError.kind, detail: lastError.message, folder: end.folder))
        }
        if end.exitCode == 0 {
            return end.missingFetched
                ? .failed(DownloadProgress.outcome(exitCode: 0, gameReady: false, log: end.log, folder: end.folder))
                : .fetchMissing("The download ended without the whole game: MetalHorizon resumes it once to fetch what is missing…")
        }
        guard end.retriesDone < retryDelays.count else {
            let why = lastError.map { XodusMessages.failure(kind: $0.kind, detail: $0.message, folder: end.folder) }
                ?? "The download stopped (error \(end.exitCode))."
            return .failed("\(why) MetalHorizon resumed it \(retryDelays.count) times already: press Download the Game to try again. What is downloaded stays.")
        }
        let delay = end.stalled ? 5 : retryDelays[end.retriesDone]
        let why = end.stalled ? "nothing came for 10 minutes"
            : lastError?.kind == "network" ? "the Xbox servers could not be reached"
            : "error \(end.exitCode)"
        return .retry(after: delay, "The download stopped (\(why)). MetalHorizon resumes it in \(duration(delay)), where it was…")
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : "\(Int(seconds / 60)) min"
    }

    /// The player pressed Download the Game (not an automatic resume): the counts start again, the Mac stays awake.
    func begin() {
        cancelPending()
        retriesDone = 0
        missingFetched = false
        if awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                          reason: "Downloading Forza Horizon 6")
        }
    }

    /// xodus-cli started; `interrupt` asks it to stop cleanly (SIGINT).
    func started(interrupt: @escaping () -> Void) {
        userStopped = false
        stalled = false
        filesStarted = false
        lastSign = Date()
        self.interrupt = interrupt
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStall() }
        }
    }

    /// Something new came from xodus; `files` once the files download (progress lines then come twice a second).
    func sawSign(files: Bool) {
        lastSign = Date()
        if files { filesStarted = true }
    }

    /// Whether xodus has been silent for longer than its limit (the watchdog's test, apart for the tests).
    nonisolated static func isStalled(silentFor seconds: TimeInterval, filesStarted: Bool) -> Bool {
        seconds > (filesStarted ? stallLimit : quietLimit)
    }

    private func checkStall() {
        guard Self.isStalled(silentFor: Date().timeIntervalSince(lastSign), filesStarted: filesStarted),
              let interrupt else { return }
        stalled = true
        self.interrupt = nil
        interrupt()
    }

    /// Stop: xodus stops cleanly and keeps what is done (a pause, not an error).
    func stopRequested() {
        userStopped = true
        interrupt?()
    }

    /// xodus-cli ended. Unless a resume follows, the Mac may sleep again.
    func ended(resuming: Bool) {
        watchdog?.invalidate()
        watchdog = nil
        interrupt = nil
        if !resuming { release() }
    }

    /// After `delay`, once the network is there, `start` resumes the download.
    func scheduleResume(after delay: TimeInterval, missing: Bool, waiting: @escaping () -> Void, start: @escaping () -> Void) {
        if missing { missingFetched = true } else { retriesDone += 1 }
        cancelPending()
        let item = DispatchWorkItem { NetworkWatch.shared.whenOnline(waiting: waiting, start) }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancelPending() {
        pending?.cancel()
        pending = nil
        NetworkWatch.shared.cancelWait()
    }

    func release() {
        cancelPending()
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    var keepsTheMacAwake: Bool { awake != nil }
}

/// Whether the Mac has a network, and a way to wait for it.
final class NetworkWatch: @unchecked Sendable {
    static let shared = NetworkWatch()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private var waiting: (() -> Void)?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(online: path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "MetalHorizon.network"))
    }

    var isOnline: Bool { lock.withLock { online } }

    private func update(online value: Bool) {
        let ready: (() -> Void)? = lock.withLock {
            online = value
            guard value, let action = waiting else { return nil }
            waiting = nil
            return action
        }
        if let ready { DispatchQueue.main.async(execute: ready) }
    }

    /// `action` now when the Mac is online; else `waiting` now and `action` when the network comes back.
    func whenOnline(waiting: () -> Void, _ action: @escaping () -> Void) {
        let now: Bool = lock.withLock {
            if online { return true }
            self.waiting = action
            return false
        }
        if now { action() } else { waiting() }
    }

    func cancelWait() { lock.withLock { waiting = nil } }
}

enum DownloadPreflight {
    /// What stops a download before it starts, as the window says it; nil when it may start. (The room is checked
    /// apart, against the game's size.)
    static func problem(folder: String, accountSaved: Bool) -> String? {
        if !accountSaved {
            return "Sign in with Microsoft first: the download needs the Xbox account that owns the game."
        }
        if folder.contains("/Library/Mobile Documents/") {
            return "That folder is in iCloud Drive, which would upload the whole game: choose a folder outside it, such as ~/FH6."
        }
        var url = URL(fileURLWithPath: folder)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        if !FileManager.default.isWritableFile(atPath: url.path) {
            return "MetalHorizon cannot write in \(Setup.tildePath(url.path)): choose another folder for the game."
        }
        return nil
    }
}

/// xodus-cli's list of the files an interrupted download already wrote (`.xodus-streaming-done`).
enum ResumeJournal {
    static let name = ".xodus-streaming-done"

    static func filesDone(in folder: String) -> Int {
        guard let text = try? String(contentsOfFile: folder + "/" + name, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { $0.hasPrefix("done ") }.count
    }
}

// MARK: - The Xbox connection

enum SignInStates {
    /// The helper's end states: the sign-in is over whether or not its window is still open.
    static let end: Set<String> = ["complete", "cancelled", "exchange_rejected", "exchange_failed",
                                   "network_error", "keychain_denied", "device_error", "clock_wrong"]

    /// What the window says for a state of the sign-in helper.
    static func message(_ state: String) -> String? {
        switch state {
        case "starting": return "Preparing Xbox sign-in…"
        case "waiting_for_microsoft": return "Enter your Microsoft account in the sign-in window."
        case "received_response": return "Microsoft responded; checking the Xbox account…"
        case "exchange_pending": return "Exchanging the Microsoft response for Xbox access…"
        case "exchange_failed": return "Xbox token exchange failed; the sign-in window has stopped."
        case "approval_required": return "Microsoft requires an additional approval step."
        case "account_accepted": return "Xbox accepted the account; saving the sign-in…"
        case "complete": return "Xbox account connected."
        case "exchange_rejected": return "Microsoft sign-in returned a response Xbox could not accept."
        case "cancelled": return "Microsoft sign-in was cancelled."
        case "network_error": return "Microsoft could not be reached while signing in: check the network, then press Sign In again."
        case "keychain_denied":
            return "macOS's Keychain did not let MetalHorizon keep your sign-in: press Sign In again and choose Always Allow when macOS asks about \"Xodus Service\"."
        case "device_error": return "This Mac could not be registered with Microsoft: try Sign In again in a moment."
        case "clock_wrong":
            return "This Mac's clock is off and Microsoft refuses the sign-in: turn on Set time and date automatically in System Settings › General › Date & Time, then press Sign In again."
        default: return nil
        }
    }

    /// The messages a sign-in ends on by itself: finishSignIn keeps them instead of "the window closed…".
    static let terminalMessages: Set<String> = Set(
        ["exchange_rejected", "exchange_failed", "cancelled", "network_error", "keychain_denied", "device_error", "clock_wrong"]
            .compactMap(message))
}

/// A sign-in that shows no change for 15 minutes is ended, instead of "Signing In…" forever.
@MainActor
final class SignInWatch {
    static let shared = SignInWatch()
    static let limit: TimeInterval = 900
    private var lastState = ""
    private var lastChange = Date()

    func reset(now: Date = Date()) {
        lastState = ""
        lastChange = now
    }

    /// True once the sign-in has shown the same state for longer than `limit`.
    func stuck(state: String, now: Date = Date()) -> Bool {
        if state != lastState {
            lastState = state
            lastChange = now
            return false
        }
        return now.timeIntervalSince(lastChange) > Self.limit
    }
}

enum SignInPreflight {
    /// What stops a sign-in before its window opens, or nil. Blocking (up to about 6 s): off the main thread.
    static func problem() -> String? {
        let net = Sys.reachMicrosoft()
        return problem(online: net.online, skew: net.skew)
    }

    static func problem(online: Bool, skew: TimeInterval?) -> String? {
        if !online {
            return "Microsoft cannot be reached from this Mac: check the network, then press Sign In again."
        }
        if let skew, abs(skew) > 300 {
            return "This Mac's clock is \(Int(abs(skew) / 60)) minutes \(skew > 0 ? "ahead of" : "behind") Microsoft's, which "
                + "refuses the sign-in: turn on Set time and date automatically in System Settings › General › Date & Time, then press Sign In again."
        }
        return nil
    }
}

enum SignInHelper {
    static let bundleIdentifier = "org.xodus-gaming.xodus-cli"

    /// A sign-in window left from an earlier try is closed before a new one opens.
    static func closeLeftovers() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).forEach { $0.terminate() }
    }

    /// The status file of an earlier sign-in, and its half-written copy, removed.
    static func clearStatus(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: file.path + ".partial"))
    }
}

extension AccountCheck {
    private static let cacheLock = NSLock()
    private static var acceptedAt: Date?
    /// An accepted account is trusted this long: Play starts faster and asks Microsoft less.
    static let acceptedFor: TimeInterval = 300
    /// The pauses before asking again when Microsoft could not be reached.
    static let networkRetries: [TimeInterval] = [5, 15]

    /// The account check, asked again on a network failure (after 5 s, then 15 s), with an accepted verdict kept for
    /// 5 minutes. Blocking: off the main thread.
    static func checked(resources: URL?, now: Date = Date(),
                        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                        run: (URL?) -> AccountCheck? = AccountCheck.run) -> AccountCheck? {
        if let at = cacheLock.withLock({ acceptedAt }), now.timeIntervalSince(at) < acceptedFor { return .accepted }
        var result = run(resources)
        for pause in networkRetries {
            guard case .unreachable? = result else { break }
            sleep(pause)
            result = run(resources)
        }
        if result == .accepted { cacheLock.withLock { acceptedAt = now } }
        return result
    }

    /// A new sign-in, or a refusal seen elsewhere: the next check asks Microsoft.
    static func forget() { cacheLock.withLock { acceptedAt = nil } }
}
