import XCTest
@testable import MetalHorizon

/// The engine choice and the Autopilot's rules, without running anything.
final class AutopilotTests: XCTestCase {
    override class func setUp() { TestEnvironment.ensure() }

    private let m5 = MachineFacts(appleSilicon: true, macOSMajor: 27, macOSMinor: 2, memoryGB: 48)
    private let small = MachineFacts(appleSilicon: true, macOSMajor: 27, macOSMinor: 2, memoryGB: 16)
    private let oldOS = MachineFacts(appleSilicon: true, macOSMajor: 26, macOSMinor: 4, memoryGB: 48)

    func testAutomaticPicksNativeOnACapableMac() {
        let d = RouteDecision.decide(preference: .automatic, edition: .xbox, facts: m5, health: RouteHealth(), nativeAvailable: true)
        XCTAssertEqual(d.route, .native)
        XCTAssertEqual(RouteDecision.decide(preference: .automatic, edition: .xbox, facts: small, health: RouteHealth(), nativeAvailable: true).route, .d3dmetal)
        XCTAssertEqual(RouteDecision.decide(preference: .automatic, edition: .xbox, facts: oldOS, health: RouteHealth(), nativeAvailable: true).route, .d3dmetal)
        XCTAssertEqual(RouteDecision.decide(preference: .automatic, edition: .xbox, facts: m5, health: RouteHealth(), nativeAvailable: false).route, .d3dmetal)
        XCTAssertEqual(RouteDecision.decide(preference: .automatic, edition: .steam, facts: m5, health: RouteHealth(), nativeAvailable: true).route, .d3dmetal)
        XCTAssertEqual(RouteDecision.decide(preference: .d3dmetal, edition: .xbox, facts: m5, health: RouteHealth(), nativeAvailable: true).route, .d3dmetal)
        // a forced native choice on a Mac that cannot run it falls back, and says so
        let forced = RouteDecision.decide(preference: .native, edition: .xbox, facts: oldOS, health: RouteHealth(), nativeAvailable: true)
        XCTAssertEqual(forced.route, .d3dmetal)
        XCTAssertTrue(forced.reason.contains("macOS 27"))
    }

    func testABenchedNativeEngineIsLeftOutUntilItsTimeIsUp() {
        var health = RouteHealth()
        let now = Date()
        health.bench(.native, for: 3 * 86_400, reason: "stopped twice", now: now)
        XCTAssertEqual(RouteDecision.decide(preference: .automatic, edition: .xbox, facts: m5, health: health, nativeAvailable: true, now: now).route, .d3dmetal)
        XCTAssertEqual(RouteDecision.decide(preference: .automatic, edition: .xbox, facts: m5, health: health, nativeAvailable: true,
                                            now: now.addingTimeInterval(4 * 86_400)).route, .native)
        // the player's own choice wins over the bench
        XCTAssertEqual(RouteDecision.decide(preference: .native, edition: .xbox, facts: m5, health: health, nativeAvailable: true, now: now).route, .native)
    }

    private func outcome(_ route: ResolvedRoute, exit: Int32, after seconds: TimeInterval, log: String = "",
                         stopped: Bool = false, metalFX: Bool = false) -> RunOutcome {
        RunOutcome(route: route, exitCode: exit, duration: seconds, findings: Diagnostics.scan(text: log, source: "test"),
                   userStopped: stopped, options: (metalFX, 0))
    }

    func testAnEarlyCrashIsRelaunchedOnceAndTwoInADayMoveTheGame() {
        var health = RouteHealth()
        let now = Date()
        let crash = outcome(.native, exit: 1, after: 40, log: "wine: Unhandled page fault on read access to 0000000000000010 at address 00006FFFF0001234")
        var d = Autopilot.afterRun(crash, health: &health, nativeAvailable: true, facts: m5, preference: .automatic, alreadyRelaunched: false, now: now)
        XCTAssertEqual(d.relaunch, .native, "the first early stop is relaunched on the same engine")
        XCTAssertFalse(health.isBenched(.native, now: now))

        d = Autopilot.afterRun(crash, health: &health, nativeAvailable: true, facts: m5, preference: .automatic, alreadyRelaunched: false,
                               now: now.addingTimeInterval(60))
        XCTAssertTrue(health.isBenched(.native, now: now.addingTimeInterval(61)), "two engine failures in a day set the native engine aside")
        XCTAssertEqual(d.relaunch, .d3dmetal, "and the relaunch goes to D3DMetal")
        XCTAssertTrue(d.repairs.contains { $0.kind == .switchedEngine })

        // once the Play click had its relaunch, no second one
        d = Autopilot.afterRun(crash, health: &health, nativeAvailable: true, facts: m5, preference: .automatic, alreadyRelaunched: true,
                               now: now.addingTimeInterval(120))
        XCTAssertNil(d.relaunch)
    }

    func testAForcedEngineIsNeverSwitched() {
        var health = RouteHealth()
        let crash = outcome(.native, exit: 1, after: 30, log: "wine: Unhandled page fault")
        _ = Autopilot.afterRun(crash, health: &health, nativeAvailable: true, facts: m5, preference: .native, alreadyRelaunched: false)
        let d = Autopilot.afterRun(crash, health: &health, nativeAvailable: true, facts: m5, preference: .native, alreadyRelaunched: false)
        XCTAssertFalse(health.isBenched(.native))
        XCTAssertFalse(d.repairs.contains { $0.kind == .switchedEngine })
    }

