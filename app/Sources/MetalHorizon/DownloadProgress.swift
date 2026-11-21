import Foundation

// The game's download, in numbers. xodus-cli (patches/xodus-cli/0006), run with XODUS_PROGRESS=lines, prints
// `progress <bytes done> <bytes total>` about twice a second: the bytes of the files this run fetches (an update or a
// download started again counts only what it fetches). The window turns them into a filling bar and one line such as
// "12.3 GB of 158 GB · 45 MB/s · about 52 min left". An older xodus-cli prints none: the bar stays indeterminate.

struct DownloadSample: Equatable {
    var done: Int64
    var total: Int64?
}

enum DownloadProgress {
    /// The lines xodus-cli prints for the app; the activity view leaves them out (LogFilter).
    static let linePattern = #"^progress \d+( \d+)?$"#

    /// `progress <done> <total>` (or `progress <done>`); anything else is nil. A total of 0 is no total.
    static func parse(_ line: String) -> DownloadSample? {
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 || parts.count == 3, parts[0] == "progress", let done = Int64(parts[1]), done >= 0 else { return nil }
        var total: Int64?
        if parts.count == 3 {
            guard let value = Int64(parts[2]), value >= 0 else { return nil }
            total = value > 0 ? value : nil
        }
        return DownloadSample(done: total.map { min(done, $0) } ?? done, total: total)
    }

    /// Decimal units, as the Finder counts: "850 MB", "12.3 GB", "158 GB".
    static func bytes(_ count: Int64) -> String {
        let value = Double(max(count, 0))
        if value >= 1e12 { return String(format: "%.1f TB", value / 1e12) }
        if value >= 1e11 { return String(format: "%.0f GB", value / 1e9) }
        if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
        if value >= 1e7 { return String(format: "%.0f MB", value / 1e6) }
        return String(format: "%.1f MB", value / 1e6)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1e9 { return String(format: "%.1f GB/s", bytesPerSecond / 1e9) }
        if bytesPerSecond >= 1e7 { return String(format: "%.0f MB/s", bytesPerSecond / 1e6) }
        if bytesPerSecond >= 1e6 { return String(format: "%.1f MB/s", bytesPerSecond / 1e6) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1e3)
    }

    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 60 { return tr("less than a minute left") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return tr("about %lld min left", minutes) }
        return tr("about %lld h %@ min left", minutes / 60, String(format: "%02d", minutes % 60))
    }
}

// MARK: - How a download ends

// 21 November 2026: with 16 GB free, xodus-cli fetched the package's index (about 1 GB), found it needed 171 GB, said
// so and stopped, but with exit code 0: the window said "Download finished.", Download the Game stayed, and there was
// no game. xodus-cli now exits with a failure (patches/xodus-cli/0007); the window also checks the room before a first
// download, and after any download looks at what xodus said and whether the game is there.
extension DownloadProgress {
    /// The room the game's files take, as xodus-cli asked for it on 21 November 2026 (170.5 GB). xodus checks the
    /// exact figure itself once it has read the package's index.
    static let gameBytes: Int64 = 170_545_541_024

    /// The room left where the game goes, counted as xodus-cli counts it: what the volume has available now, without
    /// the space macOS could purge (xodus refuses on this figure, so a check on a larger one would let it fail).
    static func availableBytes(at path: String) -> Int64? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    }

    /// xodus-cli's line when the disk is short of room:
    /// `not enough free disk space on <folder>: need <n> bytes, have <m> bytes (files: <t>)`.
    static func notEnoughSpace(_ line: String) -> (need: Int64, free: Int64)? {
        guard let regex = try? NSRegularExpression(pattern: #"not enough free disk space on .*: need (\d+) bytes, have (\d+) bytes"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let needRange = Range(match.range(at: 1), in: line), let freeRange = Range(match.range(at: 2), in: line),
              let need = Int64(line[needRange]), let free = Int64(line[freeRange]) else { return nil }
        return (need, free)
    }

    /// What the window says when the room is missing.
    static func notEnoughSpaceMessage(need: Int64, free: Int64, folder: String) -> String {
        "Not enough free space: the game needs \(bytes(need)) in \(folder), and \(bytes(free)) are free. "
            + "Free some space, or choose a folder on a drive with more room, then press Download the Game again."
    }

    /// What the window says when xodus-cli's download ends. An exit code of 0 is not enough on its own: an older
    /// xodus-cli exited with 0 after giving up, so the game must be there too.
    static func outcome(exitCode: Int32, gameReady: Bool, log: [String], folder: String) -> String {
        if let space = log.lazy.compactMap(notEnoughSpace).last {
            return notEnoughSpaceMessage(need: space.need, free: space.free, folder: folder)
        }
        if exitCode == 0 && gameReady { return "Download finished." }
        if exitCode == 0 {
            return "The download ended without the game. What xodus said is in the activity log; press Download the Game to try again."
        }
        return "The download stopped (error \(exitCode)). See the activity log."
    }
}

/// The download's state from its progress lines: where it is, and a speed smoothed over a few seconds (a single
/// half-second would make the time left jump around).
struct DownloadMeter: Equatable {
    private(set) var done: Int64 = 0
    private(set) var total: Int64?
    /// Bytes per second, smoothed; nil until a few seconds have passed.
    private(set) var speed: Double?
    private var anchorTime: Date?
    private var anchorDone: Int64 = 0

    /// Speed is measured over at least this long, then smoothed (exponential moving average).
    static let window: TimeInterval = 2
    static let smoothing = 0.3

    mutating func add(_ sample: DownloadSample, at time: Date) {
        if sample.done < done {
            // counting started again: so does the speed
            anchorTime = nil
            speed = nil
        }
        done = sample.done
        total = sample.total
        guard let start = anchorTime else { anchorTime = time; anchorDone = done; return }
        let elapsed = time.timeIntervalSince(start)
        guard elapsed >= Self.window else { return }
        let rate = Double(done - anchorDone) / elapsed
        speed = speed.map { $0 + Self.smoothing * (rate - $0) } ?? rate
        anchorTime = time
        anchorDone = done
    }

    /// 0...1 when the total is known.
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    var percent: String? { fraction.map { "\(Int(($0 * 100).rounded(.down)))%" } }

    var secondsLeft: Double? {
        guard let total, let speed, speed > 1 else { return nil }
        return Double(max(total - done, 0)) / speed
    }

    /// "12.3 GB of 158 GB · 45 MB/s · about 52 min left"; without a total, "12.3 GB downloaded · 45 MB/s".
    var summary: String {
        var parts = [total.map { tr("%@ of %@", DownloadProgress.bytes(done), DownloadProgress.bytes($0)) }
                     ?? tr("%@ downloaded", DownloadProgress.bytes(done))]
        if let speed { parts.append(DownloadProgress.speed(speed)) }
        if let secondsLeft { parts.append(DownloadProgress.timeLeft(secondsLeft)) }
        return parts.joined(separator: " · ")
    }
}
