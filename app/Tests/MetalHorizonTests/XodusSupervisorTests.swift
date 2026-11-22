import XCTest
@testable import MetalHorizon

/// MetalHorizon's half of the robustness of xodus and the Xbox connection (docs/XODUS-ROBUSTNESS.md, D and E).
final class XodusSupervisorTests: XCTestCase {
    // MARK: xodus' lines

    func testReadsXodusLines() {
        XCTAssertEqual(XodusLine.parse("status index"), .status("index"))
        XCTAssertEqual(XodusLine.parse("status resume 1234"), .status("resume 1234"))
        XCTAssertEqual(XodusLine.parse("error no-space not enough free disk space on /x: need 5 bytes, have 3 bytes (files: 5)"),
                       .error(kind: "no-space", message: "not enough free disk space on /x: need 5 bytes, have 3 bytes (files: 5)"))
        XCTAssertEqual(XodusLine.parse("error network"), .error(kind: "network", message: ""))
        for garbage in ["", "status", "status ", "error", "error ", "progress 1 2", "statuses index", "Downloading ntfs..."] {
            XCTAssertNil(XodusLine.parse(garbage), garbage)
        }
    }

    func testStepsAndFailuresInWords() {
        XCTAssertEqual(XodusMessages.phase("index"), "Reading the package's index (about 1 GB)…")
        XCTAssertEqual(XodusMessages.phase("resume 12"), "Resuming the download: 12 files are already there…")
        XCTAssertNotNil(XodusMessages.phase("licence"))
        XCTAssertNil(XodusMessages.phase("something new"))
        for kind in ["no-space", "not-owned", "signed-out", "keychain", "clock", "disk", "package", "network"] {
            XCTAssertFalse(XodusMessages.failure(kind: kind, detail: "", folder: "~/FH6").isEmpty, kind)
        }
        XCTAssertTrue(XodusMessages.failure(kind: "keychain", detail: "", folder: "~/FH6").contains("Always Allow"))
        XCTAssertTrue(XodusMessages.failure(kind: "signed-out", detail: "", folder: "~/FH6").contains("Sign In Again"))
        let space = XodusMessages.failure(kind: "no-space",
                                          detail: "not enough free disk space on /x: need 170545541024 bytes, have 16238161920 bytes (files: 170545541024)",
                                          folder: "~/FH6")
        XCTAssertTrue(space.contains("171 GB") && space.contains("16.2 GB"), space)
        XCTAssertEqual(XodusMessages.failure(kind: "clock", detail: "This Mac's clock is 12 minutes ahead.", folder: "~/FH6"),
                       "This Mac's clock is 12 minutes ahead.")
    }

    func testTheActivityLogLeavesXodusLinesOut() {
        let lines = ["status index", "error network The Xbox servers could not be reached", "opening the package: timed out", "progress 1 2"]
        XCTAssertEqual(LogFilter.apply(lines, errorsOnly: false, search: ""), ["opening the package: timed out"])
    }

    // MARK: what to do when a download ends

    private func end(_ code: Int32, ready: Bool = false, log: [String] = [], retries: Int = 0, stopped: Bool = false,
                     stalled: Bool = false, missing: Bool = false) -> DownloadDecision {
        DownloadSupervisor.decide(DownloadEnd(exitCode: code, gameReady: ready, log: log, folder: "~/FH6", retriesDone: retries,
                                              userStopped: stopped, stalled: stalled, missingFetched: missing))
    }

    func testStopIsAPause() {
        guard case .paused(let text) = end(130, stopped: true) else { return XCTFail("Stop pauses") }
        XCTAssertTrue(text.contains("Download the Game"))
        guard case .paused = end(15, stopped: true) else { return XCTFail("an older xodus killed by SIGTERM: a pause too") }
    }

    func testFinishedOnlyWithTheGame() {
        XCTAssertEqual(end(0, ready: true), .finished("Download finished."))
        guard case .fetchMissing = end(0, ready: false) else { return XCTFail("the missing files are fetched once") }
        guard case .failed(let text) = end(0, ready: false, missing: true) else { return XCTFail("then it says so") }
        XCTAssertFalse(text.contains("finished"))
    }

    func testFailuresNoRetryFixes() {
        let room = "not enough free disk space on /x: need 170545541024 bytes, have 16238161920 bytes (files: 170545541024)"
        guard case .failed(let space) = end(1, log: [room, "error no-space " + room]) else { return XCTFail("no room: no retry") }
        XCTAssertTrue(space.contains("171 GB"))
        for kind in ["not-owned", "signed-out", "keychain", "clock", "disk", "package"] {
            guard case .failed = end(1, log: ["error \(kind) why"]) else { return XCTFail("\(kind) is final") }
        }
    }

    func testTransientFailuresResumeWithGrowingPauses() {
        XCTAssertEqual(DownloadSupervisor.retryDelays, [30, 60, 120, 240, 480])
        for (retries, delay) in DownloadSupervisor.retryDelays.enumerated() {
            guard case .retry(let after, let text) = end(1, log: ["error network The servers could not be reached"], retries: retries)
            else { return XCTFail("network failure \(retries) resumes") }
            XCTAssertEqual(after, delay)
            XCTAssertTrue(text.contains("could not be reached"), text)
        }
        guard case .failed(let text) = end(1, log: ["error network down"], retries: 5) else { return XCTFail("five resumes at most") }
        XCTAssertTrue(text.contains("5 times"))
        // an older xodus-cli that crashed says nothing: resumed too
        guard case .retry(30, _) = end(101) else { return XCTFail("a crash without an error line resumes") }
        // nothing came for 10 minutes: restarted at once
        guard case .retry(5, let stalled) = end(130, stalled: true) else { return XCTFail("a stalled download restarts") }
        XCTAssertTrue(stalled.contains("10 minutes"))
    }

