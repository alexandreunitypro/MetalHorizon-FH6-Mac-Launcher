import Foundation

// MetalHorizon's Autopilot: what the app checks and repairs by itself, before each Play and after each run, so the
// player never has to read a log. Two rules hold everywhere:
//   1. Never touch the player's data: saves, the game's files and the sign-in are only ever read. A repair rebuilds
//      something MetalHorizon made (a link, a component, a running service), or changes one of its own settings.
//   2. Every action is written down (repairs.json, shown in the window and in Export Diagnostics), with what was
//      seen and what was done, and a setting the Autopilot changed is one the player can change back.

/// One thing the Autopilot did.
struct Repair: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String          // what was done, in a few words
    var detail: String         // what was seen and why this fixes it
    var kind: Kind

    enum Kind: String, Codable {
        case fixed          // something was repaired
        case reconfigured   // a setting was changed
        case relaunched     // the game was started again
        case switchedEngine // the run moved to the other engine
        case note           // seen, nothing to change
    }
}

enum RepairLog {
    static var file: URL { logDirectory.appendingPathComponent("repairs.json") }

    static func all() -> [Repair] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder.iso.decode([Repair].self, from: data) else { return [] }
        return list
    }

    /// The repairs of the last day, newest first.
    static func recent(within interval: TimeInterval = 86_400, now: Date = Date()) -> [Repair] {
        all().filter { now.timeIntervalSince($0.date) < interval }.sorted { $0.date > $1.date }
    }

    static func record(_ repair: Repair) {
        var list = all()
        list.append(repair)
        if let data = try? JSONEncoder.iso.encode(Array(list.suffix(200))) { try? data.write(to: file, options: .atomic) }
        // the same line in repairs.log, which Export Diagnostics has always carried
        let line = "\(ISO8601DateFormatter().string(from: repair.date)) [\(repair.kind.rawValue)] \(repair.title): \(repair.detail)\n"
        let text = logDirectory.appendingPathComponent("repairs.log")
        if let handle = try? FileHandle(forWritingTo: text) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(to: text, atomically: true, encoding: .utf8)
        }
    }
}

/// How a run ended, as the Autopilot sees it.
struct RunOutcome {
    var route: ResolvedRoute
    var exitCode: Int32
    var duration: TimeInterval
    var findings: [Finding]
    var userStopped: Bool          // Force Quit or Stop: never a failure to act on
    var options: (metalFX: Bool, maxFPS: Int)

    /// A run that lasted, or ended cleanly after the game had time to start.
    /// The log shows the game itself crashed. Its exit code says nothing: Wine's debugger and the game's own crash
    /// window (FHE01) end with exit 0 (issue #14: five crashes in a row, none seen as a failure).
    var crashed: Bool {
        has("wine-unimplemented", "page-fault", "macos-abort", "native-emulator-crash", "native-device-lost", "native-vulkan-driver", "killed-9")
    }
    var succeeded: Bool { !userStopped && !crashed && (duration >= 300 || (exitCode == 0 && duration >= 90)) }
    var failed: Bool { !userStopped && !succeeded && (crashed || exitCode != 0 || duration < 90) }

    func has(_ ids: String...) -> Bool { findings.contains { ids.contains($0.id) } }

    /// A failure the engine causes (a crash before the game got going, the graphics device lost, the emulator),
    /// rather than the account, the network or the game's files, which another engine would not change.
    var engineFailure: Bool {
        guard failed else { return false }
        if has("xodus-package-missing", "xbox-not-downloaded", "forza-invalid-profile", "steam-auth", "stop-message",
               "xodus-service-down", "xodus-license") { return false }
        return has("wine-unimplemented", "page-fault", "macos-abort", "native-emulator-crash", "native-device-lost", "native-vulkan-driver",
                   "gpu-unsupported", "fhe21-amd", "concrt-crash") || (exitCode != 0 && duration < 120)
    }
}

/// What the Autopilot decided after a run.
struct AfterRunDecision {
    var repairs: [Repair] = []
    var relaunch: ResolvedRoute?        // start the game again at once, on this engine
    var disableMetalFX = false
    var syncOff = false
    var reassembleShim = false
    var restartXboxService = false
}

