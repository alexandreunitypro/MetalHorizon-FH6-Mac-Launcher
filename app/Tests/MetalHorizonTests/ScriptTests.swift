import XCTest
@testable import MetalHorizon

// The shell scripts behind Play, without Wine: dry runs on fake folders, the relaunch after D3DMetal's Neural Engine
// failure, and the messages a broken setup gets.
final class ScriptTests: XCTestCase {
    override class func setUp() { TestEnvironment.ensure() }
    private var root: URL!
    private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mh-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func touch(_ path: String, executable: Bool = false, contents: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    /// A fake engine (bin/wine prints its arguments), D3DMetal and shim.
    private func fakeComponents(i386: Bool) throws -> [String: String] {
        try touch("engine/bin/wine", executable: true, contents: "#!/bin/bash\necho \"fake wine $*\"\n")
        try touch("engine/bin/wineserver", executable: true, contents: "#!/bin/bash\nexit 0\n")
        try touch("engine/lib/libgnutls.30.dylib")
        if i386 { try touch("engine/lib/wine/i386-windows/ntdll.dll") }
        try touch("d3dm/external/libd3dshared.dylib")
        try touch("d3dm/wine/x86_64-windows/d3d12.dll")
        try touch("shim/x86_64-windows/apd12.dll")
        try touch("shim/x86_64-unix/apd12.so")
        return ["MH_ENGINE": root.appendingPathComponent("engine").path, "MH_D3DMETAL": root.appendingPathComponent("d3dm").path,
                "MH_SHIM": root.appendingPathComponent("shim").path, "MH_LOGS": root.appendingPathComponent("logs").path]
    }

    private func run(_ script: String, _ args: [String] = [], env: [String: String]) throws -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [resources.appendingPathComponent(script).path] + args
        task.environment = env.merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory()]) { a, _ in a }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return (task.terminationStatus, out)
    }

    func testXboxDryRunCarriesTheOptions() throws {
        var env = try fakeComponents(i386: false)
        try touch("FH6/forzahorizon6.exe")
        env.merge(["MH_GAME": root.appendingPathComponent("FH6").path, "MH_XODUS_CLI": "/usr/bin/true", "MH_XODUS_SERVICE": "/usr/bin/true",
                   "MH_DRY_RUN": "1", "MH_GAMEINPUT": "1", "MH_METALFX": "1", "MH_MAX_FPS": "45", "MH_HUD": "0"]) { _, b in b }
        // the game files without their package: a clear stop instead of xodus-cli's bare panic
        var (code, out) = try run("metalhorizon-play.sh", env: env)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(Diagnostics.scan(text: out, source: "t").contains { $0.id == "xodus-package-missing" }, out)
        try touch("FH6/.xodus-streaming.msixvc")
        (code, out) = try run("metalhorizon-play.sh", env: env)
        XCTAssertEqual(code, 0, out)
        for expected in ["WINE_GAMEINPUT=\"1\"", "D3DM_ENABLE_METALFX=\"1\"", "D3DM_MAX_FPS=\"45\"", "WINEMSYNC=\"1\"",
                         "CX_GRAPHICS_BACKEND=\"d3dmetal\"", "D3DM_VENDOR_ID=\"4318\"", "concrt140", "MVK_CONFIG_LOG_LEVEL=\"1\""] {
            XCTAssertTrue(out.contains(expected), "\(expected) missing:\n\(out)")
        }
        XCTAssertFalse(out.contains("MTL_HUD_ENABLED"), out)
        XCTAssertFalse(out.lowercased().contains("crossover"), out)
    }

    func testXboxBrokenLinkSaysWhere() throws {
        var env = try fakeComponents(i386: false)
        let game = root.appendingPathComponent("FH6")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: game.path + "/forzahorizon6.exe", withDestinationPath: "/nowhere/FORZA HORIZON 6/forzahorizon6.exe")
        env.merge(["MH_GAME": game.path, "MH_XODUS_CLI": "/usr/bin/true", "MH_XODUS_SERVICE": "/usr/bin/true", "MH_DRY_RUN": "1"]) { _, b in b }
        let (code, out) = try run("metalhorizon-play.sh", env: env)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(out.contains("which is gone"), out)
        XCTAssertTrue(Diagnostics.scan(text: out, source: "t").contains { $0.id == "broken-game-link" }, out)
    }

    func testSteamPlayDryRunAndStatus() throws {
        var env = try fakeComponents(i386: true)
        let prefix = root.appendingPathComponent("Steam prefix").path
        env.merge(["MH_PREFIX": prefix, "MH_STEAM_APPID": "2483190", "MH_GAMEINPUT": "1"]) { _, b in b }
        // nothing installed yet
        var (code, out) = try run("metalhorizon-steam.sh", ["status"], env: env)
        XCTAssertEqual(code, 0, out)
        var status = SteamStatus.parse(out)
        XCTAssertFalse(status.clientRunning)
        XCTAssertTrue(out.contains("steam_installed=no"), out)
        (code, out) = try run("metalhorizon-steam.sh", ["play"], env: env)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(out.contains("Install Steam first"), out)
        // Steam and the game in its library
        try touch("Steam prefix/drive_c/Program Files (x86)/Steam/steam.exe")
        (code, out) = try run("metalhorizon-steam.sh", ["play"], env: env)
        XCTAssertTrue(out.contains("not in this prefix's Steam library"), out)
        try touch("Steam prefix/drive_c/Program Files (x86)/Steam/steamapps/appmanifest_2483190.acf",
                  contents: "\"AppState\"\n{\n\t\"StateFlags\"\t\t\"4\"\n\t\"buildid\"\t\t\"26422872\"\n}\n")
        var dry = env
        dry["MH_DRY_RUN"] = "1"
        (code, out) = try run("metalhorizon-steam.sh", ["play"], env: dry)
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("-silent -cef-disable-gpu -cef-disable-gpu-compositing -applaunch 2483190"), out)
        XCTAssertTrue(out.contains("fallback: Steam silent on DXMT beside the game"), out)
        XCTAssertTrue(out.contains("WINEMSYNC=\"1\""), out)
        XCTAssertTrue(out.contains("CX_GRAPHICS_BACKEND=\"d3dmetal\""), out)
        XCTAssertTrue(out.contains("WINE_GAMEINPUT=\"1\""), out)
        XCTAssertTrue(out.contains("gameoverlayrenderer64,gameoverlayrenderer=d"), out)
        (code, out) = try run("metalhorizon-steam.sh", ["status"], env: env)
        status = SteamStatus.parse(out)
        XCTAssertTrue(out.contains("steam_installed=yes") && out.contains("game_installed=yes") && out.contains("game_build=26422872"), out)
        XCTAssertTrue(status.engine32bit)
    }

    /// Open with MH_STEAM_URL hands Steam its own install link for the game; anything but a steam:// link is dropped.
    func testSteamOpensOnTheGamesInstallWindow() throws {
        var env = try fakeComponents(i386: true)
        env["MH_PREFIX"] = root.appendingPathComponent("Steam prefix").path
        try touch("Steam prefix/drive_c/Program Files (x86)/Steam/steam.exe")
        let log = root.appendingPathComponent("logs/steam-window.log")
        env["MH_STEAM_URL"] = "steam://install/2483190"
        var (code, out) = try run("metalhorizon-steam.sh", ["open"], env: env)
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("steam://install/2483190"))
        env["MH_STEAM_URL"] = "https://example.com/x"
        (code, out) = try run("metalhorizon-steam.sh", ["open"], env: env)
        XCTAssertEqual(code, 0, out)
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("example.com"))
    }

    func testSteamRefusesAnEngineWithout32BitHalf() throws {
        var env = try fakeComponents(i386: false)
        env["MH_PREFIX"] = root.appendingPathComponent("p").path
        let (code, out) = try run("metalhorizon-steam.sh", ["install"], env: env)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(out.contains("no 32-bit half"), out)
        XCTAssertTrue(Diagnostics.scan(text: out, source: "t").contains { $0.id == "no-32bit-engine" })
    }

    /// mh_run_game relaunches once after the Neural Engine failure, then stops on the clean run.
    /// The native route: Highball's FH6 environment, its own prefix, the 30 cap unless the player chose one.
    func testNativeDryRunCarriesTheRoute() throws {
        try touch("native/engine/bin/wine", executable: true, contents: "#!/bin/bash\necho fake native wine\n")
        try touch("native/engine/lib/libgnutls.30.dylib")
        try touch("native/renderers/vkd3d/wine/aarch64-windows/d3d12.dll")
        try touch("native/renderers/kosmickrisp/kosmickrisp_icd.json", contents: "{}")
        try touch("game/forzahorizon6.exe")
        try touch("game/.xodus-streaming.msixvc")
        var env = ["MH_ROUTE": "native", "MH_NATIVE": root.appendingPathComponent("native").path,
                   "MH_GAME": root.appendingPathComponent("game").path, "MH_XODUS_CLI": "/usr/bin/true",
                   "MH_XODUS_SERVICE": "/usr/bin/true", "MH_LOGS": root.appendingPathComponent("logs").path, "MH_DRY_RUN": "1"]
        var (code, out) = try run("metalhorizon-play.sh", env: env)
        XCTAssertEqual(code, 0, out)
        XCTAssertTrue(out.contains("WINEPREFIX=\"\(root.appendingPathComponent("game").path)/.metalhorizon-native\""), out)
        XCTAssertTrue(out.contains("VKD3D_FEATURE_LEVEL=\"12_1\""), out)
        XCTAssertTrue(out.contains("DXVK_FRAME_RATE=\"30\""), out)
        XCTAssertTrue(out.contains("HB_PRESENT_PACE_FPS=\"30\""), out)
        XCTAssertTrue(out.contains("FEX_SMCCHECKS=\"mtrack\""), out)
        XCTAssertTrue(out.contains("dxgi,d3d11,d3d10core,d3d12,d3d12core=n,b"), out)
        XCTAssertTrue(out.contains("customVendorId=8086"), out)
        XCTAssertFalse(out.contains("CX_GRAPHICS_BACKEND"), "no D3DMetal on the native route: \(out)")
        env["MH_MAX_FPS"] = "45"
        (code, out) = try run("metalhorizon-play.sh", env: env)
        XCTAssertTrue(out.contains("DXVK_FRAME_RATE=\"45\""), out)
        XCTAssertFalse(out.contains("HB_PRESENT_PACE_FPS"), "45 does not divide 60 Hz: no pacing slot")
        // a native route without its loader stops with the line the diagnosis knows
        try FileManager.default.removeItem(at: root.appendingPathComponent("native/engine/bin/wine"))
        env.removeValue(forKey: "MH_DRY_RUN")
        (code, out) = try run("metalhorizon-play.sh", env: env)
        XCTAssertNotEqual(code, 0)
        XCTAssertTrue(Diagnostics.scan(text: out, source: "t").contains { $0.id == "native-loader" }, out)
    }

    /// A licence request nobody answers ends the run with the line the diagnosis knows, and stops the xodus process.
    func testLicenceRequestThatNeverAnswersIsStopped() throws {
        let log = root.appendingPathComponent("game.log")
        try "Requesting the Forza Horizon 6 package license…\n".write(to: log, atomically: true, encoding: .utf8)
        let marker = "mh-test-xodus-\(UUID().uuidString.prefix(8))"
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/bash")
        sleeper.arguments = ["-c", "exec -a \(marker) sleep 60"]
        try sleeper.run()
        let script = ". '\(resources.appendingPathComponent("metalhorizon-common.sh").path)'; mh_keychain_watch '\(log.path)' '\(marker)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        task.environment = ["PATH": "/usr/bin:/bin", "MH_WATCH_STEP": "1", "MH_LICENCE_SLOW": "2", "MH_LICENCE_TIMEOUT": "4"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        sleeper.waitUntilExit()
        if !out.contains("Keychain") {   // a real Keychain dialog on this Mac would make the watch wait for the player
            XCTAssertTrue(out.contains("NOTE: the Xbox licence servers have not answered"), out)
            XCTAssertTrue(out.contains("STOP: the Xbox licence request did not answer"), out)
            XCTAssertTrue(Diagnostics.scan(text: out, source: "t").contains { $0.id == "xodus-licence-timeout" })
            XCTAssertNotEqual(sleeper.terminationStatus, 0, "the stuck xodus process is stopped")
        }
    }

    func testInvalidProfileIsRecognized() {
        XCTAssertTrue(Diagnostics.scan(text: "Code d'erreur : E:43-1b-4", source: "t").contains { $0.id == "forza-invalid-profile" })
    }

    func testRelaunchAfterNeuralEngineFailure() throws {
        let env = try fakeComponents(i386: false)
        let counter = root.appendingPathComponent("count").path
        try touch("fakegame", executable: true, contents: """
            #!/bin/bash
            n=$(cat "\(counter)" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "\(counter)"
            if [ $n -eq 1 ]; then echo ' Error Domain=com.apple.appleneuralengine Code=26 "doCompileModel:csIdentity"'; exit 1; fi
            echo "fine"; exit 0
            """)
        let log = root.appendingPathComponent("game.log").path
        let script = ". '\(resources.appendingPathComponent("metalhorizon-common.sh").path)'; ENGINE='\(env["MH_ENGINE"]!)'; mh_run_game '\(log)' '\(root.appendingPathComponent("fakegame").path)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        task.environment = ["PATH": "/usr/bin:/bin", "MH_RETRIES": "2"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, out)
        XCTAssertTrue(out.contains("== launch 2"), out)
        XCTAssertFalse(out.contains("== launch 3"), out)
        XCTAssertEqual(try String(contentsOfFile: counter, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "2")
        let logText = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(Diagnostics.scan(text: logText, source: "t").isEmpty, "a retried failure is not reported again: \(logText)")
    }
}
