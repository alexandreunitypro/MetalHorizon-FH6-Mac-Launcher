import Foundation

// MetalHorizon's MCP server: an AI assistant connects to it (stdio, newline-delimited JSON-RPC 2.0) to check the
// setup, recognize known errors in the logs, look at Steam, the controllers, the network and the Wine prefix, change
// MetalHorizon's settings with the user, and export a diagnostics bundle. It serves tools, resources (the setup, the
// known problems, the logs) and prompts (guided troubleshooting). It cannot start the game or a download, and it never
// reads the Keychain secrets; everything it returns goes through `redact`.

private struct RPCError: Error {
    var code: Int
    var message: String
}

private struct ToolError: Error {
    var message: String
}

private struct Tool {
    var name: String
    var title: String
    var description: String
    var properties: [String: Any] = [:]
    var required: [String] = []
    var readOnly = true
    var destructive = false
    var openWorld = false
    var handler: ([String: Any]) throws -> String

    var descriptor: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
            "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                            "idempotentHint": readOnly, "openWorldHint": openWorld]
        ]
    }
}

private struct Resource {
    var uri: String
    var name: String
    var description: String
    var mimeType: String
    var read: () throws -> String
}

enum MCPServer {
    private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    private static let xodusRuntimeDir = "/private/tmp/xodus-runtime-test"
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func run() -> Never {
        while let line = readLine() {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard let data = text.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            handle(message)
        }
        exit(0)
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func handle(_ message: [String: Any]) {
        guard let method = message["method"] as? String, let id = message["id"] else { return }   // notifications, replies
        let params = message["params"] as? [String: Any] ?? [:]
        do {
            send(["jsonrpc": "2.0", "id": id, "result": try dispatch(method, params)])
        } catch let error as RPCError {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
        } catch {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": "\(error)"]])
        }
    }

    /// One JSON-RPC request in, its result out: the stdio loop and the tests share it.
    static func respond(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        do { return ["result": try dispatch(method, params)] }
        catch let error as RPCError { return ["error": ["code": error.code, "message": error.message]] }
        catch { return ["error": ["code": -32603, "message": "\(error)"]] }
    }

    private static func dispatch(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": protocolVersions.contains(asked) ? asked : "2025-06-18",
                "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false],
                                 "resources": ["listChanged": false, "subscribe": false]],
                "serverInfo": ["name": "metalhorizon", "title": "MetalHorizon", "version": appVersion],
                "instructions": instructions
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": tools.map(\.descriptor)]
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                throw RPCError(code: -32602, message: "Unknown tool")
            }
            do {
                let text = try tool.handler(params["arguments"] as? [String: Any] ?? [:])
                return ["content": [["type": "text", "text": text]], "isError": false]
            } catch let error as ToolError {
                return ["content": [["type": "text", "text": error.message]], "isError": true]
            }
        case "prompts/list":
            return ["prompts": prompts.map { ["name": $0.name, "title": $0.title, "description": $0.description,
                                              "arguments": $0.arguments] }]
        case "prompts/get":
            guard let name = params["name"] as? String, let prompt = prompts.first(where: { $0.name == name }) else {
                throw RPCError(code: -32602, message: "Unknown prompt")
            }
            let args = params["arguments"] as? [String: String] ?? [:]
            return ["description": prompt.description,
                    "messages": [["role": "user", "content": ["type": "text", "text": prompt.text(args)]]]]
        case "resources/list":
            return ["resources": resources().map { ["uri": $0.uri, "name": $0.name, "description": $0.description, "mimeType": $0.mimeType] }]
        case "resources/templates/list":
            return ["resourceTemplates": [
                ["uriTemplate": "metalhorizon://sessions/{id}/{file}", "name": "A run's log",
                 "description": "output.log, game.log or summary.json of a session from list_sessions, secrets removed.",
                 "mimeType": "text/plain"]
            ]]
        case "resources/read":
            guard let uri = params["uri"] as? String else { throw RPCError(code: -32602, message: "uri is required") }
            let text = try readResource(uri)
            return ["contents": [["uri": uri, "mimeType": uri.hasSuffix(".json") || uri.hasSuffix("setup") ? "application/json" : "text/plain",
                                  "text": text]]]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Instructions for the assistant

    static let instructions = """
    MetalHorizon runs the user's own copy of Forza Horizon 6 on an Apple silicon Mac, from either edition:
    - Xbox / Microsoft Store: Wine (Blackwell Engine) + xodus (Xbox sign-in, download, licence) + Apple's D3DMetal 4 \
    behind Highball's DirectX 12 shim.
    - Steam: the same graphics stack on Blackwell Engine Steam (32-bit half, DXMT for Steam's own window), with Steam \
    itself in a prefix MetalHorizon manages; the game is launched by a silent Steam client (steam.exe -silent -applaunch).
    The app installs the engines and D3DMetal by itself (D3DMetal after the user accepts Apple's licence). \
    Nothing comes from CrossOver.app. You help the user set it up and debug it.

    How to help:
    - Start with check_setup (or diagnose when something went wrong). diagnose reads the newest runs' logs, matches \
    them against the known problems and returns causes and fixes in plain words.
    - When the user pastes an error, use explain_error. list_known_issues is the whole table.
    - Logs: list_sessions then read_session (output.log is the run, game.log the game's or Steam's own output; \
    errors_only cuts the noise). search_logs finds a message across runs. read_crash_reports summarizes macOS crash reports.
    - Steam edition: steam_status says whether Steam is installed, signed in once, running (window or game mode), \
    and whether the game is installed. steam_control can open or stop Steam's window when the user agrees.
    - Controllers: list_controllers shows what macOS sees and whether the game will get them (GameInput, engine patch 0012).
    - Network problems (downloads, sign-in, Steam's installer): network_check.
    - Settings: get_settings, then set_setting only after the user agrees. MetalHorizon must be reopened to show a \
    changed setting. show_play_environment shows what Play would run, without starting anything.
    - For a GitHub issue, export_diagnostics writes a zip with secrets removed; tell the user to attach it.
    - Answer in the user's language, in plain words, one step at a time; the user may be a beginner.

    Rules:
    - Never ask for a Microsoft or Steam password, a sign-in code or a token, and never repeat one. Signing in happens \
    only on Microsoft's page or in Steam's own window.
    - The logs come with tokens, e-mail addresses, XUIDs, Steam IDs and gamertags removed; do not try to recover them.
    - Do not help bypass the game's copy protection, licence check, Steam's DRM or the anti-cheat, or modify the \
    game's files. MetalHorizon's fixes live only in the compatibility layer. Online play is unofficial and carries a \
    risk for the account.
    - You cannot start the game or a download: ask the user to click Play or Download from Xbox. They should quit the \
    game from its own menu (Xbox edition: then wait about 30 seconds for the cloud save upload).
    """

    // MARK: - Tools

    private static let settingKeys = ["edition", "gameDirectory", "steamPrefix", "engineDirectory", "d3dmetalDirectory",
                                      "metalHUD", "controllerMode", "metalFX", "maxFPS", "autoRetry"]

