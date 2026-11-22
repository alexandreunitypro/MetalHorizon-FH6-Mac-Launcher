import Foundation

// What a player can tell the developer, and what MetalHorizon adds to it. After a game, MetalHorizon asks how it ran:
// 5 stars, how far the game got, what worked, a comment. Tools › Report a Problem… sends the same at any time. In
// "Send Automatically" mode, each run's summary goes too (play time, error codes, engine). Nothing leaves the Mac
// without the player's click, except in that mode, which the player chooses (Settings › Feedback).
//
// A report never holds a name, an e-mail address, an account, a gamertag, an Xbox or Steam ID, or the Mac's user name:
// the comment and the texts go through MCPServer.redact, and the Mac is known only by an anonymous ID the player can
// renew. It is the JSON tools/reports-receiver takes (schema 1).

enum FeedbackKind: String, Codable {
    case session, feedback, problem, crash

    var title: String {
        switch self {
        case .session: return tr("Session summary")
        case .feedback: return tr("Rating")
        case .problem: return tr("Problem report")
        case .crash: return tr("Crash report")
        }
    }
}

/// How far the game got, in the player's words.
enum ReachedPoint: String, CaseIterable, Identifiable {
    case drove, menu, loading, black, never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .drove: return tr("I drove in the open world")
        case .menu: return tr("The main menu, no further")
        case .loading: return tr("Stuck on a loading screen")
        case .black: return tr("A black or frozen screen")
        case .never: return tr("The game did not open")
        }
    }
}

enum FeatureState: String, CaseIterable, Identifiable {
    case works, problem, untried
    var id: String { rawValue }

    var title: String {
        switch self {
        case .works: return tr("Works")
        case .problem: return tr("Problem")
        case .untried: return tr("Not tried")
        }
    }
}

/// What the survey asks about, for this edition and these settings.
struct FeedbackFeature: Identifiable, Hashable {
    let id: String
    let title: String

    static func list(edition: Edition, frameGeneration: Bool) -> [FeedbackFeature] {
        var list = [FeedbackFeature(id: "performance", title: tr("Smoothness")),
                    FeedbackFeature(id: "graphics", title: tr("Picture")),
                    FeedbackFeature(id: "sound", title: tr("Sound")),
                    FeedbackFeature(id: "controller", title: tr("Controller")),
                    FeedbackFeature(id: "online", title: tr("Online play"))]
        if edition == .xbox {
            list += [FeedbackFeature(id: "store", title: tr("Add-ons and VIP")),
                     FeedbackFeature(id: "picture", title: tr("Profile picture"))]
        }
        if frameGeneration { list.append(FeedbackFeature(id: "framegen", title: tr("Frame generation"))) }
        return list
    }
}

/// The player's answers. Everything is optional: the stars alone, or Send with nothing, are a report.
struct FeedbackAnswers: Equatable {
    var rating = 0
    var reached: ReachedPoint?
    var features: [String: FeatureState] = [:]
    var comment = ""
    var attachLogs = true
}

/// What the feedback window is about: the run that just ended, or a problem the player reports.
struct FeedbackRequest: Identifiable {
    let id = UUID()
    let kind: FeedbackKind
    let session: SessionInfo?
}

/// Whether MetalHorizon asks how the game ran after each run (the mode itself is CrashReport.mode).
enum FeedbackPreferences {
    static let askKey = "metalhorizon.feedback.askAfterGames"

    static var askAfterGames: Bool {
        get { settingsStore().object(forKey: askKey) as? Bool ?? true }
        set { settingsStore().set(newValue, forKey: askKey) }
    }
}

/// The anonymous ID that tells the developer two reports come from the same Mac, and nothing else. Renewable.
enum FeedbackIdentity {
    static let key = "metalhorizon.feedback.installation"

    static var installation: String {
        if let saved = settingsStore().string(forKey: key), UUID(uuidString: saved) != nil { return saved }
        return renew()
    }

    @discardableResult
    static func renew() -> String {
        let id = UUID().uuidString.lowercased()
        settingsStore().set(id, forKey: key)
        return id
    }
}

/// The time played with MetalHorizon on this Mac, and the runs.
enum PlayTotals {
    static let secondsKey = "metalhorizon.feedback.playSeconds"
    static let runsKey = "metalhorizon.feedback.runs"

    static var seconds: Int { settingsStore().integer(forKey: secondsKey) }
    static var runs: Int { settingsStore().integer(forKey: runsKey) }

    static func add(seconds played: Int) {
        guard played > 0 else { return }
        settingsStore().set(seconds + played, forKey: secondsKey)
        settingsStore().set(runs + 1, forKey: runsKey)
    }
}

