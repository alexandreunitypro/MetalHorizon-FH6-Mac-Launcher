import Foundation

/// Steam's pre-launch notices ("controller recommended", "use Steam Input for this controller?" and the like), recorded
/// as seen before a cold start, so the silent client MetalHorizon starts the game with never waits on one.
///
/// Before a game's first start Steam's launch can stop at `ShowInterstitials` and wait for the player to dismiss a notice
/// drawn by its web UI. The silent client (`-silent -applaunch`) shows no window, so the launch waits for good and the
/// game never starts: issues #16 and #17 (E:0-0-L-8 after Steam's 5-minute wait, Steam's last lines showing nothing
/// else). Once a notice has been shown, Steam's web UI records it in the user's `localconfig.vdf`, under
/// `UserLocalConfigStore/WebStorage`, and never stops that game's launch for it again:
///
///     "Deck_ConfiguratorInterstitialsVersionSeen_GamepadRecommended"   "1"
///     "Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended"      "0"
///     "Deck_ConfiguratorInterstitialApps_GamepadRecommended"           "[2483190]"
///
/// Ported from Highball (`Sources/HighballKit/SteamLaunchNotice.swift`, https://github.com/gauthierpiarrette/highball,
/// GPL-3.0, Gauthier Piarrette), which found it: Forza Horizon 6 stood at `ShowInterstitials` on its first Play, and with
/// these values written first Steam answered itself within a second and started the game. The notices only inform; the
/// player could not see them in this mode anyway. Steam keeps the file in memory while it runs and writes it back on
/// exit, so this is done only while no Steam client runs in the prefix. A "don't show again" the player ticked stays.
enum SteamLaunchNotice {
    /// The notices as Steam client 1788652215 defines them: the name in their storage keys, whether Steam asks once per
    /// game (an apps list and a checkbox) or once for every game, and the version it compares the stored one against.
    static let notices: [(name: String, perGame: Bool, version: Int)] = [
        ("GamepadRecommended", true, 1),
        ("CurrentGamepadSteamInputOptIn", true, 1),
        ("CurrentGamepadUnsupported", true, 1),
        ("AppTextInputDoesNotAutomaticallyInvokesKeyboard", true, 1),
        ("AppLauncherInteractionIssues", true, 1),
        ("AppHasSmallText", true, 1),
        ("IntroToVRTheater", true, 1),
        ("HDRRequiresUserAction", true, 1),
        ("UnclaimedEntitlement", true, 1),
        ("Intro", false, 3),
        ("NonVerifiedGame", false, 5),
        ("Gyro", false, 4),
        ("RemotePlayConfirm", false, 3),
        ("ExternalControllersAndSIAPI", false, 1),
        ("IntroToActionSets", false, 1),
        ("IntroToSteamInputGames", false, 1),
    ]

    /// The text of a `localconfig.vdf` with every notice recorded as seen for `appID`, or nil when nothing needs to
    /// change or the file has no `WebStorage` block (a client that never showed its web UI: nothing is invented then).
    static func markingSeen(in text: String, appID: Int) -> String? {
        let crlf = text.contains("\r\n")
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func depth(_ line: String) -> Int { line.prefix { $0 == "\t" }.count }
        func trimmed(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        guard let storage = lines.indices.first(where: { trimmed(lines[$0]) == "\"WebStorage\"" && depth(lines[$0]) == 1 }),
              storage + 1 < lines.count, trimmed(lines[storage + 1]) == "{",
              var end = lines.indices.first(where: { $0 > storage + 1 && depth(lines[$0]) == 1 && trimmed(lines[$0]) == "}" })
        else { return nil }

        func pair(_ line: String) -> (key: String, value: String)? {
            let parts = trimmed(line).components(separatedBy: "\"")
            guard parts.count >= 5, parts[0].isEmpty else { return nil }
            return (parts[1], parts[3])
        }
        func entry(_ key: String, _ value: String) -> String { "\t\t\"\(key)\"\t\t\"\(value)\"" }
        func index(of key: String) -> Int? { (storage + 2..<end).first { pair(lines[$0])?.key == key } }
        func value(of key: String) -> String? { index(of: key).flatMap { pair(lines[$0])?.value } }
        var changed = false
        func set(_ key: String, _ value: String) {
            if let i = index(of: key) { lines[i] = entry(key, value) } else { lines.insert(entry(key, value), at: end); end += 1 }
            changed = true
        }

        for notice in notices {
            let seen = "Deck_ConfiguratorInterstitialsVersionSeen_" + notice.name
            if (value(of: seen).flatMap { Int($0) } ?? 0) < notice.version { set(seen, String(notice.version)) }
            guard notice.perGame else { continue }
            let checkbox = "Deck_ConfiguratorInterstitialsCheckbox_" + notice.name
            if index(of: checkbox) == nil { set(checkbox, "0") }
            let appsKey = "Deck_ConfiguratorInterstitialApps_" + notice.name
            var apps = value(of: appsKey).flatMap { try? JSONDecoder().decode([Int].self, from: Data($0.utf8)) } ?? []
            if !apps.contains(appID) {
                apps.append(appID)
                set(appsKey, "[" + apps.map(String.init).joined(separator: ",") + "]")
            }
        }
        guard changed else { return nil }
        let joined = lines.joined(separator: "\n")
        return crlf ? joined.replacingOccurrences(of: "\n", with: "\r\n") : joined
    }

    /// Records the notices as seen for `appID` in every Steam user's `localconfig.vdf` under `steamRoot`. Only while no
    /// Steam client runs there. Returns how many files changed.
    @discardableResult
    static func markSeen(steamRoot: URL, appID: Int) -> Int {
        let userdata = steamRoot.appendingPathComponent("userdata")
        let users = (try? FileManager.default.contentsOfDirectory(at: userdata, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for user in users {
            let file = user.appendingPathComponent("config/localconfig.vdf")
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let updated = markingSeen(in: text, appID: appID),
                  (try? updated.write(to: file, atomically: true, encoding: .utf8)) != nil else { continue }
            count += 1
        }
        return count
    }
}