    private static let tools: [Tool] = [
        Tool(name: "check_setup", title: "Check the setup",
             description: "Everything Play needs for the chosen edition, item by item (game or Steam library, engine, D3DMetal 4, DirectX 12 shim, Xbox account or Steam, Rosetta, macOS, memory, disk, app location), with a fix for each problem. Start here.",
             handler: { _ in checkSetup() }),
        Tool(name: "diagnose", title: "Diagnose the last runs",
             description: "Reads the newest runs' logs (or one session), matches them against MetalHorizon's known problems, adds the checks before Play, and returns each problem with its cause, the line that shows it and the fix.",
             properties: ["session": ["type": "string", "description": "A session id from list_sessions; default: the newest runs"],
                          "runs": ["type": "integer", "description": "How many recent runs to read (default 3, at most 10)"]],
             handler: diagnose),
        Tool(name: "explain_error", title: "Explain an error message",
             description: "Matches a message or log excerpt the user pasted (a dialog's text, a Terminal error, a log line) against the known problems and returns the explanation and the fix.",
             properties: ["text": ["type": "string", "description": "The error text, as pasted"]], required: ["text"],
             handler: explainError),
        Tool(name: "list_known_issues", title: "Known problems",
             description: "MetalHorizon's table of known problems: id, title, which edition, what it means and what to do. Optional filter.",
             properties: ["edition": ["type": "string", "enum": ["xbox", "steam", "any"]],
                          "query": ["type": "string", "description": "Keep the problems whose title or text contains this"]],
             handler: listKnownIssues),
        Tool(name: "get_troubleshooting_guide", title: "Troubleshooting guide",
             description: "The troubleshooting guide in prose: messages and symptoms of Forza Horizon 6 under MetalHorizon, for both editions, with causes and fixes.",
             handler: { _ in troubleshootingGuide }),
        Tool(name: "list_sessions", title: "List the runs",
             description: "MetalHorizon's runs (Play, downloads, Steam install/open/stop), newest first: id, kind, date, exit code and the known problems found in each.",
             properties: ["limit": ["type": "integer", "description": "At most this many (default 15)"]],
             handler: listSessions),
        Tool(name: "read_session", title: "Read a run's log",
             description: "One run's output.log (the script: versions, settings, steps, the error lines at the end) or game.log (the game's own output, or Steam's for the Steam edition), noise and secrets removed.",
             properties: ["id": ["type": "string", "description": "A session id from list_sessions, or 'latest'"],
                          "file": ["type": "string", "enum": ["output", "game", "summary"]],
                          "tail": ["type": "integer", "description": "Last lines to return (default 200, at most 3000)"],
                          "grep": ["type": "string", "description": "Keep only the lines with this text (case-insensitive)"],
                          "errors_only": ["type": "boolean", "description": "Keep only error lines"]],
             required: ["id"], handler: readSession),
        Tool(name: "search_logs", title: "Search the logs",
             description: "Finds a text or a regular expression in the recent runs' logs and MetalHorizon's other logs; returns the matching lines with where they are.",
             properties: ["pattern": ["type": "string", "description": "Text or regular expression (case-insensitive)"],
                          "runs": ["type": "integer", "description": "How many recent runs to search (default 10)"]],
             required: ["pattern"], handler: searchLogs),
        Tool(name: "list_logs", title: "List the other logs",
             description: "MetalHorizon's logs outside the runs (xodus-service.log, steam-window.log, steam-install.log...) and the macOS crash reports of Wine, the game and xodus, newest first. Pass an id to read_log.",
             handler: { _ in try listLogs() }),
        Tool(name: "read_log", title: "Read a log",
             description: "One log or crash report from list_logs, with secrets removed. Crash reports are summarized (exception, faulting thread).",
             properties: [
                "id": ["type": "string", "description": "The id from list_logs, such as logs/xodus-service.log or crash/wine64-preloader-2026-10-25-200000.ips"],
                "tail": ["type": "integer", "description": "Last lines to return (default 200, at most 2000)"],
                "grep": ["type": "string", "description": "Keep only the lines that contain this text (case-insensitive)"]
             ], required: ["id"], handler: readLog),
        Tool(name: "read_crash_reports", title: "Crash reports",
             description: "Summaries of the newest macOS crash reports for Wine, Forza Horizon 6, xodus and MetalHorizon: process, exception, faulting thread's frames.",
             properties: ["limit": ["type": "integer", "description": "At most this many (default 3)"]],
             handler: { args in
                 let summaries = recentCrashSummaries(limit: min(max(args["limit"] as? Int ?? 3, 1), 10))
                 return summaries.isEmpty ? "No crash report from Wine, the game, xodus or MetalHorizon." : redact(summaries.joined(separator: "\n\n----\n\n"))
             }),
        Tool(name: "last_crash_report", title: "Last crash report",
             description: "The newest game run that crashed, as the developer receives it: the error message (Wine's exception line and backtrace, a macOS crash report, or what stopped the run), what MetalHorizon recognized, the versions (app, engine series, D3DMetal, game build, macOS, chip) and the options. Secrets removed.",
             handler: { _ in
                 let setup = Setup.load()
                 guard let session = LogStore.sessions().first(where: { $0.kind == "play" || $0.kind == "steam-play" }) else {
                     return "No game run yet."
                 }
                 guard let report = CrashReport.make(session, edition: setup.edition) else {
                     return "The newest game run (\(session.id)) did not crash. diagnose and read_session show its logs."
                 }
                 return report.text(setup: setup)
             }),
        Tool(name: "export_diagnostics", title: "Export diagnostics",
             description: "Writes a zip on the Desktop for a GitHub issue: the setup report, the last runs' logs, xodus-service and Steam logs, crash summaries, all with secrets removed. Returns its path and a pre-filled issue link.",
             readOnly: false, handler: { _ in
                 let setup = Setup.load()
                 let url = try Diagnostics.exportBundle(setup)
                 let findings = LogStore.sessions().first.map { Diagnostics.scan(files: [$0.directory.appendingPathComponent("output.log"), $0.directory.appendingPathComponent("game.log")]) } ?? []
                 return json(["bundle": redact(url.path), "new_issue_link": Diagnostics.issueURL(setup, findings: findings).absoluteString,
                              "note": "Ask the user to attach the zip to the issue; it holds no password, token or e-mail address."])
             }),
        Tool(name: "show_play_environment", title: "Show what Play would run",
             description: "Runs the edition's Play script in dry-run mode with the current settings: the environment (GPU identity, d3d12 and D3DMetal paths, sync mode, controllers, options) and the command, or the first STOP message that would block Play. Starts nothing.",
             handler: { _ in try showPlayEnvironment() }),
        Tool(name: "get_system_info", title: "System information",
             description: "The Mac: macOS version, chip, memory, Rosetta, free space where the game is, where MetalHorizon runs from (Applications, translocated, quarantined), Steam for macOS running.",
             handler: { _ in systemInfo() }),
        Tool(name: "network_check", title: "Check the network",
             description: "Reaches the servers MetalHorizon needs (GitHub for the engines, Microsoft and Xbox Live for the Xbox edition, Valve's installer mirrors and Steam for the Steam edition) and reports each answer, its time, and certificate errors like the 'no alternative certificate subject name' a filtering network causes.",
             properties: ["scope": ["type": "string", "enum": ["all", "xbox", "steam", "components"]]],
             openWorld: true, handler: networkCheck),
        Tool(name: "check_components", title: "Check the components",
             description: "The installed Blackwell Engine (Xbox and Steam variants) and D3DMetal against what this app version pins: versions, and what each engine carries (32-bit half, SDL2 for controllers, GameInput, DXMT, GnuTLS, FreeType).",
             handler: { _ in checkComponents() }),
        Tool(name: "find_engines", title: "Find Wine engines",
             description: "Looks on this Mac for Wine engines (folders with bin/wine) and says which can run the game.",
             handler: { _ in findEngines() }),
        Tool(name: "find_d3dmetal", title: "Find D3DMetal",
             description: "Looks on this Mac for Apple's D3DMetal (mounted Game Porting Toolkit, Downloads, Applications) and gives each copy's version; the game needs version 4.",
             handler: { _ in findD3DMetal() }),
        Tool(name: "steam_status", title: "Steam status",
             description: "Steam edition: the prefix, whether Steam is installed and was signed in to once (no account name), whether it runs (window or game mode), and Forza Horizon 6's state in the library (installed, downloading, build).",
             handler: { _ in steamStatus() }),
        Tool(name: "steam_control", title: "Open or stop Steam",
             description: "Steam edition: opens Steam's window (DXMT, sync off; a client in game mode is restarted first when no game runs) or stops Steam cleanly with its own -shutdown. Ask the user first. It cannot start the game.",
             properties: ["action": ["type": "string", "enum": ["open", "stop"]]], required: ["action"],
             readOnly: false, destructive: true, handler: steamControl),
        Tool(name: "list_controllers", title: "Controllers",
             description: "The game controllers macOS sees (pads, wheels, sticks; name, vendor, USB or Bluetooth), the controller setting, whether the next Play turns GameInput on for them, and whether the engine has SDL2 (PlayStation, Switch and generic pads).",
             handler: { _ in listControllers() }),
        Tool(name: "prefix_info", title: "Wine prefix",
             description: "The edition's Wine prefix: where it is, whether it has a 32-bit system folder, its DLL overrides, the programs running in it, and its size on disk.",
             handler: { _ in prefixInfo() }),
        Tool(name: "get_settings", title: "Settings",
             description: "All of MetalHorizon's settings with their current values.",
             handler: { _ in getSettings() }),
        Tool(name: "set_setting", title: "Change a setting",
             description: "Sets one of MetalHorizon's settings after checking the value. Keys: edition (xbox/steam), gameDirectory, steamPrefix, engineDirectory, d3dmetalDirectory (folders; \"default\" goes back to MetalHorizon's own), metalHUD, metalFX, autoRetry (true/false), controllerMode (automatic/on/off), maxFPS (0 for none). Ask the user first. MetalHorizon must be reopened to show the change.",
             properties: [
                "key": ["type": "string", "enum": settingKeys],
                "value": ["type": "string", "description": "A folder path (~ allowed), true/false, a number, or an enum value"]
             ], required: ["key", "value"], readOnly: false, handler: setSetting),
        Tool(name: "xodus_service", title: "xodus-service",
             description: "Xbox edition: status, start or stop of xodus-service, the helper that holds the Xbox sign-in and gives the game its tokens. Without it: 'Cloud save synchronization failed' and no online play. Do not stop it while the game runs.",
             properties: ["action": ["type": "string", "enum": ["status", "start", "stop"]]],
             required: ["action"], readOnly: false, destructive: true, handler: xodusService)
    ]

