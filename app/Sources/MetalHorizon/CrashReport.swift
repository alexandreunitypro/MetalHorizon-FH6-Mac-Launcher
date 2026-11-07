import AppKit
import Foundation

// When a run ends in a crash, MetalHorizon says so: right away when the game closes, or at the next launch if the app
// was closed meanwhile. The player sees the error message itself (Wine's "Unhandled exception" line and the first
// frames of its backtrace, a macOS crash report, or what stopped the script), what Diagnostics recognized, and can
// send it all to the developer: everything needed to patch, with secrets removed.
//
// How it is sent: a diagnostics zip plus a report text. When the app carries a report endpoint
// (Resources/report-endpoint.json: {"kind": "discord", "url": "<webhook>"} or {"kind": "http", "url": "<https URL>"}),
// the report is uploaded there after the player clicks Send. Without one, a pre-filled GitHub issue opens and the zip
// is shown in Finder to drop into it. Nothing leaves the Mac without the player's click, except with the
// "Send automatically" setting, which only works with an endpoint.

enum CrashReportMode: String, CaseIterable, Identifiable {
    case ask, automatic, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ask: return "Ask Me"
        case .automatic: return "Send Automatically"
        case .never: return "Never"
        }
    }
}

struct CrashReport: Identifiable {
    let id: String               // the session, so one crash is reported once
    let kind: String
    let date: Date
    let exitCode: Int?
    let message: String          // the error itself, as the player would read it in Wine's or macOS's dialog
    let backtrace: [String]      // the first frames, when Wine printed them
    let findings: [Finding]
    let crashReports: [String]   // macOS crash report summaries from the run's time
    let gameVersion: String
    let sessionDirectory: URL

    var headline: String {
        findings.first(where: { $0.issue.severity == .error })?.issue.title
            ?? (message.isEmpty ? "The game stopped unexpectedly" : "The game crashed")
    }

    // MARK: Finding a crash to report

    static let reportedKey = "metalhorizon.crashReportsHandled"
    static let modeKey = "metalhorizon.crashReportMode"

    static var mode: CrashReportMode {
        get { CrashReportMode(rawValue: settingsStore().string(forKey: modeKey) ?? "") ?? .ask }
        set { settingsStore().set(newValue.rawValue, forKey: modeKey) }
    }

    static func markHandled(_ id: String) {
        var handled = settingsStore().stringArray(forKey: reportedKey) ?? []
        handled.append(id)
        settingsStore().set(Array(handled.suffix(100)), forKey: reportedKey)
    }

    /// The newest play run, when it crashed and was not reported or dismissed yet.
    static func pending(edition: Edition) -> CrashReport? {
        guard mode != .never else { return nil }
        let handled = Set(settingsStore().stringArray(forKey: reportedKey) ?? [])
        guard let session = LogStore.sessions().first(where: { $0.kind == "play" || $0.kind == "steam-play" }),
              !handled.contains(session.id),
              Date().timeIntervalSince(session.date) < 14 * 86_400 else { return nil }
        return make(session, edition: edition)
    }

    static func make(_ session: SessionInfo, edition: Edition) -> CrashReport? {
        let output = session.directory.appendingPathComponent("output.log")
        let game = session.directory.appendingPathComponent("game.log")
        let findings = Diagnostics.scan(files: [output, game])
        let text = tail(of: game, bytes: 3_000_000) + "\n" + tail(of: output, bytes: 500_000)
        let (message, backtrace) = errorMessage(in: text)
        let crashes = crashSummaries(since: session.date.addingTimeInterval(-60))
        let crashed = !message.isEmpty || !crashes.isEmpty || findings.contains { $0.issue.severity == .error && $0.issue.id != "stop-message" }
        // a stop before the game started (STOP: lines) is a setup problem: the Diagnosis box covers it
        let stoppedBeforeStart = text.contains("STOP: ") && !text.contains("== game started")
        guard crashed, !stoppedBeforeStart else { return nil }
        return CrashReport(id: session.id, kind: session.kind, date: session.date, exitCode: session.exitCode,
                           message: MCPServer.redact(message), backtrace: backtrace.map(MCPServer.redact), findings: findings,
                           crashReports: crashes.map(MCPServer.redact), gameVersion: gameVersion(edition: edition),
                           sessionDirectory: session.directory)
    }

