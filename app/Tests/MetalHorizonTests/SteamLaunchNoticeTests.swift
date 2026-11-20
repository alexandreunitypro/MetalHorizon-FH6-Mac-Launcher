import XCTest
@testable import MetalHorizon

/// Steam's pre-launch notices recorded as seen (issues #16, #17), on made-up localconfig.vdf files.
final class SteamLaunchNoticeTests: XCTestCase {
    private let config = """
    "UserLocalConfigStore"
    {
    \t"Software"
    \t{
    \t}
    \t"WebStorage"
    \t{
    \t\t"Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended"\t\t"1"
    \t\t"Deck_ConfiguratorInterstitialApps_GamepadRecommended"\t\t"[730]"
    \t}
    }
    """

    func testEveryNoticeIsRecordedOnceForTheGame() throws {
        let marked = try XCTUnwrap(SteamLaunchNotice.markingSeen(in: config, appID: 2483190))
        XCTAssertTrue(marked.contains("\"Deck_ConfiguratorInterstitialsVersionSeen_GamepadRecommended\"\t\t\"1\""))
        XCTAssertTrue(marked.contains("\"Deck_ConfiguratorInterstitialApps_GamepadRecommended\"\t\t\"[730,2483190]\""), "another game's entry stays")
        XCTAssertTrue(marked.contains("\"Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended\"\t\t\"1\""), "the player's own choice stays")
        XCTAssertTrue(marked.contains("\"Deck_ConfiguratorInterstitialsVersionSeen_NonVerifiedGame\"\t\t\"5\""))
        XCTAssertTrue(marked.contains("\"Deck_ConfiguratorInterstitialApps_CurrentGamepadSteamInputOptIn\"\t\t\"[2483190]\""))
        XCTAssertTrue(marked.contains("\"Software\""), "the rest of the file is kept")
        XCTAssertNil(SteamLaunchNotice.markingSeen(in: marked, appID: 2483190), "nothing left to change the second time")
    }

    func testAFileWithoutWebStorageIsLeftAlone() {
        XCTAssertNil(SteamLaunchNotice.markingSeen(in: "\"UserLocalConfigStore\"\n{\n\t\"Software\"\n\t{\n\t}\n}\n", appID: 2483190))
    }

    func testEveryUserOfTheSteamFolderIsMarked() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for user in ["111", "222"] {
            let dir = root.appendingPathComponent("userdata/\(user)/config")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try config.replacingOccurrences(of: "\n", with: "\r\n").write(to: dir.appendingPathComponent("localconfig.vdf"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(SteamLaunchNotice.markSeen(steamRoot: root, appID: 2483190), 2)
        let text = try String(contentsOf: root.appendingPathComponent("userdata/222/config/localconfig.vdf"), encoding: .utf8)
        XCTAssertTrue(text.contains("[730,2483190]"))
        XCTAssertTrue(text.contains("\r\n"), "Windows line endings stay")
        XCTAssertEqual(SteamLaunchNotice.markSeen(steamRoot: root, appID: 2483190), 0)
    }

    func testTheLicenceTokenFailureIsRecognized() {
        let line = "2026-11-20T10:00:00Z  WARN xodus_service::connection::xml: Licence token request failed: the licence service answered HTTP 403 Forbidden"
        XCTAssertTrue(Diagnostics.scan(text: line, source: "t").contains { $0.id == "licence-token-failed" })
        XCTAssertTrue(Diagnostics.scan(text: "DEBUG xodus_service::connection::router: Connection closed by the game", source: "t").isEmpty,
                      "a finished request closing is not a problem")
    }
}
