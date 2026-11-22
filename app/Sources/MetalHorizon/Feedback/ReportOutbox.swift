import AppKit
import Foundation
import Network

// The outbox: a report the player sends waits here, on their Mac, until the developer's Mac takes it. That Mac
// (tools/reports-receiver) may be asleep or offline, so nothing is lost:
//   - each report is a folder in ~/Library/Application Support/MetalHorizon/Outbox/<id> (report.json, REPORT.md,
//     logs.zip, state.json);
//   - while MetalHorizon is open, it asks every minute whether the developer's Mac answers (a tiny GET), and right
//     away when the network comes back or the app comes to the front; a report goes as soon as it does;
//   - a server that says "later" (429, 503, 507) is waited for as it asks; a server error waits longer each time; a
//     report the server refuses three times is kept aside for the player to see and discard;
//   - nothing goes while the game runs or downloads, and a report older than 30 days is dropped.
// The server keeps a report once by its UUID, so a report sent twice (an answer lost on the way) is kept once.

/// The developer's Mac: Resources/report-endpoint.json {"kind": "metalhorizon", "url": "https://….ts.net", "key": "…"}
/// (tools/reports-receiver makes it). MH_REPORT_ENDPOINT names another such file (tests, a developer's build).
struct ReportEndpoint: Equatable {
    let url: URL
    let key: String

    static var bundled: ReportEndpoint? {
        let override = ProcessInfo.processInfo.environment["MH_REPORT_ENDPOINT"].map { URL(fileURLWithPath: $0) }
        guard let file = override ?? Bundle.main.url(forResource: "report-endpoint", withExtension: "json"),
              let data = try? Data(contentsOf: file) else { return nil }
        return parse(data)
    }

    /// https, or http to this Mac itself (tests); a key of at least 32 characters.
    static func parse(_ data: Data) -> ReportEndpoint? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == "metalhorizon",
              let text = object["url"] as? String, var url = URL(string: text), let host = url.host,
              let key = object["key"] as? String, key.count >= 32 else { return nil }
        let local = host == "127.0.0.1" || host == "localhost"
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        while url.path.hasSuffix("/") && url.path.count > 1 { url.deleteLastPathComponent() }
        return ReportEndpoint(url: url, key: key)
    }

    var ping: URL { url.appendingPathComponent("v1/ping") }
    var reports: URL { url.appendingPathComponent("v1/reports") }
}

struct OutboxItem: Identifiable, Codable, Equatable {
    let id: String
    let kind: String
    let title: String
    let created: Date
    var attempts = 0
    var nextTry: Date
    var lastError: String?
    var refused = false
}

@MainActor
final class ReportOutbox: ObservableObject {
    static let shared = ReportOutbox(folder: supportDirectory.appendingPathComponent("Outbox"), endpoint: { ReportEndpoint.bundled })

    static let maxAge: TimeInterval = 30 * 86_400
    static let maxItems = 50
    static let maxBytes: Int64 = 300 * 1024 * 1024
    static let checkInterval: TimeInterval = 60

    @Published private(set) var items: [OutboxItem] = []
    /// Whether the developer's Mac answered the last time it was asked (nil: not asked yet).
    @Published private(set) var reachable: Bool?
    @Published private(set) var lastDelivery: Date?
    /// While the game runs or downloads, nothing goes.
    var paused = false {
        didSet { if oldValue && !paused { Task { await flush() } } }
    }

    let folder: URL
    private let endpointProvider: () -> ReportEndpoint?
    private let session: URLSession
    private var timer: Timer?
    private var monitor: NWPathMonitor?
    private var activation: NSObjectProtocol?
    private var flushing = false

    init(folder: URL, endpoint: @escaping () -> ReportEndpoint?, session: URLSession = .shared) {
        self.folder = folder
        self.endpointProvider = endpoint
        self.session = session
        load()
    }

    var endpoint: ReportEndpoint? { endpointProvider() }
    var waiting: [OutboxItem] { items.filter { !$0.refused } }