    private static func tail(of url: URL, bytes: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Wine's crash message and backtrace (winedbg prints them to the game's output when the crash dialog is off,
    /// which the Play scripts arrange), else the last fatal line.
    static func errorMessage(in text: String) -> (String, [String]) {
        let lines = text.components(separatedBy: "\n").filter { !$0.contains("(retried)") && !$0.contains("(harmless)") }
        if let index = lines.lastIndex(where: { $0.contains("Unhandled exception:") || $0.range(of: #"wine: Unhandled (page fault|exception|illegal|division|stack overflow)"#, options: .regularExpression) != nil }) {
            var frames: [String] = []
            for line in lines[index...].dropFirst() where frames.count < 25 {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.range(of: #"^(=>)?\s*\d+\s+0x[0-9a-fA-F]+"#, options: .regularExpression) != nil { frames.append(trimmed) }
                else if !frames.isEmpty && trimmed.hasPrefix("Modules:") { break }
            }
            return (lines[index].trimmingCharacters(in: .whitespaces), frames)
        }
        let fatal = [#"Terminating app due to uncaught exception.*"#, #"Error Domain=com\.apple\.appleneuralengine.*"#,
                     #"msync_init Failed.*"#, #"Installation path is too long.*"#, #"panicked at .*"#, #"E:0-0-L-8"#,
                     #"Initialization failed"#]
        for pattern in fatal {
            if let line = lines.last(where: { $0.range(of: pattern, options: .regularExpression) != nil }) {
                return (line.trimmingCharacters(in: .whitespaces), [])
            }
        }
        return ("", [])
    }

    /// macOS crash reports of Wine, the game or xodus written since the run started.
    private static func crashSummaries(since: Date) -> [String] {
        let fm = FileManager.default
        let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let recent = ((try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { url in
                let name = url.lastPathComponent.lowercased()
                guard name.hasSuffix(".ips"), ["wine", "forza", "xodus"].contains(where: name.contains) else { return false }
                return ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= since
            }
        guard !recent.isEmpty else { return [] }
        return Array(MCPServer.recentCrashSummaries(limit: min(recent.count, 3)))
    }

    /// The game's version: the Xbox package's Identity Version, or Steam's build id.
    static func gameVersion(edition: Edition) -> String {
        let setup = Setup.load()
        switch edition {
        case .steam:
            return setup.steam.gameBuild.map { "Steam build \($0)" } ?? "Steam (no build found)"
        case .xbox:
            guard let text = try? String(contentsOfFile: setup.gameDirectory + "/appxmanifest.xml", encoding: .utf8),
                  let identity = text.range(of: #"<Identity [^>]*Version="([0-9.]+)""#, options: .regularExpression) else { return "Xbox (unknown version)" }
            let tag = String(text[identity])
            let version = tag.range(of: #"Version="[0-9.]+""#, options: .regularExpression).map { String(tag[$0]).dropFirst(9).dropLast() } ?? "?"
            return "Xbox \(version)"
        }
    }

    // MARK: The report

    /// Everything needed to patch: the error, the stack, what was recognized, versions, settings, the run's header.
    func text(setup: Setup) -> String {
        let report = Diagnostics.report(setup)
        let engineInfo = (FileManager.default.contents(atPath: setup.engine + "/metalhorizon.json"))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let header = (try? String(contentsOf: sessionDirectory.appendingPathComponent("output.log"), encoding: .utf8))?
            .components(separatedBy: "\n").prefix(30).filter { !$0.isEmpty }.joined(separator: "\n") ?? ""
        var out = """
            ## \(headline)

            **Error message**
            ```
            \(message.isEmpty ? "(no error line: see the logs)" : message)
            ```

            """
        if !backtrace.isEmpty {
            out += "**Backtrace (first frames)**\n```\n\(backtrace.joined(separator: "\n"))\n```\n\n"
        }
        if !findings.isEmpty {
            out += "**What MetalHorizon recognized**\n" + findings.prefix(6).map { "- \($0.issue.title) (`\($0.issue.id)`): `\($0.evidence.prefix(200))`" }.joined(separator: "\n") + "\n\n"
        }
        out += """
            **Versions**
            - MetalHorizon \(report["app_version"] ?? "?"), \(setup.edition.title) edition, game \(gameVersion)
            - Engine: \(engineInfo["name"] ?? "?") \(engineInfo["version"] ?? "?") (series \(String(describing: engineInfo["seriesSha256"] ?? "?").prefix(12)), commit \(String(describing: engineInfo["commit"] ?? "?").prefix(10)))
            - D3DMetal \(setup.d3dmetalVersion)
            - macOS \(report["macos"] ?? "?"), \(report["chip"] ?? "?") (\(report["model"] ?? "?")), \(report["memory_gb"] ?? "?") GB, Rosetta \(report["rosetta"] as? Bool == true ? "yes" : "no")
            - Options: HUD \(setup.metalHUD), controllers \(setup.controllerMode.rawValue), MetalFX \(setup.metalFX), frame cap \(setup.maxFPS), relaunch \(setup.autoRetry)
            - Run: \(id), exit code \(exitCode.map(String.init) ?? "?")

            **Run header**
            ```
            \(MCPServer.redact(header))
            ```

            """
        if !crashReports.isEmpty {
            out += "**macOS crash report**\n```\n\(crashReports.joined(separator: "\n----\n").prefix(6000))\n```\n"
        }
        return out
    }

    /// Writes the zip, then uploads it with the report to the endpoint, or opens a pre-filled GitHub issue.
    func send(setup: Setup) async -> String {
        let body = text(setup: setup)
        let zip: URL
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("metalhorizon-report-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try body.write(to: folder.appendingPathComponent("REPORT.md"), atomically: true, encoding: .utf8)
            zip = try Diagnostics.exportBundle(setup, to: folder)
        } catch {
            return "Could not write the report: \(error)"
        }
        if let endpoint = CrashReport.endpoint {
            do {
                try await CrashReport.upload(body: body, zip: zip, to: endpoint)
                CrashReport.markHandled(id)
                return "Report sent to the developer. Thank you!"
            } catch {
                // the endpoint failed: fall back to GitHub, nothing is lost
                CrashReport.openIssue(body: body, title: headline, zip: zip, setup: setup)
                CrashReport.markHandled(id)
                return "The report server did not answer (\(error.localizedDescription)); a GitHub issue opened instead. Drop the zip shown in Finder into it."
            }
        }
        CrashReport.openIssue(body: body, title: headline, zip: zip, setup: setup)
        CrashReport.markHandled(id)
        return "A GitHub issue opened with the report; drop the zip shown in Finder into it, then click Submit."
    }

    struct Endpoint: Decodable { let kind: String; let url: String }

    static var endpoint: Endpoint? {
        guard let url = Bundle.main.url(forResource: "report-endpoint", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
              endpoint.url.hasPrefix("https://") else { return nil }
        return endpoint
    }

    private static func upload(body: String, zip: URL, to endpoint: Endpoint) async throws {
        var request = URLRequest(url: URL(string: endpoint.url)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        let boundary = "MetalHorizon-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var data = Data()
        func field(_ name: String, _ value: String, type: String = "text/plain") {
            data += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\nContent-Type: \(type); charset=utf-8\r\n\r\n\(value)\r\n".utf8)
        }
        if endpoint.kind == "discord" {
            // Discord limits a message to 2000 characters; the whole report rides along as a file
            let short = String(body.prefix(1800))
            let payload = try JSONSerialization.data(withJSONObject: ["content": short, "allowed_mentions": ["parse": []]])
            field("payload_json", String(decoding: payload, as: UTF8.self), type: "application/json")
            data += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"REPORT.md\"\r\nContent-Type: text/markdown\r\n\r\n".utf8)
            data += Data(body.utf8) + Data("\r\n".utf8)
            data += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files[1]\"; filename=\"\(zip.lastPathComponent)\"\r\nContent-Type: application/zip\r\n\r\n".utf8)
        } else {
            field("report", body, type: "text/markdown")
            data += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"logs\"; filename=\"\(zip.lastPathComponent)\"\r\nContent-Type: application/zip\r\n\r\n".utf8)
        }
        data += try Data(contentsOf: zip) + Data("\r\n--\(boundary)--\r\n".utf8)
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw InstallError.tool("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
    }

    private static func openIssue(body: String, title: String, zip: URL, setup: Setup) {
        var components = URLComponents(string: "https://github.com/alexandreunitypro/MetalHorizon-FH6-Mac-Launcher/issues/new")!
        let text = body.count > 6000 ? String(body.prefix(6000)) + "\n\n(cut: the whole report is REPORT.md in the zip)" : body
        components.queryItems = [URLQueryItem(name: "title", value: "[crash] [\(setup.edition.rawValue)] \(title)"),
                                 URLQueryItem(name: "body", value: text + "\n\n**Logs**: attached zip (secrets removed).")]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        if let url = components.url { NSWorkspace.shared.open(url) }
        NSWorkspace.shared.activateFileViewerSelecting([zip])
    }
}