enum Autopilot {
    /// The rules, applied to a run that just ended. `health` is updated in place (and saved by the caller).
    /// `alreadyRelaunched`: the Play click already got its one automatic relaunch.
    static func afterRun(_ run: RunOutcome, health: inout RouteHealth, nativeAvailable: Bool, facts: MachineFacts,
                         preference: EngineRoute, alreadyRelaunched: Bool, now: Date = Date()) -> AfterRunDecision {
        var decision = AfterRunDecision()
        if run.userStopped { return decision }
        if run.succeeded {
            let wasBenched = health.isBenched(run.route, now: now)
            health.recordSuccess(run.route, at: now)
            if wasBenched {
                decision.repairs.append(Repair(title: "\(run.route.title) is back in use",
                                               detail: "A run on it lasted; the Autopilot no longer keeps it aside.", kind: .note))
            }
            return decision
        }
        guard run.failed else { return decision }
        health.recordFailure(run.route, at: now)

        // Options that are known to take a run down: off for the next one, said so.
        if run.options.metalFX && run.route == .d3dmetal && run.engineFailure {
            decision.disableMetalFX = true
            decision.repairs.append(Repair(title: "MetalFX upscaling turned off",
                                           detail: "The game stopped early with MetalFX on; the next run goes without it (Settings › Graphics turns it back on).",
                                           kind: .reconfigured))
        }
        if run.has("msync-mismatch") {
            decision.syncOff = true
            decision.repairs.append(Repair(title: "Sync mode set to plain",
                                           detail: "Wine could not set up msync (bootstrap_look_up); the next run uses Wine's plain synchronization.",
                                           kind: .reconfigured))
        }
        if run.has("fh205", "fhe21") && run.route == .d3dmetal {
            decision.reassembleShim = true
            decision.repairs.append(Repair(title: "DirectX 12 shim rebuilt",
                                           detail: "The game refused the graphics card (FH205 / FHE21): the shim that presents D3DMetal as an NVIDIA card is put together again.",
                                           kind: .fixed))
        }

        // The licence never answered: a fresh Xbox service and one more try, on the same engine.
        if run.has("xodus-licence-timeout") {
            decision.restartXboxService = true
            decision.repairs.append(Repair(title: "Xbox service restarted",
                                           detail: "The licence request got no answer for 3 minutes; the next try starts a fresh xodus-service.",
                                           kind: .fixed))
            if !alreadyRelaunched {
                decision.relaunch = run.route
                decision.repairs.append(Repair(title: "Game started again", detail: "One more try after the licence request timed out.", kind: .relaunched))
            }
            return decision
        }

        guard run.engineFailure else { return decision }

        // The engine stopped the game. Twice in a day on one engine: that engine is set aside for three days and the
        // other one runs the game. A forced choice in Settings is respected, only noted.
        let other: ResolvedRoute = run.route == .native ? .d3dmetal : .native
        let otherUsable = other == .d3dmetal || (nativeAvailable && facts.nativeSupported && !health.isBenched(.native, now: now))
        let failures = health.recentFailures(run.route, now: now)
        if failures >= 2 && preference == .automatic && otherUsable {
            health.bench(run.route, for: 3 * 86_400,
                         reason: "\(run.route.title) stopped the game \(failures) times today; \(other.title) runs it for the next three days.",
                         now: now)
            decision.repairs.append(Repair(title: "Switched to \(other.title)",
                                           detail: "\(run.route.title) stopped the game \(failures) times today. The Autopilot keeps it aside for three days; Settings › Graphics can bring it back now.",
                                           kind: .switchedEngine))
        }
        // One automatic relaunch per Play, on the engine the next Play would use, when the game stopped before it
        // got going: most early stops are timing, and the player should not have to click again.
        if !alreadyRelaunched && (run.duration < 180 || (run.crashed && run.duration < 600)) {
            let next: ResolvedRoute = health.isBenched(run.route, now: now) && otherUsable ? other : run.route
            decision.relaunch = next
            decision.repairs.append(Repair(title: "Game started again\(next == run.route ? "" : " on \(next.title)")",
                                           detail: "It stopped \(Int(run.duration)) s after Play (exit \(run.exitCode)); one automatic relaunch.",
                                           kind: .relaunched))
        }
        return decision
    }

    /// Before Play: what can be repaired without asking, repaired. Returns what was done; throws nothing (a repair
    /// that fails is written down and Play goes on, the run's own checks stop it if they must).
    static func beforePlay(setup: Setup, route: ResolvedRoute, runtime: URL = URL(fileURLWithPath: "/private/tmp/xodus-runtime-test")) -> [Repair] {
        var done: [Repair] = []
        if route == .native {
            if NativeEngine.filesPresent && NativeEngine.loaderPresent && !NativeEngine.linked {
                do {
                    try NativeEngine.linkLoader()
                    done.append(Repair(title: "Native engine's loader link repaired",
                                       detail: "The engine's wine pointed somewhere else (the app or the loader moved); it points at the signed loader again.",
                                       kind: .fixed))
                } catch {
                    done.append(Repair(title: "Could not repair the native engine's loader link", detail: "\(error)", kind: .note))
                }
            }
        }
        // xodus-service alive without its socket: it cannot answer the game, which then fails to sign in. A stale one
        // goes; the Play script starts a fresh one.
        if setup.edition == .xbox {
            let socket = runtime.appendingPathComponent("xodus.sock").path
            if NativeEngine.run("/usr/bin/pgrep", ["-f", "xodus-service"]).status == 0 && !fileExists(socket) {
                NativeEngine.run("/usr/bin/pkill", ["-f", "xodus-service"])
                done.append(Repair(title: "Xbox service restarted",
                                   detail: "xodus-service was running without its socket, so the game could not reach the Xbox account; a fresh one starts with Play.",
                                   kind: .fixed))
            }
        }
        // Leftovers of a run that crashed: a wineserver still holding the prefix makes the next start hang.
        let engine = route == .native ? NativeEngine.engine : setup.engine
        let prefix = route == .native ? setup.nativePrefix : setup.prefix
        if fileExists(engine + "/bin/wineserver"), fileExists(prefix),
           NativeEngine.run("/usr/bin/pgrep", ["-f", "forzahorizon6.exe"]).status != 0 {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: engine + "/bin/wineserver")
            task.arguments = ["-k"]
            task.environment = ["WINEPREFIX": prefix]
            if (try? task.run()) != nil { task.waitUntilExit() }
        }
        return done
    }
}
