import XCTest
@testable import MetalHorizon

/// The Doctor's engine and catalogue on made-up situations. Treatments that act on the real Mac (stopping a service,
/// moving a folder) are only detected here, never run.
final class DoctorTests: XCTestCase {
    override class func setUp() { TestEnvironment.ensure() }

    private func patient(_ moment: DoctorMoment, edition: Edition = .xbox, ownership: XboxOwnership = .purchase,
                         runs: [RunRecord] = [], online: Bool? = nil, freeGB: Int64? = 500,
                         translocated: Bool = false, rosetta: Bool = true, facts: MachineFacts? = nil,
                         maxFPS: Int = 0, route: EngineRoute = .automatic) -> Patient {
        var setup = Setup(edition: edition, gameDirectory: "/nonexistent-\(UUID().uuidString)")
        setup.ownership = ownership
        setup.maxFPS = maxFPS
        setup.engineRoute = route
        return Patient(setup: setup, facts: facts ?? MachineFacts(appleSilicon: true, macOSMajor: 27, macOSMinor: 2, memoryGB: 48),
                       moment: moment, runs: runs, gameRunning: false, serviceRunning: false, serviceSocket: true,
                       accountSaved: true, rosetta: rosetta, freeBytes: freeGB.map { $0 * 1_000_000_000 },
                       appTranslocated: translocated, appQuarantined: false, appPath: "/tmp/MetalHorizon.app",
                       online: online, clockSkew: nil, steamNativeRunning: false)
    }

    private func run(_ kind: String = "play", exit: Int = 1, after seconds: Int = 40, findings: [String] = [],
                     route: String? = "d3dmetal", ago: TimeInterval = 60) -> RunRecord {
        var info = SessionInfo(id: "x", directory: URL(fileURLWithPath: "/tmp"), kind: kind, date: Date().addingTimeInterval(-ago),
                               bytes: 0, exitCode: exit, findings: findings)
        info.duration = seconds
        info.route = route
        return RunRecord(info)
    }

    func testTheBudgetStopsATreatmentThatDoesNotCure() async {
        var calls = 0
        let ailment = Ailment(id: "test-ailment", title: "Test", moments: [.idle],
                              detect: { _ in "seen." },
                              treatments: { _, _ in [.automatic(title: "cheap fix") { calls += 1; return "done." }, .explain] },
                              maxAttempts: 2)
        var state = DoctorState()
        for _ in 0..<3 { _ = await Doctor.examine(patient(.idle), actions: DoctorActions(), catalogue: [ailment], state: &state) }
        XCTAssertEqual(calls, 2, "a treatment is tried at most maxAttempts times in its window")
        let third = await Doctor.examine(patient(.idle), actions: DoctorActions(), catalogue: [ailment], state: &state)
        XCTAssertEqual(third.explained, ["test-ailment"], "after the budget, the next treatment (explain) is used")
    }

    func testOutOfMemoryCapsTheFrameRate() async {
        var cap = -1, hud = true
        var actions = DoctorActions()
        actions.setMaxFPS = { cap = $0 }
        actions.setHUD = { hud = $0 }
        var state = DoctorState()
        let exam = await Doctor.examine(patient(.afterRun, runs: [run(exit: 137, after: 600, findings: ["killed-9"])]),
                                        actions: actions, catalogue: Doctor.runtime, state: &state)
        XCTAssertEqual(cap, 30)
        XCTAssertFalse(hud)
        XCTAssertTrue(exam.repairs.contains { $0.title == "Frame cap set to 30" })
    }

    func testOfflineBeforePlayIsExplainedNotTreated() async {
        var state = DoctorState()
        let exam = await Doctor.examine(patient(.beforePlay, ownership: .gamePass, online: false), actions: DoctorActions(),
                                        catalogue: Doctor.xbox.filter { $0.id == "offline" }, state: &state)
        XCTAssertEqual(exam.explained, ["offline"])
        let ailment = Doctor.xbox.first { $0.id == "offline" }!
        XCTAssertTrue(ailment.detect(patient(.beforePlay, ownership: .gamePass, online: false))?.contains("Game Pass") == true)
        XCTAssertNil(ailment.detect(patient(.beforePlay, online: true)))
    }

    func testGamePassLicenceRefusalOffersTheSubscriptionsPage() async {
        var opened: URL?
        var actions = DoctorActions()
        actions.openURL = { opened = $0 }
        var state = DoctorState()
        let exam = await Doctor.examine(patient(.afterRun, ownership: .gamePass, runs: [run(findings: ["licence-not-entitled"])]),
                                        actions: actions, catalogue: Doctor.xbox.filter { $0.id == "licence-not-entitled" }, state: &state)
        let fix = try? XCTUnwrap(exam.pending.first)
        XCTAssertEqual(fix?.button, "Open My Subscriptions")
        XCTAssertTrue(fix?.detail.contains("Game Pass") == true)
        _ = await fix?.action()
        XCTAssertEqual(opened?.host, "account.microsoft.com")
    }