    /// Starts the checks: every minute while something waits, when the network comes back, when the app comes forward.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.flush() }
        }
        monitor.start(queue: DispatchQueue(label: "metalhorizon.outbox.network"))
        self.monitor = monitor
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.flush() }
        }
        Task { await flush() }
    }

    // MARK: Putting a report in

    /// Keeps a report until it is sent: written aside, then moved into place. `logs` (a zip) is moved in.
    @discardableResult
    func enqueue(report: [String: Any], summary: String?, logs: URL?, title: String, now: Date = Date()) throws -> OutboxItem {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = (report["id"] as? String ?? UUID().uuidString).lowercased()
        let staging = folder.appendingPathComponent(".incoming-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: staging.appendingPathComponent("report.json"))
            if let summary { try Data(summary.utf8).write(to: staging.appendingPathComponent("REPORT.md")) }
            if let logs { try fm.moveItem(at: logs, to: staging.appendingPathComponent("logs.zip")) }
            let item = OutboxItem(id: id, kind: report["kind"] as? String ?? "feedback", title: title, created: now, nextTry: now)
            try save(item, in: staging)
            let final = folder.appendingPathComponent(id)
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: staging, to: final)
            items.removeAll { $0.id == id }
            items.append(item)
            trim()
            return item
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: Sending

    /// Sends what is due, oldest first, if the developer's Mac answers. `force` sends what waits for a later try too.
    func flush(force: Bool = false, now: Date = Date()) async {
        guard !flushing, !paused, let endpoint else { return }
        expire(now: now)
        let due = items.filter { !$0.refused && (force || $0.nextTry <= now) }.sorted { $0.created < $1.created }
        guard !due.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        let answers = await Self.ping(endpoint, session: session)
        reachable = answers
        // the developer's Mac is off or offline: the next minute asks again, nothing counts as a failure
        guard answers else { return }
        for item in due {
            let outcome = await Self.deliver(folder.appendingPathComponent(item.id), to: endpoint, session: session)
            switch outcome {
            case .delivered:
                remove(item.id)
                lastDelivery = Date()
            case .later(let seconds, let reason):
                update(item.id) { $0.nextTry = now.addingTimeInterval(seconds); $0.lastError = reason }
            case .failed(let reason):
                // the server erred: longer each time, up to half an hour
                update(item.id) {
                    $0.attempts += 1
                    $0.nextTry = now.addingTimeInterval(min(30 * pow(2, Double($0.attempts - 1)), 1800))
                    $0.lastError = reason
                }
            case .unreachable(let reason):
                update(item.id) { $0.lastError = reason }
                reachable = false
                return
            case .refused(let reason):
                update(item.id) {
                    $0.attempts += 1
                    $0.lastError = reason
                    $0.refused = $0.attempts >= 3
                    $0.nextTry = now.addingTimeInterval(600)
                }
            }
        }
    }

    enum Outcome: Equatable {
        case delivered
        case later(TimeInterval, String)
        case failed(String)
        case unreachable(String)
        case refused(String)
    }

    nonisolated static func ping(_ endpoint: ReportEndpoint, session: URLSession) async -> Bool {
        var request = URLRequest(url: endpoint.ping, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue(endpoint.key, forHTTPHeaderField: "X-MetalHorizon-Key")
        request.setValue("MetalHorizon/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// One report to the developer's Mac: multipart, the parts tools/reports-receiver reads.
    nonisolated static func deliver(_ item: URL, to endpoint: ReportEndpoint, session: URLSession) async -> Outcome {
        guard let report = try? Data(contentsOf: item.appendingPathComponent("report.json")) else { return .refused("report.json is missing") }
        let summary = try? Data(contentsOf: item.appendingPathComponent("REPORT.md"))
        let logs = try? Data(contentsOf: item.appendingPathComponent("logs.zip"))
        let boundary = "MetalHorizon-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint.reports, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue(endpoint.key, forHTTPHeaderField: "X-MetalHorizon-Key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("MetalHorizon/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = multipart(boundary: boundary, report: report, summary: summary, logs: logs)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { return .unreachable("no answer") }
        let said = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String) ?? "HTTP \(http.statusCode)"
        let wait = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
        switch http.statusCode {
        case 200, 201: return .delivered
        case 429: return .later(wait ?? 3600, said)
        case 503: return .later(wait ?? 60, said)
        case 507: return .later(wait ?? 86_400, said)
        case 408, 500...599: return .failed(said)
        default: return .refused(said)
        }
    }

    nonisolated static func multipart(boundary: String, report: Data, summary: Data?, logs: Data?) -> Data {
        var body = Data()
        func part(_ name: String, _ filename: String, _ type: String, _ content: Data) {
            body += Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n".utf8)
            body += content + Data("\r\n".utf8)
        }
        part("report", "report.json", "application/json", report)
        if let summary { part("summary", "REPORT.md", "text/markdown; charset=utf-8", summary) }
        if let logs { part("logs", "logs.zip", "application/zip", logs) }
        body += Data("--\(boundary)--\r\n".utf8)
        return body
    }

    // MARK: The folder

    func discard(_ id: String) { remove(id) }

    func discardAll() { for item in items { remove(item.id) } }

    func load() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var loaded: [OutboxItem] = []
        for entry in folders {
            if entry.lastPathComponent.hasPrefix(".incoming-") { try? fm.removeItem(at: entry); continue }
            guard let data = try? Data(contentsOf: entry.appendingPathComponent("state.json")),
                  let item = try? Self.decoder.decode(OutboxItem.self, from: data) else { continue }
            loaded.append(item)
        }
        items = loaded.sorted { $0.created < $1.created }
    }

    private func save(_ item: OutboxItem, in directory: URL? = nil) throws {
        let place = directory ?? folder.appendingPathComponent(item.id)
        try Self.encoder.encode(item).write(to: place.appendingPathComponent("state.json"), options: .atomic)
    }

    private func update(_ id: String, _ change: (inout OutboxItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        try? save(items[index])
    }

    private func remove(_ id: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(id))
        items.removeAll { $0.id == id }
    }

    /// Reports older than 30 days go.
    func expire(now: Date = Date()) {
        for item in items where now.timeIntervalSince(item.created) > Self.maxAge { remove(item.id) }
    }

    /// At most 50 reports and 300 MB: the oldest logs go first, then the oldest reports.
    private func trim() {
        while items.count > Self.maxItems, let oldest = items.min(by: { $0.created < $1.created }) { remove(oldest.id) }
        var total = Self.size(of: folder)
        for item in items.sorted(by: { $0.created < $1.created }) where total > Self.maxBytes {
            let logs = folder.appendingPathComponent(item.id).appendingPathComponent("logs.zip")
            let size = (try? logs.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if size > 0 { try? FileManager.default.removeItem(at: logs); total -= size }
        }
    }

    private static func size(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker { total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
