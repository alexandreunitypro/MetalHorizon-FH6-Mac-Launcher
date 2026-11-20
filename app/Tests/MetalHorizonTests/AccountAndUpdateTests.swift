import XCTest
@testable import MetalHorizon

/// Xbox's refusal codes and the game's version, on made-up answers: the account's real problem is named with the page
/// that fixes it, and an outdated game is offered its update.
final class AccountAndUpdateTests: XCTestCase {
    override class func setUp() { TestEnvironment.ensure() }

    /// What xodus-service writes when Xbox refuses an account that has no Xbox profile.
    private let noProfileLine = #"Xbox answered 401 Unauthorized to xsts.auth.xboxlive.com: {"Identity":"0","XErr":2148916233,"Message":"","Redirect":"https://start.ui.xboxlive.com/CreateAccount"} "#

    private func patient(account: AccountCheck?, update: GameUpdate? = nil) -> Patient {
        var setup = Setup(edition: .xbox, gameDirectory: "/nonexistent-\(UUID().uuidString)")
        setup.ownership = .purchase
        var p = Patient(setup: setup, facts: MachineFacts(appleSilicon: true, macOSMajor: 27, macOSMinor: 2, memoryGB: 48),
                        moment: .beforePlay, runs: [], gameRunning: false, serviceRunning: false, serviceSocket: true,
                        accountSaved: true, rosetta: true, freeBytes: 500_000_000_000, appTranslocated: false,
                        appQuarantined: false, appPath: "/tmp/MetalHorizon.app", online: true, clockSkew: nil,
                        steamNativeRunning: false)
        p.account = account
        p.gameUpdate = update
        return p
    }

    func testXboxRefusalCodesAreNamed() {
        XCTAssertEqual(XboxRefusal.from(noProfileLine)?.id, "xbox-no-profile")
        XCTAssertEqual(XboxRefusal.from(#"{"XErr": 2148916238}"#)?.button, "Open Microsoft Family")
        XCTAssertEqual(XboxRefusal.from("the XSTS token: 401 (Xbox: XErr 2148916234, …)")?.id, "xbox-terms")
        XCTAssertNil(XboxRefusal.from(#"{"XErr":1234567890}"#), "an unknown code is left to the plain sign-in path")
        XCTAssertNil(XboxRefusal.from("HTTP status client error (400 Bad Request)"))
        XCTAssertTrue(Diagnostics.scan(text: noProfileLine, source: "t").contains { $0.id == "xbox-no-profile" })
    }

    /// A child account gets the family page first, not a sign-in that cannot help.
    func testARefusedAccountOpensThePageThatFixesIt() async {
        var opened: URL?, signedIn = false
        var actions = DoctorActions()
        actions.openURL = { opened = $0 }
        actions.signInAgain = { signedIn = true }
        var state = DoctorState()
        let exam = await Doctor.examine(patient(account: .refused("the XSTS token: 401 (Xbox: XErr 2148916238, a child account)")),
                                        actions: actions, catalogue: Doctor.xbox, state: &state)
        let fix = exam.pending.first { $0.id == "xbox-account-refused" }
        XCTAssertEqual(fix?.button, "Open Microsoft Family")
        XCTAssertTrue(fix?.detail.contains("adult") == true)
        _ = await fix?.action()
        XCTAssertEqual(opened?.host, "account.microsoft.com")
        XCTAssertFalse(signedIn)
    }

    func testVersionsCompareNumberByNumber() {
        XCTAssertTrue(GameVersion.isNewer("3.10.0.0", than: "3.9.0.0"))
        XCTAssertTrue(GameVersion.isNewer("3.461.691.1", than: "3.461.691.0"))
        XCTAssertFalse(GameVersion.isNewer("3.461.691.0", than: "3.461.691.0"))
        XCTAssertFalse(GameVersion.isNewer("3.400.0.0", than: "3.461.691.0"))
    }

    func testTheInstalledVersionComesFromTheGamesManifest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fh6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try #"<?xml version="1.0"?><Package><Identity Name="Microsoft.ForzaHorizon6" Publisher="CN=x" Version="3.461.691.0" ProcessorArchitecture="x64"/></Package>"#
            .write(to: dir.appendingPathComponent("appxmanifest.xml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(GameVersion.installed(gameDirectory: dir.path), "3.461.691.0")
        XCTAssertNil(GameVersion.installed(gameDirectory: dir.path + "/missing"))
    }

    func testAnOutdatedGameIsOfferedItsUpdate() async {
        var downloading = false
        var actions = DoctorActions()
        actions.startDownload = { downloading = true }
        var state = DoctorState()
        let exam = await Doctor.examine(patient(account: .accepted, update: GameUpdate(installed: "3.461.691.0", latest: "3.688.109.0")),
                                        actions: actions, catalogue: Doctor.xbox, state: &state)
        let fix = exam.pending.first { $0.id == "game-outdated" }
        XCTAssertEqual(fix?.button, "Update the Game")
        _ = await fix?.action()
        XCTAssertTrue(downloading)
        var state2 = DoctorState()
        let current = await Doctor.examine(patient(account: .accepted), actions: actions, catalogue: Doctor.xbox, state: &state2)
        XCTAssertFalse(current.pending.contains { $0.id == "game-outdated" })
    }
}
