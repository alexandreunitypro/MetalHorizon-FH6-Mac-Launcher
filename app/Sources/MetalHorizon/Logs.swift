import Foundation

// MetalHorizon's logs. Every run (Play, a download, Steam's install...) gets its own folder in
// ~/Library/Logs/MetalHorizon/sessions/<date>-<kind>/:
//   output.log    what the script prints: the run's header (versions, the settings that decide the graphics stack),
//                 its steps and, at the end, the error lines worth reading
//   game.log      the game's own output (for the Steam edition, the Steam client's: the game is its child)
//   summary.json  kind, start, duration, exit code and the known problems Diagnostics found in the two files
// Old sessions go once there are more than `keepSessions` or they weigh more than `maxBytes` together.

struct LogSession {
    let kind: String
    let directory: URL
    let started: Date

    var output: URL { directory.appendingPathComponent("output.log") }
    var game: URL { directory.appendingPathComponent("game.log") }
    var summary: URL { directory.appendingPathComponent("summary.json") }
    var id: String { directory.lastPathComponent }

    static func create(kind: String) throws -> LogSession {
        LogStore.rotate()
        let stamp = LogStore.stampFormatter.string(from: Date())
        let dir = LogStore.sessionsDirectory.appendingPathComponent("\(stamp)-\(kind)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = LogSession(kind: kind, directory: dir, started: Date())
        FileManager.default.createFile(atPath: session.output.path, contents: nil)
        FileManager.default.createFile(atPath: session.game.path, contents: nil)
        return session
    }

    /// Writes summary.json once the run is over, with what Diagnostics recognizes in its logs.
    @discardableResult
    func finish(exitCode: Int32, extra: [String: Any] = [:]) -> [Finding] {
        let findings = Diagnostics.scan(files: [output, game])
        var info: [String: Any] = [
            "kind": kind,
            "started": ISO8601DateFormatter().string(from: started),
            "duration_seconds": Int(Date().timeIntervalSince(started)),
            "exit_code": Int(exitCode),
            "findings": findings.map { ["id": $0.issue.id, "title": $0.issue.title, "evidence": $0.evidence] }
        ]
        info.merge(extra) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: summary)
        }
        return findings
    }
}

struct SessionInfo: Identifiable {
    let id: String
    let directory: URL
    let kind: String
    let date: Date
    let bytes: Int64
    let exitCode: Int?
    let findings: [String]
    var duration: Int? = nil        // seconds (summary.json)
    var route: String? = nil        // "native" or "d3dmetal" for a Play run
    var userStopped = false         // Stop or Force Quit
    var evidence: [String: String] = [:]   // finding id -> the line that showed it
}

enum LogStore {
    static let keepSessions = 40
    static let maxBytes: Int64 = 1_500_000_000

