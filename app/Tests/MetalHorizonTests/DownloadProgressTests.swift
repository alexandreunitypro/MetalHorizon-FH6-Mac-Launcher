import XCTest
@testable import MetalHorizon

/// xodus-cli's progress lines (patches/xodus-cli/0006) and what the window makes of them.
final class DownloadProgressTests: XCTestCase {
    func testParsesProgressLines() {
        XCTAssertEqual(DownloadProgress.parse("progress 12300000000 158000000000"),
                       DownloadSample(done: 12_300_000_000, total: 158_000_000_000))
        XCTAssertEqual(DownloadProgress.parse("progress 0 1000"), DownloadSample(done: 0, total: 1000))
        XCTAssertEqual(DownloadProgress.parse("  progress 5 10 "), DownloadSample(done: 5, total: 10))
        // never past the total
        XCTAssertEqual(DownloadProgress.parse("progress 20 10"), DownloadSample(done: 10, total: 10))
    }

    func testNoTotal() {
        XCTAssertEqual(DownloadProgress.parse("progress 42"), DownloadSample(done: 42, total: nil))
        XCTAssertEqual(DownloadProgress.parse("progress 0 0"), DownloadSample(done: 0, total: nil))
        var meter = DownloadMeter()
        meter.add(DownloadSample(done: 12_300_000_000, total: nil), at: Date())
        XCTAssertNil(meter.fraction)
        XCTAssertNil(meter.percent)
        XCTAssertEqual(meter.summary, "12.3 GB downloaded")
    }

    func testIgnoresGarbage() {
        for line in ["", "progress", "progress x 10", "progress 1 2 3", "progress -1 10", "progress 1 -10",
                     "Progress 1 2", "downloading progress 1 2", "progress 1,5 2", "progress 99999999999999999999 1",
                     "thread 'main' panicked at streaming.rs:452", "Downloading ntfs..."] {
            XCTAssertNil(DownloadProgress.parse(line), line)
        }
    }

    func testFormatsBytes() {
        XCTAssertEqual(DownloadProgress.bytes(0), "0.0 MB")
        XCTAssertEqual(DownloadProgress.bytes(5_400_000), "5.4 MB")
        XCTAssertEqual(DownloadProgress.bytes(850_000_000), "850 MB")
        XCTAssertEqual(DownloadProgress.bytes(12_300_000_000), "12.3 GB")
        XCTAssertEqual(DownloadProgress.bytes(158_000_000_000), "158 GB")
        XCTAssertEqual(DownloadProgress.bytes(1_200_000_000_000), "1.2 TB")
    }

    func testFormatsSpeedAndTimeLeft() {
        XCTAssertEqual(DownloadProgress.speed(45_000_000), "45 MB/s")
        XCTAssertEqual(DownloadProgress.speed(2_500_000), "2.5 MB/s")
        XCTAssertEqual(DownloadProgress.speed(800_000), "800 KB/s")
        XCTAssertEqual(DownloadProgress.speed(1_100_000_000), "1.1 GB/s")
        XCTAssertEqual(DownloadProgress.timeLeft(30), "less than a minute left")
        XCTAssertEqual(DownloadProgress.timeLeft(52 * 60 - 10), "about 52 min left")
        XCTAssertEqual(DownloadProgress.timeLeft(2 * 3600 + 5 * 60), "about 2 h 05 min left")
    }

