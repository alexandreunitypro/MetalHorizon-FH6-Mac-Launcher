import XCTest
@testable import MetalHorizon

/// The beta (alpha) engine channel: which engine plays, with which route and environment, and its removal.
final class BetaChannelTests: XCTestCase {
    override class func setUp() { TestEnvironment.ensure() }

    private var json: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("components.json").path
    }

    override func setUp() {
        setenv("MH_COMPONENTS_JSON", json, 1)
        for id in ["engine-beta", "engine-steam-beta"] { Component.named(id)?.remove() }
    }

    override func tearDown() {
        for id in ["engine-beta", "engine-steam-beta"] { Component.named(id)?.remove() }
        unsetenv("MH_COMPONENTS_JSON")
    }

    /// What a verified install leaves: the folder and its record.
    private func pretendInstalled(_ id: String) throws {
        let component = try XCTUnwrap(Component.named(id))
        try FileManager.default.createDirectory(atPath: component.destination, withIntermediateDirectories: true)
        try component.writeMarker()
        XCTAssertTrue(component.isInstalled)
    }

    private func setup(_ edition: Edition, _ channel: EngineChannel, override: String = "") -> Setup {
        var s = Setup(edition: edition, gameDirectory: "/nonexistent")
        s.engineChannel = channel
        s.engineDirectory = override
        return s
    }

    func testTheBetaEnginePlaysOnlyOnceItIsInstalled() throws {
        XCTAssertEqual(setup(.xbox, .beta).engine, installedEngineDirectory, "chosen but not installed yet: the public engine")
        XCTAssertEqual(setup(.xbox, .beta).optionsEnvironment(gameInput: false)["BW_PACER"], "")
        try pretendInstalled("engine-beta")
        let beta = setup(.xbox, .beta)
        XCTAssertTrue(beta.betaEngineInUse)
        XCTAssertEqual(beta.engine, installedBetaEngineDirectory)
        XCTAssertEqual(beta.optionsEnvironment(gameInput: false)["BW_PACER"], "auto", "the pacer runs with the beta engine")
        XCTAssertEqual(beta.optionsEnvironment(gameInput: false)["BW_TRAP_BOOST"], "1", "and the trap boost")
        if ProcessInfo.processInfo.activeProcessorCount > 8 {
            XCTAssertEqual(beta.optionsEnvironment(gameInput: false)["WINENCPU"], "8", "the game sees 8 processors")
        }
        XCTAssertNil(setup(.xbox, .stable).optionsEnvironment(gameInput: false)["BW_TRAP_BOOST"], "nothing of the beta on Public")
        XCTAssertNil(setup(.xbox, .stable).optionsEnvironment(gameInput: false)["WINENCPU"])
        XCTAssertEqual(setup(.xbox, .stable).engine, installedEngineDirectory, "the public channel ignores an installed beta")
        XCTAssertEqual(setup(.xbox, .stable).optionsEnvironment(gameInput: false)["BW_PACER"], "")
        XCTAssertEqual(setup(.xbox, .beta, override: "/opt/my-wine").engine, "/opt/my-wine", "a chosen engine folder still wins")
        XCTAssertEqual(setup(.steam, .beta).engine, installedSteamEngineDirectory, "Steam's beta is a separate install")
        try pretendInstalled("engine-steam-beta")
        XCTAssertEqual(setup(.steam, .beta).engine, installedSteamBetaEngineDirectory)
    }

    /// Blackwell Engine 1.4 is Beta 1.4a2 made public: the public engine whose record says "rosettaLine" gets the
    /// pacer, the Trap Boost and the 8 processors, as the beta did; an engine without it (1.3.1) gets none.
    func testThePublicEngineWithTheRosettaLineGetsItsSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rosetta-line-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let record = folder.appendingPathComponent("metalhorizon.json")
        try Data(#"{"name": "Blackwell Engine", "version": "1.3.1"}"#.utf8).write(to: record)
        let older = setup(.xbox, .stable, override: folder.path)
        XCTAssertFalse(older.rosettaLineInEngine)
        XCTAssertEqual(older.optionsEnvironment(gameInput: false)["BW_PACER"], "")
        XCTAssertNil(older.optionsEnvironment(gameInput: false)["BW_TRAP_BOOST"])
        try Data(#"{"name": "Blackwell Engine", "version": "1.4", "channel": "public", "rosettaLine": "pacer"}"#.utf8).write(to: record)
        let public14 = setup(.xbox, .stable, override: folder.path)
        XCTAssertTrue(public14.rosettaLineInEngine)
        XCTAssertFalse(public14.betaEngineInUse, "public, not the beta channel")
        XCTAssertEqual(public14.optionsEnvironment(gameInput: false)["BW_PACER"], "auto")
        XCTAssertEqual(public14.optionsEnvironment(gameInput: false)["BW_TRAP_BOOST"], "1")
        if ProcessInfo.processInfo.activeProcessorCount > 8 {
            XCTAssertEqual(public14.optionsEnvironment(gameInput: false)["WINENCPU"], "8")
        }
        let facts = MachineFacts(appleSilicon: true, macOSMajor: 27, macOSMinor: 2, memoryGB: 48)
        XCTAssertFalse(public14.routeDecision(facts: facts, health: RouteHealth()).reason.contains("Beta engine"),
                       "the public engine does not take the native route's place on Automatic")
    }

    func testOnAutomaticTheBetaEnginePlaysOnD3DMetal() throws {
        try pretendInstalled("engine-beta")
        var s = setup(.xbox, .beta)
        let facts = MachineFacts(appleSilicon: true, macOSMajor: 27, macOSMinor: 2, memoryGB: 48)
        XCTAssertEqual(s.routeDecision(facts: facts, health: RouteHealth()).route, .d3dmetal)
        XCTAssertTrue(s.routeDecision(facts: facts, health: RouteHealth()).reason.contains("Pacer"))
        s.engineRoute = .native
        XCTAssertNotEqual(s.routeDecision(facts: facts, health: RouteHealth()).reason, "Beta engine: Rosetta with the Blackwell Pacer against the 10-second freezes.",
                          "a forced route is the player's")
    }

    func testRemovingTheBetaEngineLeavesThePublicOne() throws {
        try pretendInstalled("engine-beta")
        let beta = try XCTUnwrap(Component.named("engine-beta"))
        beta.remove()
        XCTAssertFalse(fileExists(beta.destination))
        XCTAssertFalse(beta.isInstalled)
        XCTAssertFalse(setup(.xbox, .beta).betaEngineInUse)
        XCTAssertEqual(setup(.xbox, .beta).engine, installedEngineDirectory)
    }

    func testTheBetaEnginesArePinnedLikeThePublicOnes() throws {
        for id in ["engine-beta", "engine-steam-beta"] {
            let c = try XCTUnwrap(Component.named(id))
            XCTAssertEqual(c.sha256.count, 64)
            XCTAssertTrue(c.url.hasPrefix("https://github.com/alexandreunitypro/blackwell-engine/releases/download/blackwell-engine-beta-"))
            XCTAssertTrue(c.folder.hasSuffix("Beta"), "beside the public engine, never over it")
        }
    }
}
