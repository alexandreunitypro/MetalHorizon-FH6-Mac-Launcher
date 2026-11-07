import XCTest
@testable import MetalHorizon

// The known-problem table against the lines players actually sent (MetalHorizon's GitHub issues #1-#3 and the
// macOS 27.2 Steam report), the log tail and filter, Steam's files, and the MCP server's surface.
final class DiagnosticsTests: XCTestCase {
    override class func setUp() { TestEnvironment.ensure() }
    private func ids(_ text: String) -> [String] { Diagnostics.scan(text: text, source: "test").map(\.id) }

    func testReportedLinesAreRecognized() {
        let cases: [(String, String)] = [
            ("curl: (60) SSL: no alternative certificate subject name matches target host name 'cdn.steampowered.com'", "steam-download-blocked"),
            (#"wine: failed to load L"\??\C:\windows\syswow64\ntdll.dll" error c0000135"#, "no-32bit-engine"),
            ("reason: '-[NSViewBackingLayer setDisplaySyncEnabled:]: unrecognized selector sent to instance'", "steam-window-d3dmetal"),
            ("[18:10:50] Browser requested transparent background, but it is not supported", "steam-black-window"),
            ("[18:10:54] Invalid browser dimensions: 0 x 0", "steam-black-window"),
            ("059c:err:sync:msync_init Failed bootstrap_look_up for wine-370f0d1-msync", "msync-mismatch"),
            (#" Error Domain=com.apple.appleneuralengine Code=26 "doCompileModel:csIdentity:sandboxExtension:options:qos:withReply:: Bad argument error""#, "ane-init"),
            ("Installation path is too long.", "path-too-long"),
            ("错误代码 E:0-0-L-8", "steam-auth"),
            ("18:08:27 GameAction [AppID 2483190, ActionID 1] : LaunchApp waiting for user response to ShowInterstitials", "steam-interstitial"),
            ("WARN: xodus-service did not start; no Xbox sign-in", "xodus-service-down"),
            ("wine: could not load ntdll.so: dlopen(/Users/alexandre/BlackwellEngine-build-steam/out/engine/lib/wine/x86_64-unix/ntdll.so, 0x0002)", "no-ntdll-so"),
            ("Wine cannot find the FreeType font library.  To enable Wine to", "no-freetype"),
            ("arch: posix_spawnp: wine: Bad CPU type in executable", "rosetta-missing"),
            ("STOP: forzahorizon6.exe in /Users/x/FH6 is a link to /Users/x/Desktop/FORZA HORIZON 6/forzahorizon6.exe, which is gone: choose the folder the game is really in", "broken-game-link"),
            ("wine: Unhandled page fault on write access to 0000000000000001 at address 00006FFFFDCC54F8 (thread 0024)", "page-fault"),
            ("thread 'main' (2970636) panicked at crates/xodus-cli/src/commands/run.rs:197:10:", "xodus-package-missing"),
        ]
        for (line, expected) in cases {
            XCTAssertTrue(ids(line).contains(expected), "\(expected) not found in: \(line) -> \(ids(line))")
        }
    }

    func testRetriedAndCleanLinesAreNotFindings() {
        XCTAssertEqual(ids("(retried) com.apple.appleneuralengine Code=26"), [])
        XCTAssertEqual(ids("== launch 1\n== game started. Quit it from its menu\n== exit 0 after 1200s\n== game closed (exit 0)"), [])
    }

    func testFindingsAreDeduplicatedCountedAndSorted() {
        let text = """
            [18:10:50] Browser requested transparent background, but it is not supported
            [18:10:51] Browser requested transparent background, but it is not supported
            Steam Client Service failed (GLE 126)
            wine: failed to load L"\\??\\C:\\windows\\syswow64\\ntdll.dll" error c0000135
            """
        let findings = Diagnostics.scan(text: text, source: "test")
        XCTAssertEqual(findings.first?.id, "no-32bit-engine", "errors come first")
        XCTAssertEqual(findings.first { $0.id == "steam-black-window" }?.count, 2)
        XCTAssertEqual(findings.last?.issue.severity, .info)
    }

    func testEvidenceIsRedacted() {
        let finding = Diagnostics.scan(text: "STOP: sign-in failed for someone@example.com token=eyJabcdefghijk.lmnopqrstuvwx", source: "t").first
        XCTAssertNotNil(finding)
        XCTAssertFalse(finding!.evidence.contains("example.com"))
        XCTAssertFalse(finding!.evidence.contains("eyJabcdefghijk"))
    }

    func testEveryIssueHasPatternsThatCompile() {
        for issue in Diagnostics.issues {
            XCTAssertFalse(issue.patterns.isEmpty, issue.id)
            for pattern in issue.patterns {
                XCTAssertNoThrow(try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), "\(issue.id): \(pattern)")
            }
        }
        XCTAssertEqual(Set(Diagnostics.issues.map(\.id)).count, Diagnostics.issues.count, "ids are unique")
        XCTAssertGreaterThanOrEqual(Diagnostics.issues.count, 30)
    }

    // MARK: - Logs

    func testLogTailReadsOnlyWhatWasAdded() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "one\ntwo\nthr".write(to: url, atomically: true, encoding: .utf8)
        let tail = LogTail(limit: 3)
        tail.reset(url)
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.lines, ["one", "two"], "a partial line waits for its newline")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("ee\nfour\nfive\n".utf8))
        try handle.close()
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.lines, ["three", "four", "five"], "only the last `limit` lines are kept")
        XCTAssertEqual(tail.totalLines, 5)
        XCTAssertFalse(tail.poll(), "nothing new")
        try "fresh\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(tail.poll())
        XCTAssertEqual(tail.lines, ["fresh"], "a truncated file starts over")
    }

    func testFilterDropsMoltenVKNoiseAndKeepsErrors() {
        let lines = ["[mvk-info] MoltenVK version 1.4.2, supporting Vulkan version 1.4.357.",
                     "\tVK_KHR_16bit_storage v1", "  % Total    % Received % Xferd  Average Speed   Time",
                     "== starting Steam's own installer.", "wine: Unhandled page fault on read access"]
        XCTAssertEqual(LogFilter.apply(lines, errorsOnly: false, search: ""),
                       ["== starting Steam's own installer.", "wine: Unhandled page fault on read access"])
        XCTAssertEqual(LogFilter.apply(lines, errorsOnly: true, search: ""), ["wine: Unhandled page fault on read access"])
        XCTAssertEqual(LogFilter.apply(lines, errorsOnly: false, search: "STEAM"), ["== starting Steam's own installer."])
    }

    // MARK: - Steam

    func testSteamFilesAndManifest() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("steamprefix-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: prefix) }
        let files = SteamFiles(prefix: prefix)
        XCTAssertFalse(files.installed)
        let steam = files.steamDirectory
        try FileManager.default.createDirectory(atPath: steam + "/steamapps", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: steam + "/config", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: steam + "/steam.exe", contents: Data("MZ".utf8))
        XCTAssertTrue(files.installed)
        XCTAssertFalse(files.signedInOnce)
        try "\"users\"\n{\n\t\"76561198000000000\"\n\t{\n\t\t\"AccountName\"\t\t\"someone\"\n\t}\n}\n".write(toFile: steam + "/config/loginusers.vdf", atomically: true, encoding: .utf8)
        XCTAssertTrue(files.signedInOnce)
        let manifest = "\"AppState\"\n{\n\t\"appid\"\t\t\"2483190\"\n\t\"StateFlags\"\t\t\"1026\"\n\t\"installdir\"\t\t\"ForzaHorizon6\"\n\t\"buildid\"\t\t\"26422872\"\n\t\"UserConfig\"\n\t{\n\t\t\"language\"\t\t\"french\"\n\t}\n}\n"
        try manifest.write(toFile: steam + "/steamapps/appmanifest_2483190.acf", atomically: true, encoding: .utf8)
        XCTAssertEqual(SteamFiles.parseACF(manifest)["buildid"], "26422872")
        XCTAssertNil(SteamFiles.parseACF(manifest)["language"], "nested blocks are skipped")
        XCTAssertFalse(files.gameInstalled, "1026 is updating, not installed")
        XCTAssertTrue(files.gameDownloading)
        try manifest.replacingOccurrences(of: "1026", with: "4").write(toFile: steam + "/steamapps/appmanifest_2483190.acf", atomically: true, encoding: .utf8)
        XCTAssertTrue(files.gameInstalled)
        XCTAssertFalse(files.gameDownloading)
        XCTAssertEqual(files.gameFolder, steam + "/steamapps/common/ForzaHorizon6")

        let setup = Setup(edition: .steam, steamPrefix: prefix)
        XCTAssertTrue(setup.steamClientCheck.ok)
        XCTAssertTrue(setup.steamGameCheck.ok, setup.steamGameCheck.text)
        XCTAssertTrue(setup.engine.hasSuffix("Blackwell Engine Steam"))
        XCTAssertEqual(setup.prefix, prefix)
        XCTAssertTrue(Setup.looksLikeSteamPrefix(prefix), "drive_c with Steam in it")
    }

    func testSteamStatusParse() {
        let status = SteamStatus.parse("prefix=yes\nclient_running=yes\nclient_mode=game\ngame_running=no\nengine_32bit=yes\nengine_dxmt=no\n")
        XCTAssertTrue(status.clientRunning)
        XCTAssertEqual(status.clientMode, "game")
        XCTAssertFalse(status.gameRunning)
        XCTAssertFalse(status.engineDXMT)
    }

    func testGameInputDecision() {
        let pad = ControllerInfo(id: "x", name: "Xbox Wireless Controller", kind: "Gamepad", vendorID: 0x045e, productID: 0x0b13, transport: "Bluetooth")
        XCTAssertTrue(Controllers.gameInputEnabled(mode: .automatic, connected: [pad]))
        XCTAssertFalse(Controllers.gameInputEnabled(mode: .automatic, connected: []))
        XCTAssertTrue(Controllers.gameInputEnabled(mode: .on, connected: []))
        XCTAssertFalse(Controllers.gameInputEnabled(mode: .off, connected: [pad]))
        XCTAssertEqual(pad.route, "XInput (Xbox)")
        XCTAssertEqual(ControllerInfo(id: "p", name: "DualSense", kind: "Gamepad", vendorID: 0x054c, productID: 0x0ce6, transport: "USB").route,
                       "SDL2 → Xbox layout")
    }

    // MARK: - Crash reports

    func testCrashMessageAndBacktraceFromWinedbg() {
        let log = """
            winecoreaudio: 12-channel stream (mask 0x2d63f) rendered by AUSpatialMixer
            (harmless) com.apple.appleneuralengine Code=26
            Unhandled exception: page fault on write access to 0x0000000000000029 in 64-bit code (0x0000000141a2b3c4).
            Register dump:
             rip:0000000141a2b3c4 rsp:000000000031fd20
            Backtrace:
            =>0 0x0000000141a2b3c4 in forzahorizon6 (+0x1a2b3c4) (0x000000000031fe00)
              1 0x0000000141a2c000 in forzahorizon6 (+0x1a2c000) (0x000000000031fe40)
              2 0x00006fffffc31234 in concrt140 (+0x11234) (0x000000000031fe80)
            Modules:
            Module	Address			Debug info	Name (120 modules)
            """
        let (message, frames) = CrashReport.errorMessage(in: log)
        XCTAssertTrue(message.hasPrefix("Unhandled exception: page fault on write access to 0x0000000000000029"), message)
        XCTAssertEqual(frames.count, 3)
        XCTAssertTrue(frames[2].contains("concrt140"))
        XCTAssertTrue(Diagnostics.scan(text: log, source: "t").contains { $0.id == "concrt140" })
        XCTAssertEqual(CrashReport.errorMessage(in: "== game closed (exit 0)\n(harmless) com.apple.appleneuralengine Code=26").0, "")
        XCTAssertTrue(CrashReport.errorMessage(in: "thread 'main' panicked at crates/xodus-cli/src/commands/run.rs:197:10:").0.contains("panicked"))
    }

    // MARK: - MCP

    private func call(_ name: String, _ arguments: [String: Any] = [:]) -> (text: String, isError: Bool) {
        let response = MCPServer.respond("tools/call", ["name": name, "arguments": arguments])
        let result = response["result"] as? [String: Any] ?? [:]
        let content = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "\(response)"
        return (content, result["isError"] as? Bool ?? true)
    }

    func testMCPSurface() throws {
        let initialize = try XCTUnwrap(MCPServer.respond("initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any])
        let capabilities = try XCTUnwrap(initialize["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["resources"])
        XCTAssertNotNil(capabilities["prompts"])
        let tools = try XCTUnwrap((MCPServer.respond("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertGreaterThanOrEqual(names.count, 25)
        XCTAssertEqual(Set(names).count, names.count)
        for expected in ["check_setup", "diagnose", "explain_error", "steam_status", "list_controllers", "network_check", "export_diagnostics"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
        let prompts = try XCTUnwrap((MCPServer.respond("prompts/list")["result"] as? [String: Any])?["prompts"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(prompts.count, 6)
        let resources = try XCTUnwrap((MCPServer.respond("resources/list")["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        XCTAssertTrue(resources.contains { $0["uri"] as? String == "metalhorizon://known-issues" })
        let known = try XCTUnwrap((MCPServer.respond("resources/read", ["uri": "metalhorizon://known-issues"])["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        XCTAssertTrue((known.first?["text"] as? String ?? "").contains("no-32bit-engine"))
        XCTAssertNotNil(MCPServer.respond("resources/read", ["uri": "metalhorizon://nope"])["error"])
        XCTAssertNotNil(MCPServer.respond("tools/call", ["name": "nope"])["error"])
    }

    func testMCPExplainsThePastedReport() {
        let pasted = """
            == downloading Steam's own installer from steampowered.com
            curl: (60) SSL: no alternative certificate subject name matches target host name 'cdn.steampowered.com'
            STOP: could not download Steam's installer
            wine: failed to load L"\\??\\C:\\windows\\syswow64\\ntdll.dll" error c0000135
            """
        let (text, isError) = call("explain_error", ["text": pasted])
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("steam-download-blocked"), text)
        XCTAssertTrue(text.contains("no-32bit-engine"), text)
        XCTAssertTrue(call("explain_error", ["text": "all good"]).text.contains("No known problem"))
        XCTAssertTrue(call("explain_error").isError)
        let steamOnly = call("list_known_issues", ["edition": "steam"]).text
        XCTAssertTrue(steamOnly.contains("steam-interstitial"))
        XCTAssertFalse(steamOnly.contains("xodus-service-down"))
    }

    func testRedactionCoversSteam() {
        let text = "-steamid=76561198012345678 \"AccountName\"\t\t\"player_one\" mail me at a.b@example.org Welcome, Gamer123"
        let clean = MCPServer.redact(text)
        XCTAssertFalse(clean.contains("76561198012345678"), clean)
        XCTAssertFalse(clean.contains("player_one"), clean)
        XCTAssertFalse(clean.contains("example.org"), clean)
        XCTAssertFalse(clean.contains("Gamer123"), clean)
    }
}
