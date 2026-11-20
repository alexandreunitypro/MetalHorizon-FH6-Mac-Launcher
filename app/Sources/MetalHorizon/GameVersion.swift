import Foundation

/// The installed Forza Horizon 6 (Xbox / Game Pass) against the version Microsoft publishes.
///
/// On Windows the Store updates the game by itself; here nothing did. An outdated game finds no online session (the
/// servers want the current build) and can come back with "Invalid Profile" (E:43-1b-4) once its cloud profile was saved
/// by a newer build, on an Xbox, a PC or Game Pass in the cloud. `xodus-service --latest-version` asks Microsoft's
/// authenticated package service for the current version (the public catalog reports every package as version 0).
struct GameUpdate: Equatable {
    let installed: String
    let latest: String
}

enum GameVersion {
    /// Forza Horizon 6's PC package (MSIXVC) in Microsoft's catalog (product 9NR1R1XWLCNB), what downloads use too.
    static let contentID = "ab03f40c-e85d-467b-8c67-3870b89bd2d1"
    /// Asked at most this often: the answer changes with a game update, a few times a month.
    static let interval: TimeInterval = 6 * 3600

    /// The version in the game's own manifest (appxmanifest.xml, `<Identity … Version="3.461.691.0">`).
    static func installed(gameDirectory: String) -> String? {
        guard let text = try? String(contentsOfFile: gameDirectory + "/appxmanifest.xml", encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: #"<Identity\b[^>]*\bVersion="([0-9]+(?:\.[0-9]+){3})""#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// Dotted versions compared number by number ("3.10.0.0" is newer than "3.9.0.0").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static var cacheFile: URL { supportDirectory.appendingPathComponent("game-version.json") }
    private struct Cache: Codable { var checked: Date; var latest: String }

    /// The published version: from the last answer when it is recent, else asked through the bundled service (at most
    /// 40 s; nil when it cannot tell: no sign-in, offline, an older service without the mode).
    static func latest(resources: URL?, now: Date = Date()) -> String? {
        if let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder.iso.decode(Cache.self, from: data),
           now.timeIntervalSince(cache.checked) < interval { return cache.latest }
        guard let service = resources?.appendingPathComponent("xodus-service"), fileExists(service.path) else { return nil }
        let (code, out, timedOut) = Sys.capture(service.path, ["--latest-version", contentID], timeout: 40)
        guard !timedOut, code == 0,
              let line = out.split(separator: "\n").last(where: { $0.hasPrefix("LATEST ") }) else { return nil }
        let version = String(line.dropFirst("LATEST ".count)).trimmingCharacters(in: .whitespaces)
        guard version.split(separator: ".").count == 4, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        if let data = try? JSONEncoder.iso.encode(Cache(checked: now, latest: version)) { try? data.write(to: cacheFile, options: .atomic) }
        return version
    }

    /// An update to offer, or nil when the game is current or nothing can be told.
    static func check(resources: URL?, gameDirectory: String) -> GameUpdate? {
        guard let installed = installed(gameDirectory: gameDirectory), let latest = latest(resources: resources),
              isNewer(latest, than: installed) else { return nil }
        return GameUpdate(installed: installed, latest: latest)
    }

    /// After a download the answer is re-read, so a finished update is not offered again from the cache.
    static func forget() { try? FileManager.default.removeItem(at: cacheFile) }
}
