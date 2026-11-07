import Foundation

// What the app and its MCP server share: the settings, where MetalHorizon installs its components, and the checks
// that say whether Play can work. Nothing here comes from CrossOver.app.

let appBundleID = "io.github.alexandreunitypro.metalhorizon"
let storeProductID = "9nr1r1xwlcnb"   // Forza Horizon 6, Xbox / Microsoft Store edition
let supportURL = URL(string: "https://buymeacoffee.com/zaidalexandre")!
let issuesURL = URL(string: "https://github.com/alexandreunitypro/MetalHorizon-FH6-Mac-Launcher/issues")!

enum SettingKey {
    static let edition = "metalhorizon.edition"
    static let gameDirectory = "metalhorizon.gameDirectory"
    static let steamPrefix = "metalhorizon.steamPrefix"
    static let engineDirectory = "metalhorizon.engineDirectory"
    static let d3dmetalDirectory = "metalhorizon.d3dmetalDirectory"
    static let metalHUD = "metalhorizon.metalHUD"
    static let controllerMode = "metalhorizon.controllerMode"
    static let metalFX = "metalhorizon.metalFX"
    static let maxFPS = "metalhorizon.maxFPS"
    static let autoRetry = "metalhorizon.autoRetry"
    static let appleLicenseAccepted = "metalhorizon.appleLicenseAccepted"   // the D3DMetal version accepted
    static let welcomeShown = "metalhorizon.welcomeShown"
}

/// Which copy of the game: the Xbox / Microsoft Store one (xodus signs in and downloads it) or the Steam one
/// (Steam itself, inside a prefix MetalHorizon manages).
enum Edition: String, CaseIterable, Identifiable {
    case xbox, steam
    var id: String { rawValue }
    var title: String { self == .xbox ? "Xbox / Microsoft Store" : "Steam" }
}

/// The app's settings. Run from a development build (no bundle identifier), the same domain is used by name.
func settingsStore() -> UserDefaults {
    Bundle.main.bundleIdentifier == appBundleID ? .standard : (UserDefaults(suiteName: appBundleID) ?? .standard)
}

func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }

