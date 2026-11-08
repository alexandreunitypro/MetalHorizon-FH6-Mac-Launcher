import Foundation

// MetalHorizon 1.0's second way to run the game: Blackwell Engine Native, a Wine that runs natively on Apple silicon
// (Wine 11.18 for arm64 with Highball's arm64 patches and Blackwell's Xbox patches, FEX for the game's x86-64 code,
// vkd3d-proton on KosmicKrisp for Direct3D 12). It has no hitch every second: under Rosetta the game's copy
// protection rewrites its own code and Rosetta translates it again, about once a second; FEX keeps those
// translations (Highball's FEX patches), so the frame time stays even. It runs at a steady 30 frames a second where
// D3DMetal reaches up to 50 with the hitch: steady against fast (Highball's measurements on a base M4).
//
// A native Wine needs Apple's cross-architecture entitlement on its loader process, which only a signed app bundle
// with a provisioning profile can carry. MetalHorizon uses Highball's signed loader, WineLoader.app, taken from
// Highball's official release and checked against Highball's Developer ID team before it is used; every native
// `wine` is a symlink to it (as in Highball's EngineStore.linkSignedLoader).

/// Which engine Play uses. Automatic decides on each Play from this Mac and from how the last runs went.
enum EngineRoute: String, CaseIterable, Identifiable {
    case automatic, native, d3dmetal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .native: return "Native Apple silicon"
        case .d3dmetal: return "D3DMetal (Rosetta)"
        }
    }
}

/// The two engines a run can actually use.
enum ResolvedRoute: String {
    case native, d3dmetal
    var title: String { self == .native ? "Native Apple silicon" : "D3DMetal" }
    var shortExplanation: String {
        self == .native
            ? "Steady 30 frames a second, no hitch every second."
            : "Up to 50 frames a second, with a short hitch about once a second."
    }
}

/// Where the native pieces live.
let installedNativeDirectory = supportDirectory.appendingPathComponent("Blackwell Engine Native").path
let wineLoaderAppDirectory = supportDirectory.appendingPathComponent("WineLoader.app").path
/// Highball's Developer ID team: the only signer MetalHorizon accepts for the loader.
let wineLoaderTeam = "B95M7DARU4"
let wineLoaderIdentifier = "app.highball.WineLoader"

/// What decides whether the native engine can run here.
struct MachineFacts {
    var appleSilicon: Bool
    var macOSMajor: Int
    var macOSMinor: Int
    var memoryGB: Int

    static var current: MachineFacts {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isArm = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
        return MachineFacts(appleSilicon: isArm, macOSMajor: v.majorVersion, macOSMinor: v.minorVersion,
                            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824))
    }

    /// Highball's route needs macOS 27 and measured the game's footprint against 32 GB; 24 GB Macs are allowed
    /// with the lower settings the route writes, below that the native engine is not offered automatically.
    static let nativeMinMemoryGB = 24
    var nativeSupported: Bool { appleSilicon && macOSMajor >= 27 }
    var nativeRecommended: Bool { nativeSupported && memoryGB >= MachineFacts.nativeMinMemoryGB }
}

enum NativeEngine {
    static var directory: String { ProcessInfo.processInfo.environment["MH_NATIVE"] ?? installedNativeDirectory }
    static var engine: String { directory + "/engine" }
    static var loaderBinary: String { wineLoaderAppDirectory + "/Contents/MacOS/wine" }
    static var unixLoaderLink: String { engine + "/lib/wine/aarch64-unix/wine" }
    static var binLoaderLink: String { engine + "/bin/wine" }

    static var filesPresent: Bool {
        fileExists(engine + "/lib/wine/aarch64-unix/ntdll.so")
            && fileExists(engine + "/lib/wine/aarch64-windows/xtajit64.dll")
            && fileExists(engine + "/lib/wine/aarch64-windows/xgameruntime.dll")
            && fileExists(directory + "/renderers/vkd3d/wine")
            && fileExists(directory + "/renderers/kosmickrisp/kosmickrisp_icd.json")
    }