    func testRepeatedNeuralEngineFailuresHandTheGameToTheNativeEngine() async {
        let runs = (0..<3).map { _ in run(exit: 1, after: 20, findings: ["ane-init"]) }
        var state = DoctorState()
        let exam = await Doctor.examine(patient(.afterRun, runs: runs), actions: DoctorActions(),
                                        catalogue: Doctor.runtime.filter { $0.id == "ane-repeated" }, state: &state)
        XCTAssertTrue(exam.repairs.contains { $0.title == "The native engine takes over" })
        XCTAssertTrue(RouteHealth.load().isBenched(.d3dmetal))
        // and the decision follows: D3DMetal is set aside, the native engine runs the game
        let decision = RouteDecision.decide(preference: .automatic, edition: .xbox,
                                            facts: MachineFacts(appleSilicon: true, macOSMajor: 27, macOSMinor: 2, memoryGB: 48),
                                            health: RouteHealth.load(), nativeAvailable: true)
        XCTAssertEqual(decision.route, .native)
        var h = RouteHealth.load(); h.clearBench(.d3dmetal); h.save()
    }

    func testRosettaMissingMovesTheGameToTheNativeEngine() async {
        var chosen: EngineRoute?
        var actions = DoctorActions()
        actions.setEngineRoute = { chosen = $0 }
        var state = DoctorState()
        var p = patient(.launch, rosetta: false, route: .d3dmetal)
        p.setup.engineRoute = .d3dmetal
        let exam = await Doctor.examine(p, actions: actions, catalogue: Doctor.app.filter { $0.id == "rosetta-missing" }, state: &state)
        XCTAssertEqual(chosen, .native)
        XCTAssertTrue(exam.repairs.contains { $0.title == "The native engine runs the game" })
        // on an Intel Mac or older macOS, only the one-click install is offered
        var old = patient(.launch, rosetta: false, facts: MachineFacts(appleSilicon: true, macOSMajor: 26, macOSMinor: 0, memoryGB: 16))
        old.setup.engineRoute = .automatic
        var state2 = DoctorState()
        let exam2 = await Doctor.examine(old, actions: DoctorActions(), catalogue: Doctor.app.filter { $0.id == "rosetta-missing" }, state: &state2)
        XCTAssertEqual(exam2.pending.first?.button, "Install Rosetta")
    }

    func testATranslocatedAppOffersToMoveItself() async {
        var state = DoctorState()
        let exam = await Doctor.examine(patient(.launch, translocated: true), actions: DoctorActions(),
                                        catalogue: Doctor.app.filter { $0.id == "app-translocated" }, state: &state)
        XCTAssertEqual(exam.pending.first?.button, "Move to Applications")
    }

    func testDetectionsThatActOnTheMacAreOnlyDetectedHere() {
        let stale = Doctor.xbox.first { $0.id == "xodus-service-stale" }!
        var p = patient(.idle)
        p.serviceRunning = true
        p.serviceSocket = false
        XCTAssertNotNil(stale.detect(p))
        p.gameRunning = true
        XCTAssertNil(stale.detect(p), "never while the game runs")

        let timeout = Doctor.xbox.first { $0.id == "licence-timeout" }!
        XCTAssertNotNil(timeout.detect(patient(.afterRun, runs: [run(findings: ["xodus-licence-timeout"])])))
        XCTAssertNil(timeout.detect(patient(.afterRun, runs: [run(findings: ["xodus-licence-timeout"], ago: 86_400)])), "an old run does not count")

        let disk = Doctor.disk.first { $0.id == "disk-low" }!
        XCTAssertNotNil(disk.detect(patient(.launch, freeGB: 9)))
        XCTAssertNil(disk.detect(patient(.launch, freeGB: 80)))
    }

    func testTheCatalogueIsWideAndConsistent() {
        let ids = Doctor.catalogue.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ailment ids are unique")
        XCTAssertGreaterThanOrEqual(ids.count, 30)
        for ailment in Doctor.catalogue { XCTAssertFalse(ailment.moments.isEmpty, ailment.id) }
    }

    /// The real line of 7 November: the Keychain window cancelled, xodus stopped with exit 101.
    func testACancelledKeychainWindowIsRecognized() {
        let line = "called `Result::unwrap()` on an `Err` value: Keychain(PlatformFailure(Error { code: -128, message: \"User canceled the operation.\" }))"
        XCTAssertTrue(Diagnostics.scan(text: line, source: "t").contains { $0.id == "keychain-denied" })
    }
}