/// ~/Library/Logs/MetalHorizon; MH_LOG_DIR puts it elsewhere (the tests use a throwaway folder).
let logDirectory: URL = {
    let dir = ProcessInfo.processInfo.environment["MH_LOG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MetalHorizon")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

/// ~/Library/Application Support/MetalHorizon: Blackwell Engine, D3DMetal and the DirectX 12 shim live here.
/// MH_SUPPORT_DIR puts them elsewhere (the installer's tests use a throwaway folder).
let supportDirectory: URL = {
    let dir = ProcessInfo.processInfo.environment["MH_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MetalHorizon")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
let installedEngineDirectory = supportDirectory.appendingPathComponent("Blackwell Engine").path
/// The Steam variant (engine/series-steam): the 32-bit half Steam needs, Highball's patches for a launcher's own
/// window, and DXMT, the renderer Steam's window draws with.
let installedSteamEngineDirectory = supportDirectory.appendingPathComponent("Blackwell Engine Steam").path
let installedD3DMetalDirectory = supportDirectory.appendingPathComponent("D3DMetal").path
/// The Steam edition's prefix: Steam and the game in one place. Its Windows path for the game,
/// C:\Program Files (x86)\Steam\steamapps\common\ForzaHorizon6, is short whatever the Mac path is, which is what
/// the game's "Installation path is too long" check reads.
let defaultSteamPrefix = supportDirectory.appendingPathComponent("Steam").path
/// Highball's shim in front of Apple's d3d12: d3d12.dll (the shim), apd12.dll (Apple's d3d12.dll, export renamed on
/// this Mac) and apd12.so (a link to Apple's d3d12.so, so it is the same image as dxgi.so and d3d12core.so).
let shimDirectory = supportDirectory.appendingPathComponent("Shim/wine").path

/// One line of the setup: whether it is usable, what was found, and what to do if it is not.
struct Check {
    var ok: Bool
    var text: String
    var fix: String? = nil
}

struct Setup {
    var edition = Edition.xbox
    var gameDirectory = ""
    var steamPrefix = ""          // empty: MetalHorizon's own (defaultSteamPrefix)
    var engineDirectory = ""      // empty: the installed Blackwell Engine for the edition
    var d3dmetalDirectory = ""    // empty: the installed D3DMetal
    var metalHUD = true
    var controllerMode = ControllerMode.automatic
    var metalFX = false
    var maxFPS = 0
    var autoRetry = true

    static func load() -> Setup {
        let defaults = settingsStore()
        var setup = Setup()
        setup.edition = Edition(rawValue: defaults.string(forKey: SettingKey.edition) ?? "") ?? .xbox
        setup.gameDirectory = defaults.string(forKey: SettingKey.gameDirectory) ?? expandTilde("~/FH6")
        setup.steamPrefix = defaults.string(forKey: SettingKey.steamPrefix) ?? ""
        setup.engineDirectory = defaults.string(forKey: SettingKey.engineDirectory) ?? ""
        setup.d3dmetalDirectory = defaults.string(forKey: SettingKey.d3dmetalDirectory) ?? ""
        setup.metalHUD = defaults.object(forKey: SettingKey.metalHUD) as? Bool ?? true
        setup.controllerMode = ControllerMode(rawValue: defaults.string(forKey: SettingKey.controllerMode) ?? "") ?? .automatic
        setup.metalFX = defaults.bool(forKey: SettingKey.metalFX)
        setup.maxFPS = defaults.integer(forKey: SettingKey.maxFPS)
        setup.autoRetry = defaults.object(forKey: SettingKey.autoRetry) as? Bool ?? true
        return setup
    }

    /// Each edition has its engine; a manual override (engineDirectory) still wins.
    var engine: String {
        if !engineDirectory.isEmpty { return engineDirectory }
        return edition == .steam ? installedSteamEngineDirectory : installedEngineDirectory
    }
    var d3dmetal: String { d3dmetalDirectory.isEmpty ? installedD3DMetalDirectory : d3dmetalDirectory }
    var steamPrefixPath: String { steamPrefix.isEmpty ? defaultSteamPrefix : steamPrefix }
    var steam: SteamFiles { SteamFiles(prefix: steamPrefixPath) }

    /// The engine folder from whatever was picked: the folder itself, its bin/ or bin/wine.
    static func normalizeEngine(_ path: String) -> String {
        var p = expandTilde(path)
        if p.hasSuffix("/bin/wine") { p = String(p.dropLast(9)) }
        if p.hasSuffix("/bin") { p = String(p.dropLast(4)) }
        return p
    }

    /// The folder that holds external/ and wine/ (Apple's redist/lib), from the toolkit's root or redist/.
    static func normalizeD3DMetal(_ path: String) -> String {
        let p = expandTilde(path)
        let candidates = [p, p + "/redist/lib", p + "/lib"]
        return candidates.first { fileExists($0 + "/external/libd3dshared.dylib") } ?? p
    }

    /// A folder that looks like a Wine prefix with Steam in it (a Highball, CrossOver or Whisky bottle).
    static func looksLikeSteamPrefix(_ path: String) -> Bool {
        fileExists(path + "/drive_c") && SteamFiles(prefix: path).installed
    }

    /// Where the Xbox package went when it did not move with the game: the usual places, a real file of some size.
    /// Returns its real path (links resolved).
    static func findXboxPackage(besides folder: String, searching: [String]? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let parent = (folder as NSString).deletingLastPathComponent
        let places = searching ?? [home + "/Desktop", home + "/FH6", home + "/Downloads", home + "/Documents", parent]
        for dir in places where dir != folder {
            let real = URL(fileURLWithPath: dir + "/.xodus-streaming.msixvc").resolvingSymlinksInPath().path
            guard real != URL(fileURLWithPath: folder + "/.xodus-streaming.msixvc").resolvingSymlinksInPath().path else { continue }
            if let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? Int64, size > 100_000_000 {
                return real
            }
        }
        return nil
    }

    static func tildePath(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    /// The package left behind when the game files were moved (seen on a player's Mac: the game in ~/Documents, its
    /// package still on the Desktop) goes back into the game folder by itself, when that is safe: the game is there
    /// without its package, one real package was found in the usual places, and it is on the same disk, so the move is
    /// a rename (instant, nothing copied, nothing deleted). A link stays at the old place for anything that used it.
    /// Returns what was done, or nil when nothing was (nothing to do, or not safe: then the Setup line explains it).
    static func repairXboxPackage(in folder: String, searching: [String]? = nil) -> String? {
        let fm = FileManager.default
        let target = folder + "/.xodus-streaming.msixvc"
        guard !folder.isEmpty, fileExists(folder + "/forzahorizon6.exe"), !fileExists(target),
              let source = findXboxPackage(besides: folder, searching: searching) else { return nil }
        let volume: (String) -> AnyHashable? = { path in
            (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? AnyHashable
        }
        guard let a = volume(source), let b = volume(folder), a == b else { return nil }
        // a dangling link where the package belongs (left by an earlier move) is replaced; it points nowhere
        if (try? fm.destinationOfSymbolicLink(atPath: target)) != nil { try? fm.removeItem(atPath: target) }
        do {
            try fm.moveItem(atPath: source, toPath: target)
        } catch {
            return nil
        }
        try? fm.createSymbolicLink(atPath: source, withDestinationPath: target)
        let note = "Moved the game's package (.xodus-streaming.msixvc) from \(tildePath((source as NSString).deletingLastPathComponent)) into the game folder; a link stays at the old place."
        let log = logDirectory.appendingPathComponent("repairs.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(source) -> \(target)\n"
        if let handle = try? FileHandle(forWritingTo: log) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try? line.write(to: log, atomically: true, encoding: .utf8) }
        return note
    }

    /// Steam installs carry steam_api64.dll and live under steamapps/common; the Xbox edition has neither.
    static func looksLikeSteamGameFolder(_ path: String) -> Bool {
        fileExists(path + "/steam_api64.dll") || path.lowercased().contains("/steamapps/common/")
    }

    var gameCheck: Check {
        edition == .steam ? steamGameCheck : xboxGameCheck
    }

    var xboxGameCheck: Check {
        guard !gameDirectory.isEmpty else {
            return Check(ok: false, text: "Choose a folder with a short path, such as ~/FH6",
                         fix: "Pick a real folder with a short path (~/FH6), not in iCloud Drive, then Download from Xbox.")
        }
        let resolved = URL(fileURLWithPath: gameDirectory).resolvingSymlinksInPath().path
        if resolved != gameDirectory {
            return Check(ok: false, text: "This folder is a link; choose the real folder (\(resolved))",
                         fix: "xodus resolves links, so the game folder itself must have the short name: pick \(resolved) or rename it.")
        }
        let exe = gameDirectory + "/forzahorizon6.exe"
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: exe), !fileExists(exe) {
            return Check(ok: false, text: gameDirectory + " · the game files moved",
                         fix: "forzahorizon6.exe here points to \(target), which is gone. Choose the folder the game is really in, or move it back.")
        }
        if Setup.looksLikeSteamGameFolder(gameDirectory) {
            return Check(ok: false, text: gameDirectory + " · this is a Steam copy",
                         fix: "Switch the edition to Steam at the top of the window: the Steam copy runs through Steam.")
        }
        let package = gameDirectory + "/.xodus-streaming.msixvc"
        if fileExists(exe) && !fileExists(package) {
            let moved = (try? FileManager.default.destinationOfSymbolicLink(atPath: package)).map { " (its link points to \($0), which is gone)" } ?? ""
            let interrupted = fileExists(gameDirectory + "/.xodus-streaming-tmp.msixvc")
                ? " The .xodus-streaming-tmp.msixvc here is what an interrupted download leaves, not the package." : ""
            let found = Setup.findXboxPackage(besides: gameDirectory).map {
                " It is at \(Setup.tildePath($0)), on another disk: move it into this folder (Finder: Cmd-Shift-. shows hidden files)."
            } ?? " Move it here, or Download from Xbox again."
            return Check(ok: false, text: gameDirectory + " · the game's package is missing",
                         fix: "The hidden file .xodus-streaming.msixvc is not in this folder\(moved): it did not move with the game files.\(interrupted)\(found)")
        }
        if fileExists(exe) { return Check(ok: true, text: gameDirectory) }
        return Check(ok: false, text: gameDirectory + " · not downloaded yet",
                     fix: "Sign in with Microsoft, then press Download from Xbox (about 160 GB).")
    }

    var steamClientCheck: Check {
        let files = steam
        if !files.prefixReady && !files.installed {
            return Check(ok: false, text: "Not installed yet", fix: "Click Install Steam: MetalHorizon downloads Valve's installer and installs Steam in its own prefix.")
        }
        guard files.installed else {
            return Check(ok: false, text: "Not installed in \(steamPrefixPath)", fix: "Click Install Steam.")
        }
        return Check(ok: true, text: files.signedInOnce ? "Installed, signed in" : "Installed",
                     fix: files.signedInOnce ? nil : "Open Steam and sign in once (the first start updates Steam: 15 to 25 minutes).")
    }

    var steamGameCheck: Check {
        let files = steam
        guard files.installed else {
            return Check(ok: false, text: "Install Steam first", fix: "Click Install Steam, then Open Steam and sign in.")
        }
        if files.gameInstalled && !files.gameDownloading {
            return Check(ok: true, text: "Forza Horizon 6 · build \(files.gameBuild ?? "?")")
        }
        if files.manifest != nil {
            return Check(ok: false, text: "Forza Horizon 6 · downloading or updating in Steam",
                         fix: "Open Steam and let it finish the download (about 160 GB).")
        }
        return Check(ok: false, text: "Not in this Steam library yet",
                     fix: "Open Steam, sign in with the account that owns Forza Horizon 6, and install it from the Library.")
    }

    var engineVersion: String {
        guard let data = FileManager.default.contents(atPath: engine + "/metalhorizon.json"),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return info["version"] as? String ?? ""
    }

    var engineCheck: Check {
        let installNow = "MetalHorizon installs Blackwell Engine by itself; click Install if it did not start."
        let name = edition == .steam ? "Blackwell Engine Steam" : "Blackwell Engine"
        guard fileExists(engine + "/bin/wine") else {
            return Check(ok: false, text: engineDirectory.isEmpty ? "\(name) not installed yet" : engine + " · no bin/wine here", fix: installNow)
        }
        if !fileExists(engine + "/lib/wine/x86_64-windows/xgameruntime.dll") {
            return Check(ok: false, text: engine + " · no Xbox runtime: not Blackwell Engine", fix: installNow)
        }
        if !fileExists(engine + "/lib/libgnutls.30.dylib") || !fileExists(engine + "/lib/libfreetype.6.dylib") {
            return Check(ok: false, text: engine + " · its GnuTLS and FreeType are missing",
                         fix: "This engine still expects CrossOver.app's libraries. Use the installed Blackwell Engine (clear the engine setting).")
        }
        if edition == .steam && !fileExists(engine + "/lib/wine/i386-windows/ntdll.dll") {
            return Check(ok: false, text: "\(name) \(engineVersion) · no 32-bit half",
                         fix: "Steam is a 32-bit program: click Install to get Blackwell Engine Steam 1.1 or later.")
        }
        let version = engineVersion
        let controllers = fileExists(engine + "/lib/libSDL2-2.0.0.dylib") ? "" : " (no SDL2: fewer controllers)"
        return Check(ok: true, text: "\(name) \(version.isEmpty ? "" : version + " ")· \(engine)\(controllers)",
                     fix: controllers.isEmpty ? nil : "Install the latest Blackwell Engine for PlayStation, Switch and generic pads.")
    }

    var d3dmetalVersion: String {
        let plist = d3dmetal + "/external/D3DMetal.framework/Versions/A/Resources/Info.plist"
        return (NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String) ?? ""
    }

    var d3dmetalCheck: Check {
        let getIt = "Click Install: MetalHorizon downloads Apple's D3DMetal 4 once you accept Apple's license."
        guard fileExists(d3dmetal + "/external/libd3dshared.dylib"), fileExists(d3dmetal + "/wine/x86_64-windows/d3d12.dll") else {
            return Check(ok: false, text: d3dmetalDirectory.isEmpty ? "Not installed yet" : d3dmetal + " · not Apple's redist/lib folder", fix: getIt)
        }
        let version = d3dmetalVersion
        guard version.hasPrefix("4.") else {
            return Check(ok: false, text: "D3DMetal \(version.isEmpty ? "?" : version): version 4 is needed",
                         fix: "D3DMetal 3 stops at shader model 6.6 and FH6 needs more. " + getIt)
        }
        return Check(ok: true, text: "D3DMetal \(version) · Apple Game Porting Toolkit")
    }

    var shimReady: Bool {
        ["/x86_64-windows/d3d12.dll", "/x86_64-windows/apd12.dll", "/x86_64-unix/apd12.so"].allSatisfy { fileExists(shimDirectory + $0) }
    }

    /// Whether the shim was assembled from this edition's engine (each engine carries its own build of it).
    var componentsReady: Bool { engineCheck.ok && d3dmetalCheck.ok && shimReady }

    var readyToPlay: Bool {
        switch edition {
        case .xbox: return gameCheck.ok && componentsReady
        case .steam: return steamClientCheck.ok && steamGameCheck.ok && componentsReady
        }
    }

    /// The prefix the working setup already has, else MetalHorizon's own (as in metalhorizon-play.sh); for Steam,
    /// the Steam prefix.
    var prefix: String {
        if edition == .steam { return steamPrefixPath }
        return fileExists(gameDirectory + "/.blackwell-wine") ? gameDirectory + "/.blackwell-wine" : gameDirectory + "/.metalhorizon-wine"
    }

    /// The options every script reads (metalhorizon-common.sh).
    func optionsEnvironment(gameInput: Bool) -> [String: String] {
        [
            "MH_ENGINE": engine,
            "MH_D3DMETAL": d3dmetal,
            "MH_SHIM": shimDirectory,
            "MH_HUD": metalHUD ? "1" : "0",
            "MH_GAMEINPUT": gameInput ? "1" : "0",
            "MH_METALFX": metalFX ? "1" : "0",
            "MH_MAX_FPS": String(maxFPS),
            "MH_RETRIES": autoRetry ? "2" : "0",
            "MH_LOGS": logDirectory.path
        ]
    }

    /// What metalhorizon-play.sh reads (the MCP server's show_play_environment passes the same).
    func playEnvironment(resources: URL, gameInput: Bool = false, gameLog: URL? = nil) -> [String: String] {
        var env = optionsEnvironment(gameInput: gameInput)
        env["MH_GAME"] = gameDirectory
        env["MH_XODUS_CLI"] = resources.appendingPathComponent("xodus-cli").path
        env["MH_XODUS_SERVICE"] = resources.appendingPathComponent("xodus-service").path
        if let gameLog { env["MH_GAME_LOG"] = gameLog.path }
        return env
    }

    /// What metalhorizon-steam.sh reads.
    func steamEnvironment(gameInput: Bool = false, gameLog: URL? = nil) -> [String: String] {
        var env = optionsEnvironment(gameInput: gameInput)
        env["MH_PREFIX"] = steamPrefixPath
        env["MH_STEAM_APPID"] = steamAppID
        if let gameLog { env["MH_GAME_LOG"] = gameLog.path }
        return env
    }
}