    static var loaderPresent: Bool { FileManager.default.isExecutableFile(atPath: loaderBinary) }

    /// Both links point at the signed loader (a dangling or stale link is not linked).
    static var linked: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: unixLoaderLink)) == loaderBinary
            && (try? FileManager.default.destinationOfSymbolicLink(atPath: binLoaderLink)) == "../lib/wine/aarch64-unix/wine"
    }

    /// Points the engine's `wine` at the signed loader. The engine's own loader is kept aside, never used: it
    /// cannot start on arm64 without the entitlement.
    static func linkLoader() throws {
        let fm = FileManager.default
        for (link, target) in [(unixLoaderLink, loaderBinary), (binLoaderLink, "../lib/wine/aarch64-unix/wine")] {
            if let existing = try? fm.destinationOfSymbolicLink(atPath: link) {
                if existing == target { continue }
                try fm.removeItem(atPath: link)
            } else if fm.fileExists(atPath: link) {
                let aside = link + ".unsigned"
                try? fm.removeItem(atPath: aside)
                try fm.moveItem(atPath: link, toPath: aside)
            }
            try fm.createDirectory(atPath: (link as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        }
    }

    /// The loader is Highball's, signed by its Developer ID team and notarized, with the cross-architecture
    /// entitlement. Anything else is refused: MetalHorizon never runs a loader it cannot attribute.
    static func loaderSignatureValid(at app: String = wineLoaderAppDirectory) -> Bool {
        guard fileExists(app) else { return false }
        guard run("/usr/bin/codesign", ["--verify", "--strict", app]).status == 0 else { return false }
        let info = run("/usr/bin/codesign", ["-dv", "--verbose=2", app]).output
        guard info.contains("TeamIdentifier=\(wineLoaderTeam)"), info.contains("Identifier=\(wineLoaderIdentifier)") else { return false }
        let entitlements = run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", app]).output
        return entitlements.contains("com.apple.developer.cross-architecture-support")
    }

    static func check(facts: MachineFacts = .current) -> Check {
        guard facts.appleSilicon else {
            return Check(ok: false, text: "Needs an Apple silicon Mac", fix: "This Mac runs the game on D3DMetal.")
        }
        guard facts.macOSMajor >= 27 else {
            return Check(ok: false, text: "Needs macOS 27", fix: "Update macOS to use the native engine; D3DMetal runs the game meanwhile.")
        }
        guard filesPresent else {
            return Check(ok: false, text: "Not installed yet", fix: "MetalHorizon installs it by itself when the native engine is used.")
        }
        guard loaderPresent else {
            return Check(ok: false, text: "Its signed loader is missing", fix: "MetalHorizon installs Highball's signed loader by itself.")
        }
        let version = (try? String(contentsOfFile: directory + "/VERSION", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Check(ok: true, text: "Blackwell Engine Native \(version)".trimmingCharacters(in: .whitespaces),
                     fix: linked ? nil : "Its loader link is repaired before the next Play.")
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        guard (try? task.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// How each engine fared in the last runs: the automatic choice and the Autopilot read it. Kept in
/// ~/Library/Application Support/MetalHorizon/route-health.json.
struct RouteHealth: Codable, Equatable {
    struct Record: Codable, Equatable {
        var failures: [Date] = []       // runs that ended in a crash or a start-up failure
        var lastSuccess: Date?          // a run that lasted and ended cleanly
        var benchedUntil: Date?         // the Autopilot keeps this engine aside until then
        var benchReason: String?
    }
    var native = Record()
    var d3dmetal = Record()

    static var file: URL { supportDirectory.appendingPathComponent("route-health.json") }

    static func load() -> RouteHealth {
        guard let data = try? Data(contentsOf: file),
              let health = try? JSONDecoder.iso.decode(RouteHealth.self, from: data) else { return RouteHealth() }
        return health
    }

    func save() {
        if let data = try? JSONEncoder.iso.encode(self) { try? data.write(to: RouteHealth.file, options: .atomic) }
    }

    subscript(route: ResolvedRoute) -> Record {
        get { route == .native ? native : d3dmetal }
        set { if route == .native { native = newValue } else { d3dmetal = newValue } }
    }

    func isBenched(_ route: ResolvedRoute, now: Date = Date()) -> Bool {
        guard let until = self[route].benchedUntil else { return false }
        return until > now
    }

    /// Failures in the last day, after the last success.
    func recentFailures(_ route: ResolvedRoute, now: Date = Date()) -> Int {
        let record = self[route]
        return record.failures.filter { failure in
            now.timeIntervalSince(failure) < 86_400 && (record.lastSuccess.map { failure > $0 } ?? true)
        }.count
    }

    mutating func recordFailure(_ route: ResolvedRoute, at date: Date = Date()) {
        var record = self[route]
        record.failures = (record.failures + [date]).suffix(20)
        self[route] = record
    }

    mutating func recordSuccess(_ route: ResolvedRoute, at date: Date = Date()) {
        var record = self[route]
        record.lastSuccess = date
        record.benchedUntil = nil
        record.benchReason = nil
        self[route] = record
    }

    mutating func bench(_ route: ResolvedRoute, for interval: TimeInterval, reason: String, now: Date = Date()) {
        var record = self[route]
        record.benchedUntil = now.addingTimeInterval(interval)
        record.benchReason = reason
        self[route] = record
    }

    mutating func clearBench(_ route: ResolvedRoute) {
        var record = self[route]
        record.benchedUntil = nil
        record.benchReason = nil
        self[route] = record
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}

/// The engine a Play uses, and why: the player's choice, or the automatic one.
struct RouteDecision: Equatable {
    var route: ResolvedRoute
    var reason: String

    /// Automatic: the native engine on a Mac that can run it well, unless the Autopilot benched it after it failed;
    /// D3DMetal otherwise. A forced choice the Mac cannot honour falls back too, saying so.
    static func decide(preference: EngineRoute, edition: Edition, facts: MachineFacts, health: RouteHealth,
                       nativeAvailable: Bool, now: Date = Date()) -> RouteDecision {
        // The Steam edition stays on D3DMetal in 1.0: its Steam client and the game share one prefix, and the
        // native engine needs a prefix of its own (Steam would download the game again).
        if edition == .steam {
            return RouteDecision(route: .d3dmetal, reason: "The Steam edition runs on D3DMetal in this version.")
        }
        switch preference {
        case .d3dmetal:
            return RouteDecision(route: .d3dmetal, reason: "You chose D3DMetal in Settings.")
        case .native:
            if !facts.nativeSupported {
                return RouteDecision(route: .d3dmetal, reason: "The native engine needs an Apple silicon Mac with macOS 27; D3DMetal runs the game.")
            }
            return RouteDecision(route: .native, reason: "You chose the native engine in Settings.")
        case .automatic:
            if !facts.nativeSupported {
                return RouteDecision(route: .d3dmetal, reason: "The native engine needs macOS 27 on Apple silicon.")
            }
            if !facts.nativeRecommended {
                return RouteDecision(route: .d3dmetal, reason: "The native engine wants \(MachineFacts.nativeMinMemoryGB) GB of memory or more; this Mac has \(facts.memoryGB) GB.")
            }
            if health.isBenched(.native, now: now) {
                return RouteDecision(route: .d3dmetal, reason: health.native.benchReason ?? "The native engine failed on this Mac; D3DMetal runs the game for now.")
            }
            if !nativeAvailable {
                return RouteDecision(route: .d3dmetal, reason: "The native engine is not available yet; D3DMetal runs the game.")
            }
            return RouteDecision(route: .native, reason: "No hitch every second on this Mac.")
        }
    }
}
