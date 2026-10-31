import Foundation

// What the app and its MCP server share: the settings, where MetalHorizon installs its components, and the checks
// that say whether Play can work. Nothing here comes from CrossOver.app.

let appBundleID = "io.github.alexandreunitypro.metalhorizon"
let storeProductID = "9nr1r1xwlcnb"   // Forza Horizon 6, Xbox / Microsoft Store edition
let supportURL = URL(string: "https://buymeacoffee.com/zaidalexandre")!
/// Steam's own installer, downloaded straight from Valve's CDN (no account needed to fetch it).
let steamSetupURL = URL(string: "https://cdn.steampowered.com/download/SteamSetup.exe")!

enum SettingKey {
    static let gameDirectory = "metalhorizon.gameDirectory"
    static let engineDirectory = "metalhorizon.engineDirectory"
    static let d3dmetalDirectory = "metalhorizon.d3dmetalDirectory"
    static let metalHUD = "metalhorizon.metalHUD"
    static let appleLicenseAccepted = "metalhorizon.appleLicenseAccepted"   // the D3DMetal version accepted
    static let welcomeShown = "metalhorizon.welcomeShown"
}

/// The app's settings. Run from a development build (no bundle identifier), the same domain is used by name.
func settingsStore() -> UserDefaults {
    Bundle.main.bundleIdentifier == appBundleID ? .standard : (UserDefaults(suiteName: appBundleID) ?? .standard)
}

func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }

