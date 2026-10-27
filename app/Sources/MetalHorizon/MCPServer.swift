import Foundation

// MetalHorizon's MCP server: an AI assistant connects to it (stdio, newline-delimited JSON-RPC 2.0) to check the
// setup, read logs with secrets removed, look for the engine and D3DMetal, and change MetalHorizon's settings.
// It cannot start the game or a download, and it never reads the Keychain secrets.

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
    var handler: ([String: Any]) throws -> String

    var descriptor: [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
            "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": destructive,
                            "idempotentHint": true, "openWorldHint": false]
        ]
    }
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

    private static func dispatch(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": protocolVersions.contains(asked) ? asked : "2025-06-18",
                "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
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
            return ["resources": []]
        case "resources/templates/list":
            return ["resourceTemplates": []]
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Instructions for the assistant

    static let instructions = """
    MetalHorizon runs the user's own Xbox / Microsoft Store copy of Forza Horizon 6 on an Apple silicon Mac: Wine \
    (Blackwell Engine) + xodus (Xbox sign-in, download, licence) + Apple's D3DMetal 4 behind Highball's DirectX 12 shim. \
    The app downloads and installs Blackwell Engine and D3DMetal by itself (D3DMetal after the user accepts Apple's licence); \
    nothing comes from CrossOver.app. \
    You help the user set it up and debug it.

    How to help:
    - Start with check_setup. It says what is ready, what is missing and how to fix each item.
    - For an error or a crash, use list_logs then read_log (the newest play log, xodus-service.log, crash reports), \
    and get_troubleshooting_guide for the known messages and their causes.
    - To fill in a missing folder, use find_engines and find_d3dmetal, explain what you found, and use set_setting only \
    after the user agrees. MetalHorizon must be reopened to show a changed setting.
    - show_play_environment shows exactly what Play would run, without starting anything.
    - Answer in the user's language, in plain words, one step at a time; the user may be a beginner.

    Rules:
    - Never ask for a Microsoft password, a sign-in code or a token, and never repeat one. Signing in happens only \
    on Microsoft's page, from the app's "Sign In with Microsoft…" button.
    - The logs come with tokens, e-mail addresses, XUIDs and gamertags removed; do not try to recover them.
    - Do not help bypass the game's copy protection, licence check or anti-cheat, or modify the game's files. \
    MetalHorizon's fixes live only in the compatibility layer. Online play is unofficial and carries a risk for the account.
    - You cannot start the game or a download: ask the user to click Play or Download from Xbox. They should quit \
    the game from its own menu and wait about 30 seconds (the cloud save uploads).
    """

    // MARK: - Tools

    private static let tools: [Tool] = [
        Tool(name: "check_setup", title: "Check the setup",
             description: "Everything Play needs, item by item (game folder, Blackwell Engine, D3DMetal 4, DirectX 12 shim, Xbox account, xodus-service, Rosetta, macOS, memory, disk), with a fix for each problem. Start here.",
             handler: { _ in checkSetup() }),
        Tool(name: "get_troubleshooting_guide", title: "Troubleshooting guide",
             description: "Known messages and symptoms of Forza Horizon 6 under MetalHorizon (FH205, FHE21, 'Installation path is too long', 'Cloud save synchronization failed', no engine sound, stutter...) with their causes and fixes.",
             handler: { _ in troubleshootingGuide }),
        Tool(name: "list_logs", title: "List the logs",
             description: "MetalHorizon's logs (play, download, xodus-service) and the macOS crash reports of Wine, the game and xodus, newest first. Pass an id to read_log.",
             handler: { _ in try listLogs() }),
        Tool(name: "read_log", title: "Read a log",
             description: "One log or crash report from list_logs, with tokens, e-mail addresses, XUIDs and gamertags removed. Crash reports are summarized (exception, faulting thread).",
             properties: [
                "id": ["type": "string", "description": "The id from list_logs, such as logs/play-2026-10-25T20-00-00Z.log or crash/wine64-preloader-2026-10-25-200000.ips"],
                "tail": ["type": "integer", "description": "Last lines to return (default 200, at most 2000)"],
                "grep": ["type": "string", "description": "Keep only the lines that contain this text (case-insensitive)"]
             ], required: ["id"], handler: readLog),
        Tool(name: "show_play_environment", title: "Show what Play would run",
             description: "Runs the Play script in dry-run mode with the current settings: the environment (GPU identity, d3d12 and D3DMetal paths, Wine prefix) and the command, or the first STOP message that would block Play. Starts nothing.",
             handler: { _ in try showPlayEnvironment() }),
        Tool(name: "find_engines", title: "Find Wine engines",
             description: "Looks on this Mac for Wine engines (folders with bin/wine) and says which can run the game (Xbox runtime, DirectX 12 shim).",
             handler: { _ in findEngines() }),
        Tool(name: "find_d3dmetal", title: "Find D3DMetal",
             description: "Looks on this Mac for Apple's D3DMetal (mounted Game Porting Toolkit, Downloads, Applications) and gives each copy's version; the game needs version 4.",
             handler: { _ in findD3DMetal() }),
        Tool(name: "set_setting", title: "Change a setting",
             description: "Sets one of MetalHorizon's settings after checking the value: gameDirectory, engineDirectory, d3dmetalDirectory (folders; \"default\" goes back to the installed component) or metalHUD (true/false). Ask the user first. MetalHorizon must be reopened to show the change.",
             properties: [
                "key": ["type": "string", "enum": ["gameDirectory", "engineDirectory", "d3dmetalDirectory", "metalHUD"]],
                "value": ["type": "string", "description": "A folder path (~ allowed) or true/false for metalHUD"]
             ], required: ["key", "value"], readOnly: false, handler: setSetting),
        Tool(name: "xodus_service", title: "xodus-service",
             description: "Status, start or stop of xodus-service, the helper that holds the Xbox sign-in and gives the game its tokens. Without it: 'Cloud save synchronization failed' and no online play. Do not stop it while the game runs.",
             properties: ["action": ["type": "string", "enum": ["status", "start", "stop"]]],
             required: ["action"], readOnly: false, destructive: true, handler: xodusService)
    ]

    private static func checkSetup() -> String {
        let setup = Setup.load()
        func row(_ item: String, _ check: Check) -> [String: Any] {
            var r: [String: Any] = ["item": item, "status": !check.ok ? "problem" : (check.fix == nil ? "ok" : "warning"),
                                    "detail": check.text]
            if let fix = check.fix { r["fix"] = fix }
            return r
        }
        var checks = [
            row("game folder", setup.gameCheck),
            row("Blackwell Engine", setup.engineCheck),
            row("D3DMetal 4", setup.d3dmetalCheck),
            row("DirectX 12 shim", setup.shimReady ? Check(ok: true, text: "assembled in " + shimDirectory)
                : Check(ok: false, text: "not assembled yet", fix: "The app assembles it once Blackwell Engine and D3DMetal are installed: open MetalHorizon."))
        ]
        let saved = xboxAccountSaved()
        checks.append(row("Xbox account", saved ? Check(ok: true, text: "saved in the Keychain")
            : Check(ok: false, text: "not signed in", fix: "Click Sign In with Microsoft… in the app and sign in on Microsoft's page.")))
        let rosetta = fileExists("/Library/Apple/usr/libexec/oah/libRosettaRuntime")
        checks.append(row("Rosetta", rosetta ? Check(ok: true, text: "installed")
            : Check(ok: false, text: "not installed", fix: "Run: softwareupdate --install-rosetta --agree-to-license")))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(row("macOS", os.majorVersion >= 27 ? Check(ok: true, text: ProcessInfo.processInfo.operatingSystemVersionString)
            : Check(ok: false, text: ProcessInfo.processInfo.operatingSystemVersionString, fix: "The game needs macOS 27 (D3DMetal 4's DirectX 12 barriers).")))
        let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        checks.append(row("memory", memoryGB >= 16 ? Check(ok: true, text: "\(memoryGB) GB")
            : Check(ok: true, text: "\(memoryGB) GB", fix: "Below 16 GB the game is likely to stutter or run out of memory; use low texture settings.")))

        var warnings: [String] = []
        if !setup.gameDirectory.isEmpty {
            if setup.gameDirectory.count > 60 {
                warnings.append("The game folder path is long; FH6 quits with 'Installation path is too long' on long paths. ~/FH6 works.")
            }
            let exe = (try? FileManager.default.destinationOfSymbolicLink(atPath: setup.gameDirectory + "/forzahorizon6.exe")) ?? setup.gameDirectory
            for place in [home + "/Desktop", home + "/Documents", home + "/Library/Mobile Documents"] where exe.hasPrefix(place) || setup.gameDirectory.hasPrefix(place) {
                warnings.append("The game files are in \(place.replacingOccurrences(of: home, with: "~")), which iCloud may sync: loading gets slower and stutters more. Keep them in a folder like ~/Games.")
            }
            if let free = try? URL(fileURLWithPath: setup.gameDirectory).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage {
                let gb = Int(free / 1_000_000_000)
                if !setup.gameCheck.ok && gb < 170 { warnings.append("Only \(gb) GB free on the game's disk; the download needs about 160 GB.") }
                else if gb < 20 { warnings.append("Only \(gb) GB free on the game's disk; keep at least 20 GB for shader caches and saves.") }
            }
        }
        let service = serviceState()
        if !service.running { warnings.append("xodus-service is not running. Play starts it; without it: no Xbox sign-in in the game.") }

        let result: [String: Any] = [
            "app": ["version": appVersion, "executable": redact(Bundle.main.executablePath ?? "")],
            "ready_to_play": setup.readyToPlay && saved,
            "checks": checks,
            "warnings": warnings,
            "xodus_service": ["running": service.running, "socket": xodusRuntimeDir + "/xodus.sock"],
            "running_processes": runningProcesses(),
            "settings": ["gameDirectory": redact(setup.gameDirectory),
                         "engineDirectory": setup.engineDirectory.isEmpty ? "(installed Blackwell Engine)" : redact(setup.engineDirectory),
                         "d3dmetalDirectory": setup.d3dmetalDirectory.isEmpty ? "(installed D3DMetal)" : redact(setup.d3dmetalDirectory),
                         "metalHUD": setup.metalHUD],
            "components": Component.all().map { ["name": $0.name, "version": $0.version, "installed": $0.installedVersion ?? "no"] },
            "system": ["model": sysctlString("hw.model"), "chip": sysctlString("machdep.cpu.brand_string"), "memory_gb": memoryGB]
        ]
        return json(result)
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
        let ours = ["wine", "forza", "xodus", "metalhorizon"]
        let isOurs: (String) -> Bool = { name in name.hasSuffix(".ips") && ours.contains { name.lowercased().contains($0) } }
        let crashes = (entries(reports, prefix: "crash/", keep: isOurs, limit: 15)
                       + entries(reports.appendingPathComponent("Retired"), prefix: "crash/", keep: isOurs, limit: 15))
        return json(["metalhorizon_logs": entries(logDirectory, prefix: "logs/", keep: { $0.hasSuffix(".log") }, limit: 30),
                     "crash_reports": Array(crashes.prefix(20)),
                     "note": "Logs folder: ~/Library/Logs/MetalHorizon. Play runs without traces (WINEDEBUG=-all), so its log is short; for deep traces the repository's tools/mac_all.sh is used."])
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
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ToolError(message: "Cannot read \(id)") }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 5_000_000 ? size - 5_000_000 : 0)   // the end of a huge log is what matters
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if let grep = args["grep"] as? String, !grep.isEmpty {
            lines = lines.filter { $0.range(of: grep, options: .caseInsensitive) != nil }
        }
        let shown = lines.suffix(tail)
        return redact("\(id): last \(shown.count) of \(lines.count) lines\(size > 5_000_000 ? " (from the last 5 MB)" : "")\n"
                      + shown.joined(separator: "\n"))
    }

    /// A macOS .ips crash report in a few lines: process, exception, termination, faulting thread's frames.
    private static func crashSummary(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8), let split = text.firstIndex(of: "\n") else { return nil }
        let header = (try? JSONSerialization.jsonObject(with: Data(text[..<split].utf8))) as? [String: Any] ?? [:]
        guard let body = (try? JSONSerialization.jsonObject(with: Data(text[text.index(after: split)...].utf8))) as? [String: Any] else { return nil }
        var out = ["Process: \(body["procName"] ?? header["app_name"] ?? "?")  time: \(header["timestamp"] ?? body["captureTime"] ?? "?")"]
        if let exception = body["exception"] { out.append("Exception: \(compact(exception))") }
        if let termination = body["termination"] { out.append("Termination: \(compact(termination))") }
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

    private static func showPlayEnvironment() throws -> String {
        guard let resources = Bundle.main.resourceURL,
              fileExists(resources.appendingPathComponent("metalhorizon-play.sh").path) else {
            throw ToolError(message: "This copy of MetalHorizon has no Play script (development build?).")
        }
        var env = Setup.load().playEnvironment(resources: resources)
        env["MH_DRY_RUN"] = "1"
        let (code, output) = shell("/bin/bash", [resources.appendingPathComponent("metalhorizon-play.sh").path], env: env)
        return redact((code == 0 ? "Play would run with:\n" : "Play would stop (exit \(code)):\n") + output)
    }

    private static func findEngines() -> String {
        var servers = shell("/usr/bin/mdfind", ["kMDItemFSName == 'wineserver'"], timeout: 15).1
            .split(separator: "\n").map(String.init)
        let current = Setup.load().engine
        for dir in [current, installedEngineDirectory, home + "/BlackwellEngine-build/out/engine"] where !dir.isEmpty {
            servers.append(dir + "/bin/wineserver")
        }
        var seen = Set<String>()
        var found: [[String: Any]] = []
        for server in servers where server.hasSuffix("/bin/wineserver") {
            let engine = String(server.dropLast("/bin/wineserver".count))
            guard fileExists(engine + "/bin/wine"), seen.insert(engine).inserted else { continue }
            let xbox = fileExists(engine + "/lib/wine/x86_64-windows/xgameruntime.dll")
            let shim = fileExists(engine + "/renderers/d3dmetal-tsshim-hb/wine/x86_64-windows/d3d12.dll")
            let crossover = engine.contains("CrossOver.app")
            let ownLibraries = fileExists(engine + "/lib/libgnutls.30.dylib") && fileExists(engine + "/lib/libfreetype.6.dylib")
            found.append(["path": redact(engine), "xbox_runtime": xbox, "dx12_shim": shim, "own_libraries": ownLibraries,
                          "current": engine == current, "suitable": xbox && ownLibraries && !crossover,
                          "note": crossover ? "CrossOver's own Wine: no Xbox runtime, cannot run the Store edition"
                                : (!xbox ? "no xgameruntime.dll: not Blackwell Engine"
                                : (!ownLibraries ? "an older engine that needs CrossOver.app's GnuTLS and FreeType"
                                : (shim ? "ready" : "works, but without the shim the game reports FH205/FH206")))])
            if found.count == 20 { break }
        }
        return json(["engines": found,
                     "note": found.contains { $0["suitable"] as? Bool == true } ? "Pass a suitable path to set_setting engineDirectory."
                        : "No suitable engine found. Build one with engine/build.sh from the repository."])
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

    private static func setSetting(_ args: [String: Any]) throws -> String {
        guard let key = args["key"] as? String, let raw = args["value"] as? String else { throw ToolError(message: "key and value are required") }
        let store = settingsStore()
        var setup = Setup.load()
        switch key {
        case "metalHUD":
            guard ["true", "false"].contains(raw.lowercased()) else { throw ToolError(message: "metalHUD takes true or false") }
            setup.metalHUD = raw.lowercased() == "true"
            store.set(setup.metalHUD, forKey: SettingKey.metalHUD)
            return "metalHUD = \(setup.metalHUD). Reopen MetalHorizon to see it."
        case "gameDirectory", "engineDirectory", "d3dmetalDirectory":
            if key != "gameDirectory", raw.isEmpty || raw.lowercased() == "default" {
                store.removeObject(forKey: key == "engineDirectory" ? SettingKey.engineDirectory : SettingKey.d3dmetalDirectory)
                return "\(key) reset to the component MetalHorizon installs. Reopen MetalHorizon to see it."
            }
            var path = expandTilde(raw)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                throw ToolError(message: "Not a folder: \(raw)")
            }
            let check: Check
            switch key {
            case "gameDirectory":
                setup.gameDirectory = path; check = setup.gameCheck
                store.set(path, forKey: SettingKey.gameDirectory)
            case "engineDirectory":
                path = Setup.normalizeEngine(path); setup.engineDirectory = path; check = setup.engineCheck
                guard fileExists(path + "/bin/wine") else { throw ToolError(message: "No bin/wine in \(path): not an engine. Nothing changed.") }
                store.set(path, forKey: SettingKey.engineDirectory)
            default:
                path = Setup.normalizeD3DMetal(path); setup.d3dmetalDirectory = path; check = setup.d3dmetalCheck
                guard fileExists(path + "/external/libd3dshared.dylib"), fileExists(path + "/wine/x86_64-windows/d3d12.dll") else {
                    throw ToolError(message: "\(path) is not Apple's redist/lib folder (external/ and wine/). Nothing changed.")
                }
                store.set(path, forKey: SettingKey.d3dmetalDirectory)
            }
            store.synchronize()
            return json(["set": key, "value": redact(path), "status": !check.ok ? "problem" : (check.fix == nil ? "ok" : "warning"),
                         "detail": check.text, "fix": check.fix ?? "", "note": "Reopen MetalHorizon to see the change."])
        default:
            throw ToolError(message: "Unknown key \(key)")
        }
    }

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
        let wanted = ["forzahorizon6", "wineserver", "xodus-service", "xodus-cli", "xodus-login"]
        return shell("/bin/ps", ["-axo", "pid=,comm="]).1.split(separator: "\n").compactMap { line in
            let name = (line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? "")
            guard let match = wanted.first(where: { name.lowercased().contains($0) }) else { return nil }
            return "\(line.split(separator: " ").first ?? "?") \(match)"
        }
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
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
        (#"(?i)(gamertag["']?\s*[:=]?\s*["'])[^"']+"#, "$1<gamertag>"),
        (#"(?i)(Bienvenue,?|Welcome,?)\s+[^\s<]+"#, "$1 <gamertag>")
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    /// Removes what must never reach an assistant: tokens, keys, e-mail addresses, XUIDs, gamertags.
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
                   "Forza Horizon 6 in MetalHorizon has a problem: \(args["problem"] ?? "(not described yet: ask me)"). Use the metalhorizon tools: check_setup first, then list_logs and read_log for the newest play log, logs/xodus-service.log and any crash report, and compare with get_troubleshooting_guide. Tell me in plain words, one step at a time, what is wrong and what to do. Ask me before changing a setting."
               }),
        Prompt(name: "setup_assistant", title: "Set up MetalHorizon",
               description: "A step-by-step walk through the setup, from signing in to the first Play.",
               arguments: [],
               text: { _ in
                   "Help me set up MetalHorizon from the start. Call check_setup, then take me through what is missing one item at a time: signing in with Microsoft, the game folder and the download, Blackwell Engine and D3DMetal 4 (the app installs them; D3DMetal after Apple's licence is accepted). Propose each setting and use set_setting only after I agree. Finish with show_play_environment, then tell me to click Play."
               })
    ]

    // MARK: - Troubleshooting guide

    static let troubleshootingGuide = """
    # MetalHorizon troubleshooting (Forza Horizon 6, Xbox / Microsoft Store edition)

    Logs: ~/Library/Logs/MetalHorizon (play-*.log, download-*.log, xodus-service.log). Crash reports: ~/Library/Logs/DiagnosticReports.
    Play runs the game without Wine traces; deep traces come from the repository's tools (tools/mac_all.sh).

    ## Before the game starts
    - Play is greyed out: one line of the Setup is red. check_setup says which and how to fix it.
    - Blackwell Engine or D3DMetal does not install: the app downloads them from the project's GitHub release. "The server answered 404": the release is not public yet; other errors: no internet, or not enough space in ~/Library/Application Support. "does not match its SHA-256": a damaged download, try Install again.
    - D3DMetal says "Not installed yet" after Apple's licence was declined: click Install… on its line and accept the licence. MetalHorizon never installs it without that.
    - "the DirectX 12 shim is not ready": the app assembles it after both components are installed; reopening the app does it.
    - "STOP: ..." in the activity log: the Play script found a missing piece before starting (Blackwell Engine, D3DMetal 4, the DirectX 12 shim, the game folder). The message names it.
    - macOS says the app is from an unidentified developer: it is not notarized yet. Right-click MetalHorizon > Open > Open, once.
    - macOS asks to let xodus-service use the "Xodus Service" Keychain item: choose Always Allow (it holds the Xbox sign-in).
    - Download fails or stops: sign in first; the Microsoft account must own the Xbox / Microsoft Store edition (Game Pass is untested); about 160 GB free; not in iCloud Drive.

    ## Messages from the game
    - "Installation path is too long": the game folder path is too long. Use a short, real folder such as ~/FH6 (not a link: xodus resolves links).
    - "Your graphics card is not supported" (FH205 / FH206): the engine lacks Highball's DirectX 12 shim (tools/mac_setup_tsshim.sh), or D3DMetal 3 is used instead of 4.
    - Crash FHE21 right after the start: the game saw an AMD GPU and took an AMD-only path. MetalHorizon reports an NVIDIA RTX 4070, as Highball's recipe does; other scripts need FH6_GPU=nvidia.
    - "Cloud save synchronization failed" / no "Welcome <gamertag>": xodus-service is not running or the account is not signed in (xodus_service start, then sign in again). An engine without GnuTLS gives the same message (bcrypt "no encryption support"): use an engine built with engine/build.sh.
    - "The Forza Horizon 6 server is not available" (online): the xodus-service in use does not mint title-authenticated tokens (patches/xodus-cli/0002). MetalHorizon's bundled service does.
    - Online matchmaking searches forever: the engine lacks the dual-stack socket fix (engine/patches/0006-network.patch).
    - A box asks to choose between the local and the cloud save: choose Cloud.
    - "87 GB / 32 GB" low-memory warning: the engine lacks Highball 0018 (engine/patches/0004).
    - The Xbox code is asked at every launch: the engine lacks Highball 0019 (engine/patches/0008).
    - Message boxes are thin empty "pills" or have blank buttons: the engine has no fonts or no FreeType.

    ## In game
    - No engine sound: the engine lacks the surround patches (Highball 0022/0023, engine/patches/0007).
    - Crash FHE11 after changing the ray tracing options: leave ray tracing off.
    - Crash at start with ROSETTA_ADVERTISE_AVX=1: AVX makes FH6 crash; leave it off.
    - Stutter (freezes of 175-300 ms every few seconds): known, not fixed yet (shader compilation was ruled out). Keep the game files out of iCloud-synced folders; turning the Metal HUD off saves a little.
    - Near foliage and some fir trees are black: known, not fixed yet (a depth test that Metal does not match bit for bit).
    - The game freezes or crashes while the map loads: under investigation; send the newest crash report summary (read_log on crash/...).

    ## Closing
    - Quit from the game's own menu and wait about 30 seconds: the cloud save uploads as the game closes. Force Quit skips that upload.

    ## Never
    - Never share a password, a sign-in code or a token. Signing in happens only on Microsoft's page.
    - MetalHorizon does not modify the game's files and does not bypass its protection or anti-cheat; requests to do so are out of scope.
    """
}