    func testProblemsAnotherEngineWouldNotChangeAreLeftAlone() {
        var health = RouteHealth()
        let profile = outcome(.native, exit: 1, after: 60, log: "Code d'erreur : E:43-1b-4")
        let d = Autopilot.afterRun(profile, health: &health, nativeAvailable: true, facts: m5, preference: .automatic, alreadyRelaunched: false)
        XCTAssertNil(d.relaunch)
        XCTAssertFalse(d.repairs.contains { $0.kind == .switchedEngine })
        XCTAssertFalse(profile.engineFailure)
    }

    func testAPlayerStopIsNeverAFailure() {
        var health = RouteHealth()
        let d = Autopilot.afterRun(outcome(.native, exit: 143, after: 20, stopped: true), health: &health, nativeAvailable: true,
                                   facts: m5, preference: .automatic, alreadyRelaunched: false)
        XCTAssertTrue(d.repairs.isEmpty)
        XCTAssertNil(d.relaunch)
        XCTAssertEqual(health.recentFailures(.native), 0)
    }

    func testALongRunClearsTheRecordAndMetalFXCrashesTurnItOff() {
        var health = RouteHealth()
        health.bench(.native, for: 86_400, reason: "test")
        _ = Autopilot.afterRun(outcome(.native, exit: 0, after: 900), health: &health, nativeAvailable: true, facts: m5,
                               preference: .automatic, alreadyRelaunched: false)
        XCTAssertFalse(health.isBenched(.native))
        XCTAssertNotNil(health.native.lastSuccess)

        var h2 = RouteHealth()
        let d = Autopilot.afterRun(outcome(.d3dmetal, exit: 1, after: 50, log: "wine: Unhandled page fault", metalFX: true),
                                   health: &h2, nativeAvailable: false, facts: m5, preference: .automatic, alreadyRelaunched: false)
        XCTAssertTrue(d.disableMetalFX)
    }

    func testALicenceTimeoutRestartsTheXboxServiceAndTriesOnce() {
        var health = RouteHealth()
        let run = outcome(.native, exit: 143, after: 200, log: "STOP: the Xbox licence request did not answer in 3 minutes (network, or the Xbox service): stopping it.")
        var d = Autopilot.afterRun(run, health: &health, nativeAvailable: true, facts: m5, preference: .automatic, alreadyRelaunched: false)
        XCTAssertTrue(d.restartXboxService)
        XCTAssertEqual(d.relaunch, .native)
        XCTAssertFalse(health.isBenched(.native), "the network is not the engine's fault")
        d = Autopilot.afterRun(run, health: &health, nativeAvailable: true, facts: m5, preference: .automatic, alreadyRelaunched: true)
        XCTAssertNil(d.relaunch)
    }

    func testRepairsAreWrittenDownAndReadBack() {
        let before = RepairLog.all().count
        RepairLog.record(Repair(title: "Test repair", detail: "from AutopilotTests", kind: .fixed))
        XCTAssertEqual(RepairLog.all().count, before + 1)
        XCTAssertEqual(RepairLog.recent().first?.title, "Test repair")
    }

    func testNativeEngineIssuesAreRecognized() {
        XCTAssertTrue(Diagnostics.scan(text: "crash at xtajit64.dll+0x1177ac", source: "t").contains { $0.id == "native-emulator-crash" })
        XCTAssertTrue(Diagnostics.scan(text: "vkd3d: VK_ERROR_DEVICE_LOST", source: "t").contains { $0.id == "native-device-lost" })
        XCTAssertTrue(Diagnostics.scan(text: "STOP: the native engine's signed loader is missing (WineLoader.app)", source: "t").contains { $0.id == "native-loader" })
    }

    /// Issue #14: the game's own crash window ends with exit 0 after two minutes; the log shows the crash.
    func testACrashWithExitZeroIsStillAFailure() {
        var health = RouteHealth()
        let line = "wine: Unimplemented function concrt140.dll.??0_Concurrent_queue_iterator_base_v4@details@Concurrency@@IEAA@AEBV_Concurrent_queue_base_v4@12@@Z called at address 00006FFFFFAE2B98 (thread 0218), starting debugger..."
        let run = outcome(.native, exit: 0, after: 148, log: line)
        XCTAssertTrue(run.crashed)
        XCTAssertTrue(run.failed)
        XCTAssertTrue(run.engineFailure)
        var d = Autopilot.afterRun(run, health: &health, nativeAvailable: true, facts: m5, preference: .automatic, alreadyRelaunched: false)
        XCTAssertEqual(d.relaunch, .native)
        d = Autopilot.afterRun(run, health: &health, nativeAvailable: true, facts: m5, preference: .automatic, alreadyRelaunched: true)
        XCTAssertTrue(health.isBenched(.native), "two crashes in a day move the game to D3DMetal")
        XCTAssertTrue(d.repairs.contains { $0.kind == .switchedEngine })
    }
}