    static var sessionsDirectory: URL {
        let dir = logDirectory.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()

    /// Sessions, newest first.
    static func sessions() -> [SessionInfo] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.compactMap { dir -> SessionInfo? in
            let name = dir.lastPathComponent
            guard name.count > 20, let date = stampFormatter.date(from: String(name.prefix(19))) else { return nil }
            let kind = String(name.dropFirst(20))
            var bytes: Int64 = 0
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            var exitCode: Int?
            var findings: [String] = []
            var info = SessionInfo(id: name, directory: dir, kind: kind, date: date, bytes: bytes, exitCode: nil, findings: [])
            if let data = fm.contents(atPath: dir.appendingPathComponent("summary.json").path),
               let summary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                exitCode = summary["exit_code"] as? Int
                let list = summary["findings"] as? [[String: Any]] ?? []
                findings = list.compactMap { $0["id"] as? String }
                info = SessionInfo(id: name, directory: dir, kind: kind, date: date, bytes: bytes, exitCode: exitCode, findings: findings,
                                   duration: summary["duration_seconds"] as? Int,
                                   route: (summary["route"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                   userStopped: summary["user_stopped"] as? Bool ?? false,
                                   evidence: Dictionary(list.compactMap { item in
                                       (item["id"] as? String).map { ($0, item["evidence"] as? String ?? "") }
                                   }, uniquingKeysWith: { a, _ in a }))
            }
            return info
        }.sorted { $0.date > $1.date }
    }

    /// Keeps the newest sessions within `keepSessions` and `maxBytes`; the older ones are deleted (they are logs
    /// MetalHorizon wrote itself, nothing of the player's).
    static func rotate() {
        var total: Int64 = 0
        for (index, session) in sessions().enumerated() {
            total += session.bytes
            if index >= keepSessions || total > maxBytes {
                try? FileManager.default.removeItem(at: session.directory)
            }
        }
    }
}

/// Reads a growing log from where it stopped: each poll costs only the new bytes, and only the last `limit` lines are
/// kept. The activity view used to read the whole file twice a second, which a download's progress lines or a
/// traced run (hundreds of MB) made slow.
final class LogTail {
    let limit: Int
    private(set) var url: URL?
    private var offset: UInt64 = 0
    private var partial = Data()
    private(set) var lines: [String] = []
    private(set) var totalLines = 0

    init(limit: Int = 4000) { self.limit = limit }

    func reset(_ url: URL?) {
        self.url = url
        offset = 0
        partial = Data()
        lines = []
        totalLines = 0
    }

    /// Reads what was added since the last poll; true when there are new lines.
    @discardableResult
    func poll() -> Bool {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0; partial = Data(); lines = []; totalLines = 0 }   // truncated or replaced
        guard size > offset else { return false }
        // a first look at a huge file starts near its end
        if offset == 0, size > 8_000_000 { offset = size - 8_000_000 }
        try? handle.seek(toOffset: offset)
        let chunk = handle.readData(ofLength: Int(min(size - offset, 32_000_000)))
        offset += UInt64(chunk.count)
        var data = partial + chunk
        var fresh: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            fresh.append(String(decoding: data[data.startIndex..<newline], as: UTF8.self))
            data = Data(data[data.index(after: newline)...])
        }
        partial = data
        guard !fresh.isEmpty else { return false }
        totalLines += fresh.count
        lines.append(contentsOf: fresh)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        return true
    }
}

enum LogFilter {
    private static let noise: [NSRegularExpression] = [
        #"^\s*VK_[A-Za-z0-9_]+ v\d+$"#,                       // MoltenVK's extension lists
        #"^\[mvk-info\]"#, #"^\s*(model|type|vendorID|deviceID|pipelineCacheUUID|GPU memory|Metal Shading Language|GPU Family|Read-Write Texture|supports the following)"#,
        #"The following \d+ Vulkan extensions are supported"#, #"Created VkInstance for Vulkan version"#,
        #"FHTRACE"#, #"fh6fault:fh6_fault_report (stack|r[0-9a-z]+ ->|slot|code from)"#,
        #"^\s*\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+ --:--:--"#,   // curl's progress meter
        #"^\s*% Total\s+% Received"#, #"^\s*Dload\s+Upload"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let problem = try? NSRegularExpression(
        pattern: #"(?i)(^STOP:|^WARN|err:|error|unhandled|page fault|exception|terminating|failed|fatal|crash|c0000135|not supported|refus)"#)

    static func isNoise(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return noise.contains { $0.firstMatch(in: line, range: range) != nil }
    }

    static func isProblem(_ line: String) -> Bool {
        guard let problem else { return false }
        return problem.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// What the activity view shows: noise out, then the problems only or the lines with `search`.
    static func apply(_ lines: [String], errorsOnly: Bool, search: String) -> [String] {
        lines.filter { line in
            if line.isEmpty || isNoise(line) { return false }
            if errorsOnly && !isProblem(line) { return false }
            if !search.isEmpty && line.range(of: search, options: .caseInsensitive) == nil { return false }
            return true
        }
    }
}