    // MARK: Setup and checks

    private static func row(_ item: String, _ check: Check) -> [String: Any] {
        var r: [String: Any] = ["item": item, "status": !check.ok ? "problem" : (check.fix == nil ? "ok" : "warning"),
                                "detail": redact(check.text)]
        if let fix = check.fix { r["fix"] = fix }
        return r
    }

    private static func checkSetup() -> String {
        let setup = Setup.load()
        var checks: [[String: Any]] = []
        switch setup.edition {
        case .xbox:
            checks.append(row("game folder", setup.gameCheck))
            let saved = xboxAccountSaved()
            checks.append(row("Xbox account", saved ? Check(ok: true, text: "saved in the Keychain")
                : Check(ok: false, text: "not signed in", fix: "Click Sign In with Microsoft… in the app and sign in on Microsoft's page.")))
        case .steam:
            checks.append(row("Steam", setup.steamClientCheck))
            checks.append(row("Forza Horizon 6 in Steam", setup.steamGameCheck))
        }
        checks.append(row("engine", setup.engineCheck))
        checks.append(row("D3DMetal 4", setup.d3dmetalCheck))
        checks.append(row("DirectX 12 shim", setup.shimReady ? Check(ok: true, text: "assembled in " + shimDirectory)
            : Check(ok: false, text: "not assembled yet", fix: "The app assembles it once the engine and D3DMetal are installed: open MetalHorizon.")))
        let preflight = Diagnostics.preflight(setup).map { row($0.title, $0.check) }
        var result: [String: Any] = [
            "app": ["version": appVersion, "executable": redact(Bundle.main.executablePath ?? "")],
            "edition": setup.edition.rawValue,
            "ready_to_play": setup.readyToPlay && (setup.edition == .steam || xboxAccountSaved()),
            "checks": checks,
            "before_play": preflight,
            "running_processes": runningProcesses(),
            "components": Component.all().map { ["name": $0.name, "version": $0.version, "installed": $0.installedVersion ?? "no"] }
        ]
        if setup.edition == .xbox {
            let service = serviceState()
            result["xodus_service"] = ["running": service.running, "socket": xodusRuntimeDir + "/xodus.sock"]
        }
        return json(result)
    }

    private static func findingRow(_ finding: Finding) -> [String: Any] {
        ["id": finding.issue.id, "severity": finding.issue.severity.rawValue, "title": finding.issue.title,
         "cause": finding.issue.explanation, "fix": finding.issue.fix, "evidence": finding.evidence,
         "seen_in": finding.source, "times": finding.count]
    }

    private static func diagnose(_ args: [String: Any]) throws -> String {
        let setup = Setup.load()
        var sessions = LogStore.sessions()
        if let id = args["session"] as? String, !id.isEmpty, id != "latest" {
            sessions = sessions.filter { $0.id == id }
            guard !sessions.isEmpty else { throw ToolError(message: "No session \(id); take one from list_sessions.") }
        } else {
            sessions = Array(sessions.prefix(min(max(args["runs"] as? Int ?? 3, 1), 10)))
        }
        var runs: [[String: Any]] = []
        for session in sessions {
            let findings = Diagnostics.scan(files: [session.directory.appendingPathComponent("output.log"),
                                                    session.directory.appendingPathComponent("game.log")])
            runs.append(["session": session.id, "kind": session.kind, "exit_code": session.exitCode as Any? ?? NSNull(),
                         "problems": findings.map(findingRow)])
        }
        var extra = [String]()
        for name in ["xodus-service.log", "steam-window.log", "steam-install.log"] {
            let url = logDirectory.appendingPathComponent(name)
            for finding in Diagnostics.scan(files: [url]) { extra.append("\(name): \(finding.issue.title) — \(finding.issue.fix)") }
        }
        let preflight = Diagnostics.preflight(setup).filter { $0.severity > .info }.map { row($0.title, $0.check) }
        return json(["edition": setup.edition.rawValue, "before_play": preflight, "runs": runs, "other_logs": extra,
                     "note": runs.isEmpty ? "No run yet: ask the user to click Play (or Install Steam) once, then diagnose again." : ""])
    }

    private static func explainError(_ args: [String: Any]) throws -> String {
        guard let text = args["text"] as? String, !text.isEmpty else { throw ToolError(message: "text is required") }
        let findings = Diagnostics.scan(text: text, source: "pasted text")
        if findings.isEmpty {
            return "No known problem matches this text. Ask the user for the whole message and when it appears, then use diagnose or search_logs; get_troubleshooting_guide lists the symptoms MetalHorizon knows."
        }
        return json(findings.map(findingRow))
    }

    private static func listKnownIssues(_ args: [String: Any]) throws -> String {
        let edition = (args["edition"] as? String).flatMap(Edition.init(rawValue:))
        let query = (args["query"] as? String ?? "").lowercased()
        let rows = Diagnostics.issues.filter { issue in
            (edition == nil || issue.edition == nil || issue.edition == edition)
                && (query.isEmpty || "\(issue.title) \(issue.explanation) \(issue.fix) \(issue.id)".lowercased().contains(query))
        }.map { issue -> [String: Any] in
            ["id": issue.id, "title": issue.title, "edition": issue.edition?.rawValue ?? "both", "severity": issue.severity.rawValue,
             "cause": issue.explanation, "fix": issue.fix]
        }
        return json(["count": rows.count, "issues": rows])
    }

    // MARK: Logs

    private static func listSessions(_ args: [String: Any]) throws -> String {
        let limit = min(max(args["limit"] as? Int ?? 15, 1), 40)
        let formatter = ISO8601DateFormatter()
        let rows = LogStore.sessions().prefix(limit).map { s -> [String: Any] in
            ["id": s.id, "kind": s.kind, "date": formatter.string(from: s.date), "size": s.bytes,
             "exit_code": s.exitCode as Any? ?? NSNull(), "problems": s.findings]
        }
        return json(["sessions": rows, "folder": redact(LogStore.sessionsDirectory.path)])
    }

    private static func sessionDirectory(_ id: String) throws -> URL {
        let sessions = LogStore.sessions()
        if id == "latest", let first = sessions.first { return first.directory }
        guard !id.contains("/"), !id.hasPrefix("."), let match = sessions.first(where: { $0.id == id }) else {
            throw ToolError(message: "No session \(id); take one from list_sessions.")
        }
        return match.directory
    }

    private static func readText(_ url: URL, maxBytes: UInt64 = 6_000_000) -> (String, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        return (String(decoding: handle.readDataToEndOfFile(), as: UTF8.self), size > maxBytes)
    }

    private static func readSession(_ args: [String: Any]) throws -> String {
        guard let id = args["id"] as? String else { throw ToolError(message: "id is required") }
        let dir = try sessionDirectory(id)
        let file = args["file"] as? String ?? "output"
        let url = dir.appendingPathComponent(file == "summary" ? "summary.json" : "\(file).log")
        guard let (text, cut) = readText(url) else { throw ToolError(message: "\(dir.lastPathComponent) has no \(url.lastPathComponent)") }
        if file == "summary" { return redact(text) }
        var lines = LogFilter.apply(text.components(separatedBy: "\n"), errorsOnly: args["errors_only"] as? Bool ?? false,
                                    search: args["grep"] as? String ?? "")
        let tail = min(max(args["tail"] as? Int ?? 200, 1), 3000)
        let total = lines.count
        lines = Array(lines.suffix(tail))
        return redact("\(dir.lastPathComponent)/\(url.lastPathComponent): last \(lines.count) of \(total) lines after filtering\(cut ? " (from the last 6 MB)" : "")\n"
                      + lines.joined(separator: "\n"))
    }