let logDirectory: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MetalHorizon")
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
/// The Steam variant: Blackwell Engine plus two of Highball's own patches (engine/series-steam), for a
/// launcher's own window — Steam's included — to draw instead of staying black. Experimental: this project has
/// no Steam copy of Forza Horizon 6 to test with.
let installedSteamEngineDirectory = supportDirectory.appendingPathComponent("Blackwell Engine Steam").path
let installedD3DMetalDirectory = supportDirectory.appendingPathComponent("D3DMetal").path
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
    var gameDirectory = ""
    var engineDirectory = ""      // empty: the installed Blackwell Engine
    var d3dmetalDirectory = ""    // empty: the installed D3DMetal
    var metalHUD = true

    static func load() -> Setup {
        let defaults = settingsStore()
        var setup = Setup()
        setup.gameDirectory = defaults.string(forKey: SettingKey.gameDirectory) ?? expandTilde("~/FH6")
        setup.engineDirectory = defaults.string(forKey: SettingKey.engineDirectory) ?? ""
        setup.d3dmetalDirectory = defaults.string(forKey: SettingKey.d3dmetalDirectory) ?? ""
        setup.metalHUD = defaults.object(forKey: SettingKey.metalHUD) as? Bool ?? true
        return setup
    }

    /// The Steam edition needs the Steam-variant engine; a manual override (engineDirectory) still wins for either.
    var engine: String {
        if !engineDirectory.isEmpty { return engineDirectory }
        return isSteamEdition ? installedSteamEngineDirectory : installedEngineDirectory
    }
    var d3dmetal: String { d3dmetalDirectory.isEmpty ? installedD3DMetalDirectory : d3dmetalDirectory }

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

    var gameCheck: Check {
        guard !gameDirectory.isEmpty else {
            return Check(ok: false, text: "Choose a folder with a short path, such as ~/FH6",
                         fix: "Pick a real folder with a short path (~/FH6), not in iCloud Drive, then Download from Xbox.")
        }
        let resolved = URL(fileURLWithPath: gameDirectory).resolvingSymlinksInPath().path
        if resolved != gameDirectory {
            return Check(ok: false, text: "This folder is a link; choose the real folder (\(resolved))",
                         fix: "xodus resolves links, so the game folder itself must have the short name: pick \(resolved) or rename it.")
        }
        if isSteamEdition {
            if fileExists(gameDirectory + "/forzahorizon6.exe") {
                return Check(ok: true, text: gameDirectory + " · Steam edition (experimental)")
            }
            return Check(ok: false, text: gameDirectory + " · no forzahorizon6.exe here",
                         fix: "Pick the folder Steam installed the game into (steamapps/common/Forza Horizon 6).")
        }
        if fileExists(gameDirectory + "/forzahorizon6.exe") { return Check(ok: true, text: gameDirectory) }
        return Check(ok: false, text: gameDirectory + " · not downloaded yet",
                     fix: "Sign in with Microsoft, then press Download from Xbox (about 160 GB).")
    }

    /// Steam installs ship steam_api64.dll (or steam_appid.txt) and live under steamapps/common; the Xbox edition has neither.
    var isSteamEdition: Bool {
        guard !gameDirectory.isEmpty else { return false }
        return fileExists(gameDirectory + "/steam_api64.dll") || fileExists(gameDirectory + "/steam_appid.txt")
            || gameDirectory.lowercased().contains("/steamapps/common/")
    }

    /// The Steam AppID (steam_appid.txt), used to launch through Steam itself (`steam.exe -applaunch <id>`):
    /// Steam resolves the install path on its own and starts, bootstrapping its own client if needed.
    var steamAppID: String? {
        guard let data = FileManager.default.contents(atPath: gameDirectory + "/steam_appid.txt"),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// A separate prefix from the Xbox edition's, since Steam's own client lives inside it (Highball: without
    /// Steam running in the same prefix, FH6 on Steam closes itself after about 12 seconds).
    var steamPrefix: String { gameDirectory + "/.blackwell-wine-steam" }
    var steamClientExecutable: String { steamPrefix + "/drive_c/Program Files (x86)/Steam/Steam.exe" }
    var steamClientCheck: Check {
        guard fileExists(steamClientExecutable) else {
            return Check(ok: false, text: "Not installed in this prefix yet",
                         fix: "Click Install Steam: MetalHorizon downloads Valve's own installer and runs it in the game's Wine prefix. Sign in once it opens.")
        }
        return Check(ok: true, text: "Installed")
    }

    var engineVersion: String {
        guard let data = FileManager.default.contents(atPath: engine + "/metalhorizon.json"),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return info["version"] as? String ?? ""
    }

    var engineCheck: Check {
        let installNow = "MetalHorizon installs Blackwell Engine by itself; click Install if it did not start."
        guard fileExists(engine + "/bin/wine") else {
            return Check(ok: false, text: engineDirectory.isEmpty ? "Not installed yet" : engine + " · no bin/wine here", fix: installNow)
        }
        if !fileExists(engine + "/lib/wine/x86_64-windows/xgameruntime.dll") {
            return Check(ok: false, text: engine + " · no Xbox runtime: not Blackwell Engine", fix: installNow)
        }
        if !fileExists(engine + "/lib/libgnutls.30.dylib") || !fileExists(engine + "/lib/libfreetype.6.dylib") {
            return Check(ok: false, text: engine + " · its GnuTLS and FreeType are missing",
                         fix: "This engine still expects CrossOver.app's libraries. Use the installed Blackwell Engine (clear the engine setting).")
        }
        let version = engineVersion
        return Check(ok: true, text: "Blackwell Engine \(version.isEmpty ? "" : version + " ")· \(engine)")
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

    var readyToPlay: Bool {
        gameCheck.ok && engineCheck.ok && d3dmetalCheck.ok && shimReady && (!isSteamEdition || steamClientCheck.ok)
    }

    /// The prefix the working setup already has, else MetalHorizon's own (as in metalhorizon-play.sh). The Steam
    /// edition always uses its own separate prefix (steamPrefix): Steam's client lives inside it.
    var prefix: String {
        if isSteamEdition { return steamPrefix }
        return fileExists(gameDirectory + "/.blackwell-wine") ? gameDirectory + "/.blackwell-wine" : gameDirectory + "/.metalhorizon-wine"
    }

    /// What metalhorizon-play.sh reads (the MCP server's show_play_environment passes the same).
    func playEnvironment(resources: URL) -> [String: String] {
        [
            "MH_ENGINE": engine,
            "MH_D3DMETAL": d3dmetal,
            "MH_SHIM": shimDirectory,
            "MH_GAME": gameDirectory,
            "MH_XODUS_CLI": resources.appendingPathComponent("xodus-cli").path,
            "MH_XODUS_SERVICE": resources.appendingPathComponent("xodus-service").path,
            "MH_HUD": metalHUD ? "1" : "0",
            "MH_LOGS": logDirectory.path
        ]
    }

    /// What metalhorizon-play-steam.sh and metalhorizon-install-steam.sh read: no xodus (Steam handles its own
    /// sign-in and downloads), the Steam-only prefix, and the AppID for `steam.exe -applaunch`.
    func steamEnvironment() -> [String: String] {
        [
            "MH_ENGINE": engine,
            "MH_D3DMETAL": d3dmetal,
            "MH_SHIM": shimDirectory,
            "MH_GAME": gameDirectory,
            "MH_PREFIX": steamPrefix,
            "MH_STEAM_APPID": steamAppID ?? "",
            "MH_HUD": metalHUD ? "1" : "0",
            "MH_LOGS": logDirectory.path
        ]
    }
}