    func testMeterSpeedAndTimeLeft() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let total: Int64 = 158_000_000_000
        var meter = DownloadMeter()
        meter.add(DownloadSample(done: 0, total: total), at: t0)
        XCTAssertEqual(meter.fraction, 0)
        XCTAssertNil(meter.speed)
        XCTAssertEqual(meter.summary, "0.0 MB of 158 GB")
        // half a second is not enough to measure
        meter.add(DownloadSample(done: 22_500_000, total: total), at: t0.addingTimeInterval(0.5))
        XCTAssertNil(meter.speed)
        // 45 MB/s over 2 s
        meter.add(DownloadSample(done: 90_000_000, total: total), at: t0.addingTimeInterval(2))
        XCTAssertEqual(meter.speed ?? 0, 45_000_000, accuracy: 1)
        // then 12.3 GB done, still at 45 MB/s
        meter.add(DownloadSample(done: 12_300_000_000, total: total), at: t0.addingTimeInterval(2 + (12_300_000_000 - 90_000_000) / 45_000_000))
        XCTAssertEqual(meter.speed ?? 0, 45_000_000, accuracy: 1)
        XCTAssertEqual(meter.percent, "7%")
        XCTAssertEqual(meter.summary, "12.3 GB of 158 GB · 45 MB/s · about 54 min left")
        // a slower stretch is smoothed, not taken whole
        meter.add(DownloadSample(done: 12_330_000_000, total: total), at: t0.addingTimeInterval(2 + (12_300_000_000 - 90_000_000) / 45_000_000 + 2))
        XCTAssertEqual(meter.speed ?? 0, 0.7 * 45_000_000 + 0.3 * 15_000_000, accuracy: 1)
    }

    func testCountingAgainResetsTheSpeed() {
        let t0 = Date()
        var meter = DownloadMeter()
        meter.add(DownloadSample(done: 0, total: 1_000_000_000), at: t0)
        meter.add(DownloadSample(done: 100_000_000, total: 1_000_000_000), at: t0.addingTimeInterval(2))
        XCTAssertNotNil(meter.speed)
        meter.add(DownloadSample(done: 0, total: 2_000_000_000), at: t0.addingTimeInterval(3))
        XCTAssertNil(meter.speed)
        XCTAssertEqual(meter.summary, "0.0 MB of 2.0 GB")
    }

    func testActivityLogLeavesProgressLinesOut() {
        let lines = ["Downloading", "progress 1 2", "progress 5", "error: not enough free disk space"]
        XCTAssertEqual(LogFilter.apply(lines, errorsOnly: false, search: ""), ["Downloading", "error: not enough free disk space"])
    }

    // MARK: How a download ends (21 November 2026: "Download finished." with no game)

    /// xodus-cli's line from that download's log, word for word.
    private let shortOfRoom = "not enough free disk space on /Users/alexandre/Documents/FORZA HORIZON 6: need 170545541024 bytes, have 16238161920 bytes (files: 170545541024)"

    func testReadsXodusLineWhenTheDiskIsShortOfRoom() throws {
        let space = try XCTUnwrap(DownloadProgress.notEnoughSpace(shortOfRoom))
        XCTAssertEqual(space.need, 170_545_541_024)
        XCTAssertEqual(space.free, 16_238_161_920)
        for line in ["", "progress 1 2", "not enough free disk space", "need 5 bytes, have 3 bytes", "Download finished."] {
            XCTAssertNil(DownloadProgress.notEnoughSpace(line), line)
        }
    }

    func testTheReportedDownloadIsNotFinished() {
        // the download of 21 November: xodus gave up for lack of room and exited with 0, and there was no game
        let status = DownloadProgress.outcome(exitCode: 0, gameReady: false, log: ["Initializing", shortOfRoom], folder: "~/Documents/FORZA HORIZON 6")
        XCTAssertFalse(status.contains("Download finished"))
        XCTAssertEqual(status, "Not enough free space: the game needs 171 GB in ~/Documents/FORZA HORIZON 6, and 16.2 GB are free. "
                       + "Free some space, or choose a folder on a drive with more room, then press Download the Game again.")
        // the same with xodus-cli 0007, which exits with a failure
        XCTAssertEqual(DownloadProgress.outcome(exitCode: 1, gameReady: false, log: [shortOfRoom], folder: "~/FH6"),
                       DownloadProgress.notEnoughSpaceMessage(need: 170_545_541_024, free: 16_238_161_920, folder: "~/FH6"))
    }

    func testFinishedOnlyWithTheGame() {
        XCTAssertEqual(DownloadProgress.outcome(exitCode: 0, gameReady: true, log: ["progress 10 10"], folder: "~/FH6"), "Download finished.")
        let without = DownloadProgress.outcome(exitCode: 0, gameReady: false, log: ["could not get the licence"], folder: "~/FH6")
        XCTAssertFalse(without.contains("finished"))
        XCTAssertTrue(without.contains("Download the Game"))
        XCTAssertEqual(DownloadProgress.outcome(exitCode: 101, gameReady: false, log: [], folder: "~/FH6"),
                       "The download stopped (error 101). See the activity log.")
    }

    func testCountsTheRoomOfAnExistingDisk() throws {
        let free = try XCTUnwrap(DownloadProgress.availableBytes(at: NSTemporaryDirectory() + "a/folder/not/made/yet"))
        XCTAssertGreaterThan(free, 0, "a folder not made yet counts the room of the disk it would be on")
    }
}