    private static func searchLogs(_ args: [String: Any]) throws -> String {
        guard let pattern = args["pattern"] as? String, !pattern.isEmpty else { throw ToolError(message: "pattern is required") }
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        func matches(_ line: String) -> Bool {
            if let regex { return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil }
            return line.range(of: pattern, options: .caseInsensitive) != nil
        }
        var files: [(String, URL)] = []
        for session in LogStore.sessions().prefix(min(max(args["runs"] as? Int ?? 10, 1), 40)) {
            files.append(("\(session.id)/output.log", session.directory.appendingPathComponent("output.log")))
            files.append(("\(session.id)/game.log", session.directory.appendingPathComponent("game.log")))
        }
        for name in ["xodus-service.log", "steam-window.log", "steam-install.log", "steam-prefix.log", "steam-forward.log"] {
            files.append((name, logDirectory.appendingPathComponent(name)))
        }
        var hits: [String] = []
        for (label, url) in files {
            guard let (text, _) = readText(url, maxBytes: 3_000_000) else { continue }
            for line in text.components(separatedBy: "\n") where !LogFilter.isNoise(line) && matches(line) {
                hits.append("\(label): \(line.prefix(400))")
                if hits.count >= 150 { break }
            }
            if hits.count >= 150 { break }
        }
        return hits.isEmpty ? "Nothing matches \(pattern) in the recent logs." : redact("\(hits.count) lines\(hits.count >= 150 ? " (first 150)" : ""):\n" + hits.joined(separator: "\n"))
    }

    private static func listLogs() throws -> String {
        let fm = FileManager.default
        func entries(_ dir: URL, prefix: String, keep: (String) -> Bool, limit: Int) -> [[String: Any]] {
            let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            return urls.filter { keep($0.lastPathComponent) }
                .compactMap { url -> (Date, [String: Any])? in
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let date = values?.contentModificationDate ?? .distantPast
                    return (date, ["id": prefix + url.lastPathComponent, "size": values?.fileSize ?? 0,
                                   "modified": ISO8601DateFormatter().string(from: date)])
                }
                .sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        }
        let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let crashes = (entries(reports, prefix: "crash/", keep: isOurCrash, limit: 15)
                       + entries(reports.appendingPathComponent("Retired"), prefix: "crash/", keep: isOurCrash, limit: 15))
        return json(["metalhorizon_logs": entries(logDirectory, prefix: "logs/", keep: { $0.hasSuffix(".log") }, limit: 30),
                     "crash_reports": Array(crashes.prefix(20)),
                     "note": "Each run has its own folder: use list_sessions and read_session for those."])
    }

    private static func isOurCrash(_ name: String) -> Bool {
        name.hasSuffix(".ips") && ["wine", "forza", "xodus", "metalhorizon", "steam"].contains { name.lowercased().contains($0) }
    }

    private static func readLog(_ args: [String: Any]) throws -> String {
        guard let id = args["id"] as? String else { throw ToolError(message: "id is required") }
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[1].contains("/"), !parts[1].hasPrefix(".") else {
            throw ToolError(message: "Unknown id; take one from list_logs.")
        }
        let reports = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let candidates: [URL]
        switch parts[0] {
        case "logs": candidates = [logDirectory.appendingPathComponent(parts[1])]
        case "crash": candidates = [reports.appendingPathComponent(parts[1]), reports.appendingPathComponent("Retired/" + parts[1])]
        default: throw ToolError(message: "Unknown id; take one from list_logs.")
        }
        guard let url = candidates.first(where: { fileExists($0.path) }) else { throw ToolError(message: "No such log: \(id)") }
        let tail = min(max(args["tail"] as? Int ?? 200, 1), 2000)
        if parts[0] == "crash", let summary = crashSummary(url) { return redact(summary) }
        guard let (text, cut) = readText(url, maxBytes: 5_000_000) else { throw ToolError(message: "Cannot read \(id)") }
        var lines = text.components(separatedBy: "\n").filter { !LogFilter.isNoise($0) }
        if let grep = args["grep"] as? String, !grep.isEmpty {
            lines = lines.filter { $0.range(of: grep, options: .caseInsensitive) != nil }
        }
        let shown = lines.suffix(tail)
        return redact("\(id): last \(shown.count) of \(lines.count) lines\(cut ? " (from the last 5 MB)" : "")\n" + shown.joined(separator: "\n"))
    }

