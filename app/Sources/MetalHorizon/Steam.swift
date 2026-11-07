import Foundation

// The Steam edition's state, read from Steam's own files in the prefix (no process needed): whether Steam is
// installed, whether someone signed in once, and Forza Horizon 6's appmanifest (installed, downloading, its build).
// What runs (the client and its mode, the game) comes from metalhorizon-steam.sh status, which reads the processes.

let steamAppID = "2483190"   // Forza Horizon 6 on Steam (highball-db, lastVerified)

struct SteamFiles {
    let prefix: String

    var steamDirectory: String { prefix + "/drive_c/Program Files (x86)/Steam" }
    var executable: String? {
        ["steam.exe", "Steam.exe"].map { steamDirectory + "/" + $0 }.first(where: fileExists)
    }
    var installed: Bool { executable != nil }
    var prefixReady: Bool { fileExists(prefix + "/system.reg") }

    /// Someone signed in to Steam in this prefix at least once (the account names stay in the file).
    var signedInOnce: Bool {
        guard let text = try? String(contentsOfFile: steamDirectory + "/config/loginusers.vdf", encoding: .utf8) else { return false }
        return text.contains("\"AccountName\"")
    }

    var manifest: [String: String]? {
        for folder in ["steamapps", "SteamApps"] {
            let path = steamDirectory + "/\(folder)/appmanifest_\(steamAppID).acf"
            if let text = try? String(contentsOfFile: path, encoding: .utf8) { return SteamFiles.parseACF(text) }
        }
        return nil
    }

    /// Steam's StateFlags: 4 is "fully installed"; 1024, 2 and 1048576 mark updates and downloads in progress.
    var gameInstalled: Bool { (manifest?["StateFlags"]).flatMap(Int.init).map { $0 & 4 != 0 } ?? false }
    var gameDownloading: Bool {
        guard let flags = (manifest?["StateFlags"]).flatMap(Int.init) else { return false }
        return flags & (2 | 1024 | 1_048_576) != 0
    }
    var gameBuild: String? { manifest?["buildid"] }
    var gameFolder: String? {
        (manifest?["installdir"]).map { steamDirectory + "/steamapps/common/" + $0 }
    }

    /// The top-level keys of an appmanifest (Valve's KeyValues text): "key" "value" pairs, nested blocks skipped.
    static func parseACF(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var depth = 0
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" { depth += 1; continue }
            if line == "}" { depth -= 1; continue }
            guard depth == 1 else { continue }
            let parts = line.split(separator: "\"", omittingEmptySubsequences: true).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if parts.count >= 2 { result[parts[0]] = parts[1] }
        }
        return result
    }
}

/// metalhorizon-steam.sh status, parsed.
struct SteamStatus: Equatable {
    var clientRunning = false
    var clientMode = "none"       // window, game or none
    var gameRunning = false
    var engine32bit = true
    var engineDXMT = true

    static func parse(_ text: String) -> SteamStatus {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return SteamStatus(clientRunning: values["client_running"] == "yes", clientMode: values["client_mode"] ?? "none",
                           gameRunning: values["game_running"] == "yes", engine32bit: values["engine_32bit"] != "no",
                           engineDXMT: values["engine_dxmt"] != "no")
    }
}