    func testTheWatchdogsLimits() {
        XCTAssertFalse(DownloadSupervisor.isStalled(silentFor: 599, filesStarted: true))
        XCTAssertTrue(DownloadSupervisor.isStalled(silentFor: 601, filesStarted: true))
        XCTAssertFalse(DownloadSupervisor.isStalled(silentFor: 1200, filesStarted: false), "the index and the licence print no progress")
        XCTAssertTrue(DownloadSupervisor.isStalled(silentFor: 1801, filesStarted: false))
    }

    @MainActor
    func testTheMacStaysAwakeUntilTheDownloadIsOver() {
        let supervisor = DownloadSupervisor.shared
        supervisor.begin()
        XCTAssertTrue(supervisor.keepsTheMacAwake)
        supervisor.ended(resuming: true)
        XCTAssertTrue(supervisor.keepsTheMacAwake, "awake through the pause before a resume")
        supervisor.ended(resuming: false)
        XCTAssertFalse(supervisor.keepsTheMacAwake)
    }

    // MARK: before a download

    func testChecksBeforeADownload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mh-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(DownloadPreflight.problem(folder: folder.path + "/FH6", accountSaved: true), "a folder still to make, in a writable one")
        XCTAssertNotNil(DownloadPreflight.problem(folder: folder.path, accountSaved: false), "signed out")
        XCTAssertNotNil(DownloadPreflight.problem(folder: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/FH6", accountSaved: true))
        XCTAssertNotNil(DownloadPreflight.problem(folder: "/System/Library/FH6", accountSaved: true), "a folder that cannot be written")
    }

    func testCountsTheFilesAlreadyDownloaded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mh-journal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(ResumeJournal.filesDone(in: folder.path), 0)
        try "package abc 10\ndone a.bin\ndone Content\\b c.pak\n".write(to: folder.appendingPathComponent(ResumeJournal.name),
                                                                    atomically: true, encoding: .utf8)
        XCTAssertEqual(ResumeJournal.filesDone(in: folder.path), 2)
    }

    // MARK: the Xbox connection

    func testSignInStates() {
        for state in ["network_error", "keychain_denied", "device_error", "clock_wrong", "complete", "cancelled"] {
            XCTAssertTrue(SignInStates.end.contains(state), state)
            XCTAssertNotNil(SignInStates.message(state), state)
        }
        XCTAssertEqual(SignInStates.message("complete"), "Xbox account connected.", "finishSignIn knows a success by it")
        XCTAssertNil(SignInStates.message("unknown"))
        XCTAssertTrue(SignInStates.terminalMessages.contains(SignInStates.message("keychain_denied")!))
        XCTAssertFalse(SignInStates.terminalMessages.contains(SignInStates.message("complete")!))
    }

    @MainActor
    func testASignInThatDoesNotMoveIsEnded() {
        let watch = SignInWatch()
        let t0 = Date()
        watch.reset(now: t0)
        XCTAssertFalse(watch.stuck(state: "waiting_for_microsoft", now: t0))
        XCTAssertFalse(watch.stuck(state: "waiting_for_microsoft", now: t0.addingTimeInterval(899)))
        XCTAssertTrue(watch.stuck(state: "waiting_for_microsoft", now: t0.addingTimeInterval(901)))
        XCTAssertFalse(watch.stuck(state: "received_response", now: t0.addingTimeInterval(902)), "a change starts the count again")
    }

    func testChecksBeforeASignIn() {
        XCTAssertNil(SignInPreflight.problem(online: true, skew: 30))
        XCTAssertNil(SignInPreflight.problem(online: true, skew: nil))
        XCTAssertTrue(SignInPreflight.problem(online: false, skew: nil)!.contains("cannot be reached"))
        let clock = SignInPreflight.problem(online: true, skew: 600)!
        XCTAssertTrue(clock.contains("10 minutes ahead of"), clock)
        XCTAssertTrue(SignInPreflight.problem(online: true, skew: -900)!.contains("15 minutes behind"))
    }

    func testTheAccountCheckIsAskedAgainThenKept() {
        AccountCheck.forget()
        var answers: [AccountCheck?] = [.unreachable("timed out"), .unreachable("timed out"), .accepted]
        var pauses: [TimeInterval] = []
        let t0 = Date()
        let first = AccountCheck.checked(resources: nil, now: t0, sleep: { pauses.append($0) }, run: { _ in answers.removeFirst() })
        XCTAssertEqual(first, .accepted)
        XCTAssertEqual(pauses, [5, 15], "asked again after 5 s, then 15 s")

        // kept for 5 minutes: Microsoft is not asked
        var asked = 0
        let kept = AccountCheck.checked(resources: nil, now: t0.addingTimeInterval(120), sleep: { _ in },
                                        run: { _ in asked += 1; return .refused("x") })
        XCTAssertEqual(kept, .accepted)
        XCTAssertEqual(asked, 0)

        // after 5 minutes, or after a new sign-in, it is asked again; a refusal is never kept
        let later = AccountCheck.checked(resources: nil, now: t0.addingTimeInterval(301), sleep: { _ in },
                                         run: { _ in asked += 1; return .refused("expired") })
        XCTAssertEqual(later, .refused("expired"))
        XCTAssertEqual(asked, 1)
        AccountCheck.forget()
        let again = AccountCheck.checked(resources: nil, now: t0.addingTimeInterval(302), sleep: { _ in },
                                         run: { _ in asked += 1; return .noSignIn })
        XCTAssertEqual(again, .noSignIn)
        XCTAssertEqual(asked, 2)
        AccountCheck.forget()
    }
}