    /// The newest crash reports of ours, summarized.
    static func recentCrashSummaries(limit: Int) -> [String] {
        let fm = FileManager.default
        let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let urls = [reports, reports.appendingPathComponent("Retired")].flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { isOurCrash($0.lastPathComponent) }
        }
        let dated = urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).compactMap { crashSummary($0.0) }
    }

    /// A macOS .ips crash report in a few lines: process, exception, termination, faulting thread's frames.
    private static func crashSummary(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let split = text.firstIndex(of: "\n") else { return nil }
        let header = (try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8))) as? [String: Any] ?? [:]
        guard let body = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: split)...].utf8))) as? [String: Any] else { return nil }
        var out = ["Process: \(body["procName"] ?? header["app_name"] ?? "?")  time: \(header["timestamp"] ?? body["captureTime"] ?? "?")  file: \(url.lastPathComponent)"]
        if let exception = body["exception"] { out.append("Exception: \(compact(exception))") }
        if let termination = body["termination"] { out.append("Termination: \(compact(termination))") }
        if let asi = body["asi"] { out.append("Application info: \(compact(asi).prefix(600))") }
        let images = body["usedImages"] as? [[String: Any]] ?? []
        if let threads = body["threads"] as? [[String: Any]] {
            let index = body["faultingThread"] as? Int ?? 0
            if index < threads.count {
                out.append("Faulting thread \(index)\(threads[index]["name"].map { " (\($0))" } ?? ""):")
                for frame in (threads[index]["frames"] as? [[String: Any]] ?? []).prefix(25) {
                    let image = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                    let symbol = frame["symbol"] as? String ?? ""
                    out.append("  \(image) +\(frame["imageOffset"] ?? "?") \(symbol)")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Environment, system, network

    private static func showPlayEnvironment() throws -> String {
        guard let resources = Bundle.main.resourceURL else { throw ToolError(message: "No resources folder.") }
        let setup = Setup.load()
        let gameInput = Controllers.gameInputEnabled(mode: setup.controllerMode, connected: Controllers.connected())
        let (script, args, env): (String, [String], [String: String])
        switch setup.edition {
        case .xbox:
            script = resources.appendingPathComponent("metalhorizon-play.sh").path
            args = [script]
            env = setup.playEnvironment(resources: resources, gameInput: gameInput)
        case .steam:
            script = resources.appendingPathComponent("metalhorizon-steam.sh").path
            args = [script, "play"]
            env = setup.steamEnvironment(gameInput: gameInput)
        }
        guard fileExists(script) else { throw ToolError(message: "This copy of MetalHorizon has no Play script (development build?).") }
        var dry = env
        dry["MH_DRY_RUN"] = "1"
        let (code, output) = shell("/bin/bash", args, env: dry)
        return redact((code == 0 ? "Play (\(setup.edition.title)) would run with:\n" : "Play would stop (exit \(code)):\n") + output)
    }

    private static func systemInfo() -> String {
        let setup = Setup.load()
        let location = Diagnostics.appLocation
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let target = setup.edition == .steam ? setup.steamPrefixPath : (setup.gameDirectory.isEmpty ? home : setup.gameDirectory)
        return json([
            "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "macos_ok_for_d3dmetal4": os.majorVersion >= 27,
            "model": Diagnostics.sysctlValue("hw.model"),
            "chip": Diagnostics.sysctlValue("machdep.cpu.brand_string"),
            "memory_gb": Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            "rosetta_installed": Diagnostics.rosettaInstalled,
            "free_gb_where_the_game_is": Diagnostics.freeSpace(at: target).map { Int($0 / 1_000_000_000) } as Any? ?? NSNull(),
            "app_path": redact(location.path),
            "app_translocated": location.translocated,
            "app_quarantined": location.quarantined,
            "steam_for_macos_running": Diagnostics.nativeSteamRunning()
        ])
    }

    private static func networkCheck(_ args: [String: Any]) throws -> String {
        let scope = args["scope"] as? String ?? "all"
        var targets: [(String, String, String)] = []   // group, what, url
        if scope == "all" || scope == "components" {
            targets += [("components", "GitHub releases (engines, D3DMetal)", "https://github.com/alexandreunitypro/blackwell-engine/releases"),
                        ("components", "GitHub downloads", "https://objects.githubusercontent.com/")]
        }
        if scope == "all" || scope == "xbox" {
            targets += [("xbox", "Microsoft sign-in", "https://login.live.com/"),
                        ("xbox", "Xbox Live user authentication", "https://user.auth.xboxlive.com/"),
                        ("xbox", "Xbox Live XSTS", "https://xsts.auth.xboxlive.com/"),
                        ("xbox", "PlayFab (cloud saves)", "https://playfabapi.com/")]
        }
        if scope == "all" || scope == "steam" {
            targets += [("steam", "Steam installer (Akamai)", "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"),
                        ("steam", "Steam installer (media)", "https://media.steampowered.com/client/installer/SteamSetup.exe"),
                        ("steam", "Steam installer (Cloudflare)", "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"),
                        ("steam", "cdn.steampowered.com (often filtered)", "https://cdn.steampowered.com/download/SteamSetup.exe"),
                        ("steam", "Steam store", "https://store.steampowered.com/"),
                        ("steam", "Steam client updates", "https://client-update.steamstatic.com/")]
        }
        var rows: [[String: Any]] = []
        for (group, what, url) in targets {
            let (code, output) = shell("/usr/bin/curl", ["-sS", "-I", "-L", "--max-time", "12", "-o", "/dev/null",
                                                        "-w", "%{http_code} %{time_total} %{content_type}", url], timeout: 15)
            let parts = output.split(separator: "\n").last.map(String.init) ?? ""
            let fields = parts.split(separator: " ").map(String.init)
            var row: [String: Any] = ["group": group, "server": what, "url": url]
            if code == 0, let http = fields.first {
                row["http"] = http
                row["seconds"] = fields.count > 1 ? fields[1] : ""
                if fields.count > 2, url.hasSuffix(".exe"), fields[2].contains("html") {
                    row["problem"] = "answered with a web page instead of the installer (a filtering network or a wrong edge server)"
                }
            } else {
                row["error"] = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if output.contains("(60)") || output.contains("certificate") {
                    row["problem"] = "certificate mismatch: something on this network answers for this server (VPN, proxy, captive portal, DNS filter)"
                } else if output.contains("(6)") {
                    row["problem"] = "the name does not resolve (DNS)"
                } else if output.contains("(28)") {
                    row["problem"] = "timed out"
                }
            }
            rows.append(row)
        }
        return json(["checks": rows, "note": "cdn.steampowered.com failing alone is expected on some networks; MetalHorizon uses Valve's other mirrors."])
    }

    // MARK: Components, Steam, controllers, prefix

    private static func engineFeatures(_ path: String) -> [String: Any] {
        guard fileExists(path + "/bin/wine") else { return ["installed": false] }
        let version = (FileManager.default.contents(atPath: path + "/metalhorizon.json"))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["version"] as? String ?? "?"
        let gameInput = (try? Data(contentsOf: URL(fileURLWithPath: path + "/lib/wine/x86_64-windows/gameinput.dll")))
            .map { $0.range(of: Data("WINE_GAMEINPUT".utf8)) != nil } ?? false
        return ["installed": true, "path": redact(path), "version": version,
                "xbox_runtime": fileExists(path + "/lib/wine/x86_64-windows/xgameruntime.dll"),
                "gnutls": fileExists(path + "/lib/libgnutls.30.dylib"), "freetype": fileExists(path + "/lib/libfreetype.6.dylib"),
                "sdl2_controllers": fileExists(path + "/lib/libSDL2-2.0.0.dylib"), "gameinput": gameInput,
                "32bit_half": fileExists(path + "/lib/wine/i386-windows/ntdll.dll"),
                "dxmt": fileExists(path + "/renderers/dxmt/wine/x86_64-windows/dxgi.dll"),
                "dx12_shim": fileExists(path + "/renderers/tsshim/x86_64-windows/d3d12.dll")]
    }

    private static func checkComponents() -> String {
        let setup = Setup.load()
        return json([
            "pinned_by_this_app": Component.all().map { ["id": $0.id, "version": $0.version, "installed": $0.installedVersion ?? "no",
                                                         "up_to_date": $0.isInstalled] },
            "blackwell_engine": engineFeatures(installedEngineDirectory),
            "blackwell_engine_steam": engineFeatures(installedSteamEngineDirectory),
            "custom_engine": setup.engineDirectory.isEmpty ? "none" : engineFeatures(setup.engineDirectory) as Any,
            "d3dmetal": ["version": setup.d3dmetalVersion, "ok": setup.d3dmetalCheck.ok],
            "shim_assembled": setup.shimReady,
            "note": "Missing or outdated components install when MetalHorizon opens or with Install on a red line."
        ])
    }

    private static func steamStatus() -> String {
        let setup = Setup.load()
        let files = setup.steam
        var result: [String: Any] = [
            "edition_selected": setup.edition.rawValue,
            "prefix": redact(setup.steamPrefixPath),
            "prefix_is_metalhorizons_own": setup.steamPrefix.isEmpty,
            "steam_installed": files.installed,
            "signed_in_once": files.signedInOnce,
            "game_in_library": files.manifest != nil,
            "game_installed": files.gameInstalled,
            "game_downloading_or_updating": files.gameDownloading,
            "game_build": files.gameBuild ?? "",
            "appid": steamAppID
        ]
        if let script = Bundle.main.resourceURL?.appendingPathComponent("metalhorizon-steam.sh").path, fileExists(script) {
            let (_, output) = shell("/bin/bash", [script, "status"], env: setup.steamEnvironment())
            let status = SteamStatus.parse(output)
            result["client_running"] = status.clientRunning
            result["client_mode"] = status.clientMode
            result["game_running"] = status.gameRunning
            result["engine_32bit"] = status.engine32bit
            result["engine_dxmt"] = status.engineDXMT
        }
        return json(result)
    }

    private static func steamControl(_ args: [String: Any]) throws -> String {
        guard let action = args["action"] as? String, ["open", "stop"].contains(action) else { throw ToolError(message: "action is open or stop") }
        let setup = Setup.load()
        guard setup.edition == .steam else { throw ToolError(message: "The edition is Xbox; Steam is only used by the Steam edition (set_setting edition steam).") }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("metalhorizon-steam.sh").path, fileExists(script) else {
            throw ToolError(message: "This copy of MetalHorizon has no Steam script (development build?).")
        }
        let (code, output) = shell("/bin/bash", [script, action], env: setup.steamEnvironment(), timeout: 120)
        return redact((code == 0 ? "" : "exit \(code)\n") + output)
    }

    private static func listControllers() -> String {
        let setup = Setup.load()
        let connected = Controllers.connected()
        return json([
            "connected": connected.map { ["name": $0.name, "kind": $0.kind, "vendor_id": String(format: "0x%04x", $0.vendorID),
                                          "product_id": String(format: "0x%04x", $0.productID), "transport": $0.transport,
                                          "how_the_game_gets_it": $0.route] },
            "setting": setup.controllerMode.rawValue,
            "gameinput_on_next_play": Controllers.gameInputEnabled(mode: setup.controllerMode, connected: connected),
            "engine_has_sdl2": fileExists(setup.engine + "/lib/libSDL2-2.0.0.dylib"),
            "note": "Forza Horizon 6 reads pads through GameInput (engine patch 0012, on when a pad is connected in Automatic). Wine's own panel (Tools › Test Controllers in Wine) shows what Wine sees."
        ])
    }

    private static func prefixInfo() -> String {
        let setup = Setup.load()
        let prefix = setup.prefix
        var overrides: [String] = []
        if let text = try? String(contentsOfFile: prefix + "/user.reg", encoding: .utf8),
           let start = text.range(of: "[Software\\\\Wine\\\\DllOverrides]") {
            for line in text[start.upperBound...].split(separator: "\n").dropFirst().prefix(80) {
                if line.hasPrefix("[") { break }
                if line.hasPrefix("\"") { overrides.append(String(line)) }
            }
        }
        let real = URL(fileURLWithPath: prefix).resolvingSymlinksInPath().path
        let (_, lsof) = shell("/usr/sbin/lsof", ["-a", "-d", "cwd", "-u", String(getuid()), "-Fpn"])
        var running: [String] = []
        var pid = ""
        for line in lsof.split(separator: "\n") {
            if line.hasPrefix("p") { pid = String(line.dropFirst()) }
            if line.hasPrefix("n"), (String(line.dropFirst()) + "/").hasPrefix(real + "/") {
                let (_, command) = shell("/bin/ps", ["-ww", "-o", "command=", "-p", pid])
                running.append("\(pid) \(command.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))")
            }
        }
        let (_, du) = shell("/usr/bin/du", ["-sh", prefix], timeout: 20)
        return redact(json([
            "edition": setup.edition.rawValue, "prefix": prefix, "exists": fileExists(prefix + "/system.reg"),
            "has_32bit_system": fileExists(prefix + "/drive_c/windows/syswow64/ntdll.dll"),
            "dll_overrides": overrides, "running": running,
            "size": du.split(separator: "\t").first.map(String.init) ?? "?",
            "steam_mode_marker": (try? String(contentsOfFile: prefix + "/.metalhorizon-steam-mode", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]))
    }

    // MARK: Settings

    private static func getSettings() -> String {
        let s = Setup.load()
        return json([
            "edition": s.edition.rawValue, "gameDirectory": redact(s.gameDirectory),
            "steamPrefix": s.steamPrefix.isEmpty ? "(MetalHorizon's own: \(redact(defaultSteamPrefix)))" : redact(s.steamPrefix),
            "engineDirectory": s.engineDirectory.isEmpty ? "(installed Blackwell Engine)" : redact(s.engineDirectory),
            "d3dmetalDirectory": s.d3dmetalDirectory.isEmpty ? "(installed D3DMetal)" : redact(s.d3dmetalDirectory),
            "metalHUD": s.metalHUD, "controllerMode": s.controllerMode.rawValue, "metalFX": s.metalFX,
            "maxFPS": s.maxFPS, "autoRetry": s.autoRetry
        ])
    }

    private static func setSetting(_ args: [String: Any]) throws -> String {
        guard let key = args["key"] as? String, let raw = args["value"] as? String else { throw ToolError(message: "key and value are required") }
        let store = settingsStore()
        var setup = Setup.load()
        func bool(_ storeKey: String) throws -> String {
            guard ["true", "false"].contains(raw.lowercased()) else { throw ToolError(message: "\(key) takes true or false") }
            store.set(raw.lowercased() == "true", forKey: storeKey)
            return "\(key) = \(raw.lowercased()). Reopen MetalHorizon to see it."
        }
        switch key {
        case "metalHUD": return try bool(SettingKey.metalHUD)
        case "metalFX": return try bool(SettingKey.metalFX)
        case "autoRetry": return try bool(SettingKey.autoRetry)
        case "edition":
            guard let edition = Edition(rawValue: raw.lowercased()) else { throw ToolError(message: "edition is xbox or steam") }
            store.set(edition.rawValue, forKey: SettingKey.edition)
            return "edition = \(edition.rawValue). Reopen MetalHorizon: it installs that edition's engine by itself."
        case "controllerMode":
            guard let mode = ControllerMode(rawValue: raw.lowercased()) else { throw ToolError(message: "controllerMode is automatic, on or off") }
            store.set(mode.rawValue, forKey: SettingKey.controllerMode)
            return "controllerMode = \(mode.rawValue)."
        case "maxFPS":
            guard let fps = Int(raw), fps == 0 || (15...240).contains(fps) else { throw ToolError(message: "maxFPS is 0 (no cap) or 15 to 240") }
            store.set(fps, forKey: SettingKey.maxFPS)
            return "maxFPS = \(fps)."
        case "gameDirectory", "steamPrefix", "engineDirectory", "d3dmetalDirectory":
            let storeKey = [SettingKey.gameDirectory, SettingKey.steamPrefix, SettingKey.engineDirectory, SettingKey.d3dmetalDirectory][
                ["gameDirectory", "steamPrefix", "engineDirectory", "d3dmetalDirectory"].firstIndex(of: key)!]
            if key != "gameDirectory", raw.isEmpty || raw.lowercased() == "default" {
                store.removeObject(forKey: storeKey)
                return "\(key) reset to MetalHorizon's own. Reopen MetalHorizon to see it."
            }
            var path = expandTilde(raw)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                throw ToolError(message: "Not a folder: \(raw)")
            }
            let check: Check
            switch key {
            case "gameDirectory":
                setup.gameDirectory = path; check = setup.xboxGameCheck
                store.set(path, forKey: storeKey)
            case "steamPrefix":
                setup.steamPrefix = path; check = setup.steamClientCheck
                store.set(path, forKey: storeKey)
            case "engineDirectory":
                path = Setup.normalizeEngine(path); setup.engineDirectory = path; check = setup.engineCheck
                guard fileExists(path + "/bin/wine") else { throw ToolError(message: "No bin/wine in \(path): not an engine. Nothing changed.") }
                store.set(path, forKey: storeKey)
            default:
                path = Setup.normalizeD3DMetal(path); setup.d3dmetalDirectory = path; check = setup.d3dmetalCheck
                guard fileExists(path + "/external/libd3dshared.dylib"), fileExists(path + "/wine/x86_64-windows/d3d12.dll") else {
                    throw ToolError(message: "\(path) is not Apple's redist/lib folder (external/ and wine/). Nothing changed.")
                }
                store.set(path, forKey: storeKey)
            }
            store.synchronize()
            return json(["set": key, "value": redact(path), "status": !check.ok ? "problem" : (check.fix == nil ? "ok" : "warning"),
                         "detail": redact(check.text), "fix": check.fix ?? "", "note": "Reopen MetalHorizon to see the change."])
        default:
            throw ToolError(message: "Unknown key \(key)")
        }
    }

    // MARK: xodus-service

    private static func serviceState() -> (running: Bool, pids: [String]) {
        let pids = shell("/usr/bin/pgrep", ["-f", "xodus-service$"]).1.split(separator: "\n").map(String.init)
        return (fileExists(xodusRuntimeDir + "/xodus.sock") && !pids.isEmpty, pids)
    }

    private static func xodusService(_ args: [String: Any]) throws -> String {
        let action = args["action"] as? String ?? "status"
        let logFile = logDirectory.appendingPathComponent("xodus-service.log").path
        switch action {
        case "status":
            let state = serviceState()
            return state.running ? "xodus-service is running (pid \(state.pids.joined(separator: ", "))), socket \(xodusRuntimeDir)/xodus.sock."
                : "xodus-service is not running\(state.pids.isEmpty ? "" : " properly: process \(state.pids.joined(separator: ", ")) without its socket")."
        case "start":
            if serviceState().running { return "xodus-service is already running." }
            guard let binary = Bundle.main.resourceURL?.appendingPathComponent("xodus-service").path, fileExists(binary) else {
                throw ToolError(message: "This copy of MetalHorizon has no xodus-service (development build?).")
            }
            try? FileManager.default.createDirectory(atPath: xodusRuntimeDir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            try? FileManager.default.removeItem(atPath: xodusRuntimeDir + "/xodus.sock")
            // Detached through nohup so it outlives this server, like metalhorizon-play.sh starts it.
            _ = shell("/bin/sh", ["-c", "cd /tmp && XODUS_RUNTIME_DIR=\"$1\" XODUS_LOG=info nohup \"$0\" > \"$2\" 2>&1 &",
                                  binary, xodusRuntimeDir, logFile])
            for _ in 0..<30 where !fileExists(xodusRuntimeDir + "/xodus.sock") { Thread.sleep(forTimeInterval: 1) }
            return serviceState().running
                ? "xodus-service started. If macOS asks to let it use the 'Xodus Service' Keychain item, the user should choose Always Allow."
                : "xodus-service did not open its socket within 30 s. Read logs/xodus-service.log."
        case "stop":
            let state = serviceState()
            for pid in state.pids { _ = shell("/bin/kill", [pid]) }
            try? FileManager.default.removeItem(atPath: xodusRuntimeDir + "/xodus.sock")
            return state.pids.isEmpty ? "xodus-service was not running." : "xodus-service stopped."
        default:
            throw ToolError(message: "action is status, start or stop")
        }
    }

    // MARK: - Resources

    private static func resources() -> [Resource] {
        var list = [
            Resource(uri: "metalhorizon://setup", name: "Setup report", description: "check_setup's report: what is ready and what is missing.",
                     mimeType: "application/json", read: { checkSetup() }),
            Resource(uri: "metalhorizon://known-issues", name: "Known problems", description: "Every known problem with its signs, cause and fix.",
                     mimeType: "text/markdown", read: { knownIssuesMarkdown() }),
            Resource(uri: "metalhorizon://guide", name: "Troubleshooting guide", description: "The troubleshooting guide in prose.",
                     mimeType: "text/markdown", read: { troubleshootingGuide })
        ]
        for session in LogStore.sessions().prefix(5) {
            for file in ["output", "game"] {
                list.append(Resource(uri: "metalhorizon://sessions/\(session.id)/\(file)", name: "\(session.kind) \(file) (\(session.id.prefix(19)))",
                                     description: "\(file).log of the \(session.kind) run, noise and secrets removed.", mimeType: "text/plain",
                                     read: { try readSession(["id": session.id, "file": file, "tail": 800]) }))
            }
        }
        return list
    }

    private static func readResource(_ uri: String) throws -> String {
        if let fixed = resources().first(where: { $0.uri == uri }) { return try fixed.read() }
        let prefix = "metalhorizon://sessions/"
        guard uri.hasPrefix(prefix) else { throw RPCError(code: -32002, message: "Resource not found: \(uri)") }
        let parts = uri.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard parts.count == 2, ["output", "game", "summary"].contains(parts[1]) else { throw RPCError(code: -32002, message: "Resource not found: \(uri)") }
        do { return try readSession(["id": parts[0], "file": parts[1], "tail": 800]) }
        catch let error as ToolError { throw RPCError(code: -32002, message: error.message) }
    }

    private static func knownIssuesMarkdown() -> String {
        var out = "# MetalHorizon: known problems\n"
        for issue in Diagnostics.issues {
            out += "\n## \(issue.title) (`\(issue.id)`, \(issue.edition?.title ?? "both editions"), \(issue.severity.rawValue))\n"
            out += "- Cause: \(issue.explanation)\n- Fix: \(issue.fix)\n"
        }
        return out
    }

    // MARK: - Helpers

    /// Runs a program and returns its exit code and output; it is stopped after `timeout` seconds.
    private static func shell(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 30) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        do { try task.run() } catch { return (-1, "\(error)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if task.isRunning { task.terminate() } }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func runningProcesses() -> [String] {
        let wanted = ["forzahorizon6", "wineserver", "xodus-service", "xodus-cli", "xodus-login", "steam.exe", "steamwebhelper"]
        return shell("/bin/ps", ["-axo", "pid=,comm="]).1.split(separator: "\n").compactMap { line in
            let name = (line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "")
            guard let match = wanted.first(where: { name.lowercased().contains($0) }) else { return nil }
            return "\(line.split(separator: " ").first ?? "?") \(match)"
        }
    }

    private static func findEngines() -> String {
        var servers = shell("/usr/bin/mdfind", ["kMDItemFSName == 'wineserver'"], timeout: 15).1
            .split(separator: "\n").map(String.init)
        let current = Setup.load().engine
        for dir in [current, installedEngineDirectory, installedSteamEngineDirectory, home + "/BlackwellEngine-build/out/engine",
                    home + "/BlackwellEngine-build-steam/out/engine"] where !dir.isEmpty {
            servers.append(dir + "/bin/wineserver")
        }
        var seen = Set<String>()
        var found: [[String: Any]] = []
        for server in servers where server.hasSuffix("/bin/wineserver") {
            let engine = String(server.dropLast("/bin/wineserver".count))
            guard fileExists(engine + "/bin/wine"), seen.insert(engine).inserted else { continue }
            var features = engineFeatures(engine)
            let crossover = engine.contains("CrossOver.app")
            let xbox = features["xbox_runtime"] as? Bool ?? false
            let own = (features["gnutls"] as? Bool ?? false) && (features["freetype"] as? Bool ?? false)
            features["current"] = engine == current
            features["suitable_xbox"] = xbox && own && !crossover
            features["suitable_steam"] = xbox && own && !crossover && (features["32bit_half"] as? Bool ?? false)
            features["note"] = crossover ? "CrossOver's own Wine: no Xbox runtime, cannot run the game"
                : (!xbox ? "no xgameruntime.dll: not Blackwell Engine" : (!own ? "an older engine that needs CrossOver.app's GnuTLS and FreeType" : "ok"))
            found.append(features)
            if found.count == 20 { break }
        }
        return json(["engines": found,
                     "note": found.contains { $0["suitable_xbox"] as? Bool == true } ? "Pass a suitable path to set_setting engineDirectory, or keep the installed ones (recommended)."
                        : "No suitable engine found. MetalHorizon installs Blackwell Engine by itself."])
    }

    private static func findD3DMetal() -> String {
        var libraries = shell("/usr/bin/mdfind", ["kMDItemFSName == 'libd3dshared.dylib'"], timeout: 15).1
            .split(separator: "\n").map(String.init)
        libraries += shell("/usr/bin/find", [home + "/Downloads", "/Applications", home + "/Applications", "-maxdepth", "8",
                                             "-name", "libd3dshared.dylib"], timeout: 20).1.split(separator: "\n").map(String.init)
        if let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            libraries += volumes.map { "/Volumes/\($0)/redist/lib/external/libd3dshared.dylib" }
        }
        let current = Setup.load().d3dmetal
        libraries.append(current + "/external/libd3dshared.dylib")
        var seen = Set<String>()
        var found: [[String: Any]] = []
        for library in libraries where library.hasSuffix("/libd3dshared.dylib") && fileExists(library) {
            // Apple's layout: <lib>/external/libd3dshared.dylib next to <lib>/wine (the d3d12 halves)
            let dir = URL(fileURLWithPath: library).deletingLastPathComponent().deletingLastPathComponent().path
            guard seen.insert(dir).inserted else { continue }
            let setup = Setup(d3dmetalDirectory: dir)
            let version = setup.d3dmetalVersion
            let halves = fileExists(dir + "/wine/x86_64-windows/d3d12.dll")
            found.append(["path": redact(dir), "version": version.isEmpty ? "?" : version, "has_wine_halves": halves,
                          "suitable": version.hasPrefix("4.") && halves, "current": dir == current,
                          "inside_crossover": dir.contains("CrossOver.app")])
            if found.count == 20 { break }
        }
        return json(["d3dmetal": found,
                     "note": found.contains { $0["suitable"] as? Bool == true } ? "Pass a suitable path to set_setting d3dmetalDirectory."
                        : "No D3DMetal 4 here. MetalHorizon downloads it by itself after the user accepts Apple's licence in the app (Install… on the D3DMetal line)."])
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "\(object)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func compact(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(object)" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let redactions: [(NSRegularExpression, String)] = [
        (#"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_.-]{8,}"#, "<token removed>"),                        // JWTs
        (#"XBL3\.0 x=[^;\s]+;[^\s"',]+"#, "XBL3.0 x=<removed>"),                                   // Xbox Live authorization
        (#"(?i)((?:access_|refresh_|user_|device_|title_)?token|bearer|secret|password|authorization|signature|proofkey|cookie)(["']?\s*[:=]\s*["']?)[^\s"',}]{12,}"#, "$1$2<removed>"),
        (#"[A-Za-z0-9+_=-]{80,}"#, "<long value removed>"),                                       // blobs, keys (not paths: no /)
        (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "<e-mail>"),
        (#"\b2535\d{12}\b"#, "<xuid>"),
        (#"\b7656119\d{10}\b"#, "<steamid>"),                                                      // SteamID64
        (#"(?i)(-steamid=|steamid["']?\s*[:=]\s*["']?)\d{5,}"#, "$1<steamid>"),
        (#"(?i)("AccountName"\s*")[^"]+"#, "$1<account>"),                                           // loginusers.vdf
        (#"(?i)("PersonaName"\s*")[^"]+"#, "$1<name>"),
        (#"(?i)(gamertag["']?\s*[:=]?\s*["'])[^"']+"#, "$1<gamertag>"),
        (#"(?i)(Bienvenue,?|Welcome,?|欢迎，?)\s*[^\s<]+"#, "$1 <gamertag>")
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    /// Removes what must never reach an assistant: tokens, keys, e-mail addresses, XUIDs, Steam IDs and account names,
    /// gamertags.
    static func redact(_ text: String) -> String {
        redactions.reduce(text) { result, rule in
            rule.0.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.1)
        }
    }

    // MARK: - Prompts

    private struct Prompt {
        var name: String
        var title: String
        var description: String
        var arguments: [[String: Any]]
        var text: ([String: String]) -> String
    }

    private static let prompts: [Prompt] = [
        Prompt(name: "diagnose", title: "Diagnose a MetalHorizon problem",
               description: "Find why the game does not start, crashes or misbehaves, and what to do about it.",
               arguments: [["name": "problem", "description": "What happens: the message on screen, when it happens", "required": false]],
               text: { args in
                   "Forza Horizon 6 in MetalHorizon has a problem: \(args["problem"] ?? "(not described yet: ask me)"). Use the metalhorizon tools: diagnose first (it reads the newest runs and the checks before Play), then check_setup; if I pasted an error, explain_error; read_session for the details and read_crash_reports for a crash. Tell me in plain words, one step at a time, what is wrong and what to do. Ask me before changing a setting or touching Steam."
               }),
        Prompt(name: "setup_assistant", title: "Set up MetalHorizon",
               description: "A step-by-step walk through the setup, from choosing the edition to the first Play.",
               arguments: [],
               text: { _ in
                   "Help me set up MetalHorizon from the start. Call check_setup and get_system_info, ask me which edition I own (Xbox / Microsoft Store or Steam) if it is not set, then take me through what is missing one item at a time: the engine and D3DMetal 4 (the app installs them; D3DMetal after Apple's licence), then for Xbox the Microsoft sign-in, the game folder and the download, or for Steam: Install Steam, Open Steam, sign in there and install the game. Propose each setting and use set_setting only after I agree. Finish with show_play_environment, then tell me to click Play."
               }),
        Prompt(name: "steam_setup", title: "Set up the Steam edition",
               description: "Steam in MetalHorizon: installing Steam, signing in, installing Forza Horizon 6, playing.",
               arguments: [],
               text: { _ in
                   "I own Forza Horizon 6 on Steam. Use steam_status, check_setup and network_check scope steam. Explain how MetalHorizon runs Steam (its own prefix, Steam's window with DXMT, the game launched by a silent Steam client) and take me through Install Steam, Open Steam (the first start updates Steam for a while), signing in in Steam's own window and installing the game. If something fails, use diagnose and explain_error. Never ask for my Steam password."
               }),
        Prompt(name: "controller_help", title: "Get a controller working",
               description: "Why the game does not see a controller, and how to fix it.",
               arguments: [["name": "controller", "description": "Which controller and how it is connected", "required": false]],
               text: { args in
                   "My controller \(args["controller"] ?? "") does not work in Forza Horizon 6. Use list_controllers and check_components (SDL2, GameInput in the engine). Explain what macOS sees, whether the next Play turns GameInput on, and what to try: plugging it in before Play, the Controllers setting (Automatic / Always On), Tools › Test Controllers in Wine. Ask before changing a setting."
               }),
        Prompt(name: "performance_tuning", title: "Improve performance",
               description: "Settings and checks for a smoother game on this Mac.",
               arguments: [],
               text: { _ in
                   "Help me get Forza Horizon 6 to run more smoothly. Use get_system_info, get_settings and diagnose. Suggest, one at a time and with the trade-off: the in-game preset and FSR, a frame cap (maxFPS), MetalFX (metalFX), turning off the Metal HUD, quitting other apps, keeping the game out of iCloud folders. Say plainly that the short freezes under Rosetta are a known open problem. Use set_setting only after I agree."
               }),
        Prompt(name: "report_issue", title: "Report a problem on GitHub",
               description: "Prepare a good GitHub issue: what happened, the diagnosis, and the diagnostics bundle.",
               arguments: [["name": "problem", "description": "What happened", "required": false]],
               text: { args in
                   "I want to report a MetalHorizon problem: \(args["problem"] ?? "(ask me)"). Use diagnose to find what is known, then export_diagnostics, and write me a short, clear issue text (what I did, what I expected, what happened, what MetalHorizon recognized). Give me the issue link it returns and tell me to attach the zip."
               })
    ]

    // MARK: - Troubleshooting guide

    static let troubleshootingGuide = """
    # MetalHorizon troubleshooting (Forza Horizon 6, Xbox / Microsoft Store and Steam editions)

    Each run has its own folder in ~/Library/Logs/MetalHorizon/sessions (output.log, game.log, summary.json); the app's \
    Diagnosis box and the diagnose tool read them. Crash reports: ~/Library/Logs/DiagnosticReports.

    ## Before the game starts (both editions)
    - Play is greyed out: one line of the Setup is red; check_setup says which and how to fix it.
    - The engine or D3DMetal does not install: the app downloads them from the project's GitHub release. "does not match its SHA-256": a damaged download, try Install again; other errors: no internet (network_check) or not enough space.
    - D3DMetal says "Not installed yet" after Apple's licence was declined: click Install… on its line and accept the licence.
    - macOS says the app is from an unidentified developer: it is not notarized yet. Move it to Applications, right-click › Open › Open, once. Running from Downloads (App Translocation) can stop its helpers.
    - Rosetta missing: softwareupdate --install-rosetta --agree-to-license. macOS older than 27: D3DMetal 4 needs macOS 27.
    - 8 GB Macs: the game is very likely to close or freeze under Rosetta.

    ## Xbox / Microsoft Store edition
    - macOS asks to let xodus-service use the "Xodus Service" Keychain item: choose Always Allow (it holds the Xbox sign-in).
    - "xodus-service did not start" and the game closes at once: sign in again, answer Always Allow, keep the app in Applications.
    - Download fails or stops: sign in first; the Microsoft account must own the Xbox / Microsoft Store edition (Game Pass is untested); about 160 GB free; not in iCloud Drive.
    - "Installation path is too long": use a short, real folder such as ~/FH6 (not a link: xodus resolves links).
    - The game folder's forzahorizon6.exe points to a folder that was moved: choose the folder the game is really in.
    - "Cloud save synchronization failed" / no "Welcome <gamertag>": xodus-service is not running or the account is not signed in.
    - A box asks to choose between the local and the cloud save: choose Cloud.

    ## Steam edition
    - MetalHorizon keeps Steam in its own prefix (~/Library/Application Support/MetalHorizon/Steam) or in a bottle the player picked; the game's Windows path is then C:\\Program Files (x86)\\Steam\\steamapps\\common\\ForzaHorizon6, short enough for the game's path check.
    - Install Steam: Valve's installer from Valve's mirrors (cdn.steampowered.com fails on some networks with a certificate error), installed silently. A failure on every mirror is the network (VPN, proxy, DNS filter).
    - c0000135 on C:\\windows\\syswow64\\ntdll.dll: the engine has no 32-bit half (Blackwell Engine Steam 1.0); install 1.1 or later.
    - Steam's window: opened with DXMT and sync off (Open Steam). Through D3DMetal it stays black or aborts on setDisplaySyncEnabled; with GPU acceleration off in Steam's settings it stays black too. The first start updates Steam and can look frozen.
    - Play: a silent Steam client with msync starts the game (steam.exe -silent -applaunch 2483190). A client opened for its window is restarted in that mode first. Steam keeps running in the background after the game; Stop Steam closes it cleanly (-shutdown), which keeps the sign-in.
    - "msync_init Failed bootstrap_look_up": a program was started with another sync mode than the prefix's; let MetalHorizon start Steam and the game.
    - "LaunchApp waiting for user response to ShowInterstitials" / Play waits forever: Steam shows a dialog (licence agreement, cloud save, update). Open Steam, answer it, start the game once from the Library, then Play.
    - E:0-0-L-8 / "Welcome, Player": the game ran without Steam; start it with Play.
    - "NO CONNECTION" after signing in: quit Steam for macOS.

    ## Messages from the game (both editions)
    - "Your graphics card is not supported" (FH205 / FH206): the DirectX 12 shim is missing or D3DMetal 3 is used.
    - Crash FHE21 right after the start: the game saw an AMD GPU. MetalHorizon reports an NVIDIA RTX 4070, as Highball's recipe does.
    - Crash writing to address 0x9 or 0x29 a minute in: Wine's concrt140 (game update of 3 November 2026); MetalHorizon 0.4 loads Microsoft's.
    - D3DMetal stops at start with com.apple.appleneuralengine Code=26: the Neural Engine start-up of its frame interpolator; MetalHorizon relaunches the game by itself.
    - "87 GB / 32 GB" low-memory warning, Xbox code asked at every launch, no engine sound: an engine without Highball's patches 0018, 0019, 0022/0023; use the installed Blackwell Engine.

    ## Controllers
    - The game reads pads through GameInput (engine patch 0012, on at Play when a pad is connected in Automatic, or Always On). Xbox pads arrive directly; PlayStation, Switch, 8BitDo and generic pads through SDL2 with an Xbox layout. Wheels go through DirectInput.
    - Connect or pair the pad before Play. Tools › Test Controllers in Wine shows what Wine sees.

    ## In game
    - Crash FHE11 after changing the ray tracing options: leave ray tracing off.
    - Stutter (freezes of 175-300 ms every few seconds) under Rosetta: known, not fixed yet.
    - Near foliage and some fir trees are black: known, not fixed yet.

    ## Closing
    - Quit from the game's own menu. Xbox edition: wait about 30 seconds, the cloud save uploads as the game closes. Force Quit skips that upload.

    ## Never
    - Never share a password, a sign-in code or a token. Signing in happens only on Microsoft's page or in Steam's window.
    - MetalHorizon does not modify the game's files and does not bypass its protection, Steam's DRM or the anti-cheat; requests to do so are out of scope.
    """
}
