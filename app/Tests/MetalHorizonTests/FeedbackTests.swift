import Foundation
import XCTest
@testable import MetalHorizon

/// Answers a URLSession's requests from the test, or fails them as an offline Mac would.
final class StubServer: URLProtocol {
    nonisolated(unsafe) static var answer: ((URLRequest, Data) -> (Int, [String: String], Data)?)?
    nonisolated(unsafe) static var seen: [(URLRequest, Data)] = []

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.seen.append((request, body))
        guard let (status, headers, data) = Self.answer?(request, body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// The developer's Mac, up: the ping answers, and a report is kept (201).
    static func up(report status: Int = 201, headers: [String: String] = [:]) {
        answer = { request, _ in
            if request.url!.path.hasSuffix("/v1/ping") { return (200, [:], Data(#"{"ok":true}"#.utf8)) }
            return (status, headers, Data(#"{"ok":true}"#.utf8))
        }
    }
}

@MainActor
final class FeedbackTests: XCTestCase {
    override class func setUp() { TestEnvironment.ensure() }

    private var folder: URL!
    private let endpoint = ReportEndpoint(url: URL(string: "https://reports.example.ts.net")!, key: String(repeating: "k", count: 64))

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-tests-\(UUID().uuidString)")
        StubServer.answer = nil
        StubServer.seen = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func outbox() -> ReportOutbox {
        let endpoint = self.endpoint
        return ReportOutbox(folder: folder, endpoint: { endpoint }, session: StubServer.session)
    }

    private func report(kind: FeedbackKind = .feedback, comment: String = "") -> [String: Any] {
        var answers = FeedbackAnswers()
        answers.rating = 4
        answers.reached = .drove
        answers.features = ["controller": .problem, "sound": .works, "online": .untried]
        answers.comment = comment
        return FeedbackReport.json(kind: kind, answers: answers, session: nil, setup: Setup(edition: .xbox, gameDirectory: "/nonexistent"))
    }

    // MARK: What a report holds

    func testAReportSaysNothingPersonal() throws {
        let r = report(comment: "Pad dead. Write me at someone@example.com, see /Users/\(NSUserName())/Library/Logs")
        XCTAssertEqual(r["schema"] as? Int, 1)
        XCTAssertEqual(r["kind"] as? String, "feedback")
        XCTAssertNotNil(UUID(uuidString: r["id"] as? String ?? ""))
        XCTAssertNotNil(UUID(uuidString: r["installation"] as? String ?? ""), "an anonymous ID, nothing else")
        XCTAssertEqual(r["rating"] as? Int, 4)
        let comment = try XCTUnwrap(r["comment"] as? String)
        XCTAssertFalse(comment.contains("someone@example.com"))
        XCTAssertFalse(comment.contains("/Users/\(NSUserName())/"), "the Mac's user name is not in a report")
        XCTAssertTrue(comment.contains("Pad dead."))
        let survey = try XCTUnwrap(r["survey"] as? [String: Any])
        XCTAssertEqual(survey["reached"] as? String, "drove")
        XCTAssertEqual(survey["features"] as? [String: String], ["controller": "problem", "sound": "works"], "what was not tried is left out")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(r))
        let text = String(decoding: try JSONSerialization.data(withJSONObject: r), as: UTF8.self)
        XCTAssertFalse(text.contains(NSUserName() + "/"), "nowhere in it")
        let summary = FeedbackReport.summary(r)
        XCTAssertTrue(summary.contains("★★★★☆"))
        XCTAssertTrue(summary.contains("controller problem"))
    }

    func testTheMacsUserNameIsTakenOutOfPaths() {
        XCTAssertEqual(MCPServer.redactUserName("open /Users/alex/Library/x and /Users/alex", name: "alex"),
                       "open /Users/<user>/Library/x and /Users/<user>")
        XCTAssertEqual(MCPServer.redactUserName(#"C:\users\Alex\AppData"#, name: "alex"), #"C:\users\<user>\AppData"#)
        XCTAssertEqual(MCPServer.redactUserName("/Users/Shared/x", name: "alex"), "/Users/Shared/x")
    }

    func testOnlyTheDevelopersMacOverHTTPSIsAnEndpoint() {
        func parse(_ json: String) -> ReportEndpoint? { ReportEndpoint.parse(Data(json.utf8)) }
        let key = String(repeating: "a", count: 64)
        XCTAssertEqual(parse(#"{"kind":"metalhorizon","url":"https://mac.tail1.ts.net/","key":"\#(key)"}"#)?.reports.absoluteString,
                       "https://mac.tail1.ts.net/v1/reports")
        XCTAssertNotNil(parse(#"{"kind":"metalhorizon","url":"http://127.0.0.1:47811","key":"\#(key)"}"#), "this Mac, for tests")
        XCTAssertNil(parse(#"{"kind":"metalhorizon","url":"http://example.com","key":"\#(key)"}"#), "never plain HTTP over the internet")
        XCTAssertNil(parse(#"{"kind":"metalhorizon","url":"https://mac.tail1.ts.net","key":"short"}"#))
        XCTAssertNil(parse(#"{"kind":"discord","url":"https://discord.com/api/webhooks/1","key":"\#(key)"}"#))
    }

    // MARK: The outbox

    func testAReportWaitsUntilTheDevelopersMacAnswers() async throws {
        let box = outbox()
        let r = report()
        try box.enqueue(report: r, summary: "# r", logs: nil, title: "★★★★☆ · Rating")
        // the developer's Mac is off: nothing is lost, nothing counts as a failure
        await box.flush()
        XCTAssertEqual(box.items.count, 1)
        XCTAssertEqual(box.reachable, false)
        XCTAssertEqual(box.items[0].attempts, 0)
        // the app is closed and opened again: the report is still there
        let reopened = outbox()
        XCTAssertEqual(reopened.items.map(\.id), [(r["id"] as! String).lowercased()])
        // the Mac answers: it goes, and leaves the outbox
        StubServer.up()
        await reopened.flush()
        XCTAssertTrue(reopened.items.isEmpty)
        XCTAssertEqual(reopened.reachable, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(r["id"] as! String).path))
    }

    func testTheRequestIsWhatTheReceiverReads() async throws {
        let box = outbox()
        let logs = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString).zip")
        try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: logs)
        let r = report()
        try box.enqueue(report: r, summary: "# summary", logs: logs, title: "t")
        StubServer.up()
        await box.flush()
        let post = try XCTUnwrap(StubServer.seen.first { $0.0.httpMethod == "POST" })
        XCTAssertEqual(post.0.url?.path, "/v1/reports")
        XCTAssertEqual(post.0.value(forHTTPHeaderField: "X-MetalHorizon-Key"), endpoint.key)
        let type = try XCTUnwrap(post.0.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(type.hasPrefix("multipart/form-data; boundary=MetalHorizon-"))
        let body = String(decoding: post.1, as: UTF8.self)
        XCTAssertTrue(body.contains(#"name="report"; filename="report.json""#))
        XCTAssertTrue(body.contains(#"name="summary"; filename="REPORT.md""#))
        XCTAssertTrue(body.contains(#"name="logs"; filename="logs.zip""#))
        XCTAssertTrue(body.contains(r["id"] as! String))
        XCTAssertTrue(body.hasSuffix("--\r\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs.path), "the zip moved into the outbox, then went")
    }

    func testTheOutboxWaitsAsLongAsTheServerAsks() async throws {
        let box = outbox()
        try box.enqueue(report: report(), summary: nil, logs: nil, title: "t")
        StubServer.up(report: 429, headers: ["Retry-After": "120"])
        let now = Date()
        await box.flush(now: now)
        XCTAssertEqual(box.items.count, 1)
        XCTAssertEqual(box.items[0].nextTry.timeIntervalSince(now), 120, accuracy: 1)
        StubServer.seen = []
        await box.flush(now: now.addingTimeInterval(60))
        XCTAssertTrue(StubServer.seen.isEmpty, "not before the time the server gave")
        StubServer.up()
        await box.flush(now: now.addingTimeInterval(121))
        XCTAssertTrue(box.items.isEmpty)
    }

    func testAReportRefusedThreeTimesIsKeptAsideForThePlayer() async throws {
        let box = outbox()
        try box.enqueue(report: report(), summary: nil, logs: nil, title: "t")
        StubServer.up(report: 422)
        var now = Date()
        for _ in 0..<3 {
            await box.flush(now: now)
            now = now.addingTimeInterval(601)
        }
        XCTAssertEqual(box.items.count, 1)
        XCTAssertTrue(box.items[0].refused)
        XCTAssertTrue(box.waiting.isEmpty)
        StubServer.seen = []
        await box.flush(force: true, now: now)
        XCTAssertTrue(StubServer.seen.isEmpty, "never sent again")
        box.discardAll()
        XCTAssertTrue(box.items.isEmpty)
    }

    func testNothingGoesWhileTheGameRunsAndOldReportsGo() async throws {
        let box = outbox()
        StubServer.up()
        try box.enqueue(report: report(), summary: nil, logs: nil, title: "t")
        box.paused = true
        await box.flush()
        XCTAssertEqual(box.items.count, 1, "paused while the game runs")
        XCTAssertTrue(StubServer.seen.isEmpty)
        box.paused = false
        try box.enqueue(report: report(), summary: nil, logs: nil, title: "old", now: Date().addingTimeInterval(-31 * 86_400))
        box.expire()
        XCTAssertEqual(box.items.map(\.title), ["t"], "a report older than 30 days is dropped")
    }

    /// The real receiver (tools/reports-receiver) on a port of this Mac, when it is built: a report from the outbox
    /// is kept there, listed in its index.
    func testAReportReachesTheRealReceiver() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let receiver = repo.appendingPathComponent("tools/reports-receiver/.build/debug/metalhorizon-reports")
        guard FileManager.default.isExecutableFile(atPath: receiver.path) else { throw XCTSkip("swift build in tools/reports-receiver first") }
        let reports = FileManager.default.temporaryDirectory.appendingPathComponent("receiver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: reports) }
        let process = Process()
        process.executableURL = receiver
        process.arguments = ["serve", "--port", "0", "--dir", reports.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        let ready = DispatchSemaphore(value: 0)
        final class Output: @unchecked Sendable { var text = "" }
        let output = Output()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.text += String(decoding: handle.availableData, as: UTF8.self)
            if output.text.contains("listening on") { ready.signal() }
        }
        try process.run()
        defer { process.terminate(); pipe.fileHandleForReading.readabilityHandler = nil }
        XCTAssertEqual(ready.wait(timeout: .now() + 15), .success, "the receiver started")
        let printed = output.text
        let port = try XCTUnwrap(printed.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression).map { String(printed[$0].split(separator: ":")[1]) })
        let key = try String(contentsOf: reports.appendingPathComponent(".receiver-key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let local = ReportEndpoint(url: URL(string: "http://127.0.0.1:\(port)")!, key: key)
        let box = ReportOutbox(folder: folder, endpoint: { local })
        let r = report(comment: "It works, the pad too")
        try box.enqueue(report: r, summary: FeedbackReport.summary(r), logs: nil, title: "t")
        await box.flush()
        XCTAssertTrue(box.items.isEmpty, "delivered")
        let index = try String(contentsOf: reports.appendingPathComponent("index.tsv"), encoding: .utf8)
        XCTAssertTrue(index.contains((r["id"] as! String).lowercased()))
        XCTAssertTrue(index.contains("It works, the pad too"))
    }
}