enum FeedbackReport {
    /// The report, as tools/reports-receiver takes it.
    static func json(id: String = UUID().uuidString.lowercased(), kind: FeedbackKind, answers: FeedbackAnswers?,
                     session: SessionInfo?, setup: Setup, crash: CrashReport? = nil, now: Date = Date()) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let machine = Diagnostics.report(setup)
        let engineRecord = FileManager.default.contents(atPath: setup.engine + "/metalhorizon.json")
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let frameGeneration = FrameGenerationSettings.load()
        var report: [String: Any] = [
            "schema": 1,
            "id": id,
            "kind": kind.rawValue,
            "created": iso.string(from: now),
            "installation": FeedbackIdentity.installation,
            "app": ["version": Updater.currentVersion, "edition": setup.edition.rawValue,
                    "language": Bundle.main.preferredLocalizations.first ?? "en", "engine_channel": setup.engineChannel.rawValue],
            "mac": ["macos": machine["macos"] ?? "", "chip": machine["chip"] ?? "", "model": machine["model"] ?? "",
                    "memory_gb": machine["memory_gb"] ?? 0, "rosetta": machine["rosetta"] ?? false],
            "engine": ["name": engineRecord["name"] ?? "", "version": engineRecord["version"] ?? "",
                       "rosetta_line": setup.rosettaLineInEngine, "route_preference": setup.engineRoute.rawValue],
            "game": ["version": CrashReport.gameVersion(edition: setup.edition)],
            "options": ["hud": setup.metalHUD, "metalfx": setup.metalFX, "max_fps": setup.maxFPS,
                        "controllers": setup.controllerMode.rawValue, "plain_sync": setup.plainSync,
                        "frame_generation": frameGeneration.enabled ? frameGeneration.mode.rawValue : "off"],
            "totals": ["play_seconds": PlayTotals.seconds, "runs": PlayTotals.runs]
        ]
        if let session {
            report["session"] = ["id": session.id, "started": iso.string(from: session.date), "duration_s": session.duration ?? 0,
                                 "exit_code": session.exitCode.map { $0 as Any } ?? NSNull(), "user_stopped": session.userStopped,
                                 "route": session.route ?? ""]
            report["findings"] = session.findings.map { ["id": $0] }
        }
        if let answers {
            if answers.rating > 0 { report["rating"] = min(answers.rating, 5) }
            report["survey"] = ["reached": answers.reached?.rawValue ?? "",
                                "features": answers.features.filter { $0.value != .untried }.mapValues(\.rawValue)]
            let comment = MCPServer.redact(answers.comment.trimmingCharacters(in: .whitespacesAndNewlines))
            if !comment.isEmpty { report["comment"] = String(comment.prefix(5000)) }
            report["logs_attached"] = answers.attachLogs
        }
        if let crash {
            report["headline"] = crash.headline
            report["error"] = ["message": crash.message, "backtrace": crash.backtrace]
            report["findings"] = crash.findings.map { ["id": $0.issue.id, "title": $0.issue.title, "severity": "\($0.issue.severity)"] }
            report["logs_attached"] = true
        }
        return report
    }

    /// REPORT.md: the same, to read.
    static func summary(_ report: [String: Any]) -> String {
        func text(_ path: String...) -> String {
            var current: Any? = report
            for key in path { current = (current as? [String: Any])?[key] }
            if let s = current as? String { return s }
            if let n = current as? NSNumber { return n.stringValue }
            return ""
        }
        let kind = FeedbackKind(rawValue: text("kind"))?.title ?? text("kind")
        let rating = report["rating"] as? Int
        let stars = rating.map { String(repeating: "★", count: $0) + String(repeating: "☆", count: 5 - $0) }
        var out = "## \(kind)\(stars.map { ": \($0)" } ?? "")\n\n"
        out += "- MetalHorizon \(text("app", "version")), \(text("app", "edition")) edition, game \(text("game", "version"))\n"
        out += "- Engine: \(text("engine", "name")) \(text("engine", "version"))\((report["engine"] as? [String: Any])?["rosetta_line"] as? Bool == true ? " (Rosetta line)" : ""), channel \(text("app", "engine_channel"))\n"
        out += "- macOS \(text("mac", "macos")), \(text("mac", "chip")) (\(text("mac", "model"))), \(text("mac", "memory_gb")) GB\n"
        if report["session"] != nil {
            let seconds = Int(text("session", "duration_s")) ?? 0
            out += "- Run \(text("session", "id")): \(Self.duration(seconds)), route \(text("session", "route")), exit code \(text("session", "exit_code"))"
            out += ((report["session"] as? [String: Any])?["user_stopped"] as? Bool == true ? " (stopped by the player)" : "") + "\n"
        }
        out += "- Played with MetalHorizon on this Mac: \(Self.duration(Int(text("totals", "play_seconds")) ?? 0)) in \(text("totals", "runs")) runs\n\n"
        if let survey = report["survey"] as? [String: Any] {
            if let reached = ReachedPoint(rawValue: survey["reached"] as? String ?? "") { out += "**How far**: \(reached.title)\n\n" }
            if let features = survey["features"] as? [String: String], !features.isEmpty {
                out += "**What worked**: " + features.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n\n"
            }
        }
        let comment = text("comment")
        if !comment.isEmpty { out += "**Comment**\n\n" + comment.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n") + "\n\n" }
        let headline = text("headline")
        if !headline.isEmpty { out += "**Crash**: \(headline)\n```\n\(text("error", "message"))\n```\n\n" }
        if let findings = report["findings"] as? [[String: Any]], !findings.isEmpty {
            out += "**Recognized**: " + findings.compactMap { $0["id"] as? String }.joined(separator: ", ") + "\n"
        }
        return out
    }

    static func duration(_ seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600) h \(String(format: "%02d", (seconds % 3600) / 60)) min" }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}
