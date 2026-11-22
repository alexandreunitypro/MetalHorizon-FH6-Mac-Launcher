import AppKit
import Foundation

/// Turns the player's answers into a report and sends it: into the outbox when this build knows the developer's Mac
/// (Resources/report-endpoint.json), else a GitHub issue for what the developer needs to read.
@MainActor
enum FeedbackSender {
    static func send(_ request: FeedbackRequest, answers: FeedbackAnswers, setup: Setup) async -> String {
        let report = FeedbackReport.json(kind: request.kind, answers: answers, session: request.session, setup: setup)
        let summary = FeedbackReport.summary(report)
        let zip = answers.attachLogs ? await logsZip(setup) : nil
        if ReportOutbox.shared.endpoint != nil {
            do {
                try ReportOutbox.shared.enqueue(report: report, summary: summary, logs: zip, title: title(request.kind, answers))
                Task { await ReportOutbox.shared.flush() }
                return tr("Thank you! Your report goes to the developer as soon as their Mac answers.")
            } catch {
                return tr("Could not keep the report: %@", error.localizedDescription)
            }
        }
        // no developer's Mac in this build: a rating alone stays here; a problem or a comment opens a GitHub issue
        let hasProblem = request.kind == .problem || answers.features.values.contains(.problem)
            || !answers.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (answers.rating > 0 && answers.rating <= 2)
        guard hasProblem else { return tr("Thank you for your rating!") }
        openIssue(summary: summary, title: title(request.kind, answers), edition: setup.edition, zip: zip)
        return tr("A GitHub issue opened with your report: click Submit there, and drop in the logs zip shown in Finder.")
    }

    /// In "Send Automatically" mode: the run's summary (play time, error codes, engine), without logs or a comment.
    static func sendSessionSummary(_ session: SessionInfo, setup: Setup) {
        guard ReportOutbox.shared.endpoint != nil else { return }
        let report = FeedbackReport.json(kind: .session, answers: nil, session: session, setup: setup)
        _ = try? ReportOutbox.shared.enqueue(report: report, summary: FeedbackReport.summary(report), logs: nil,
                                         title: tr("Session summary") + " · " + FeedbackReport.duration(session.duration ?? 0))
        Task { await ReportOutbox.shared.flush() }
    }

    /// A crash report (CrashReport.swift), into the outbox.
    static func sendCrash(_ crash: CrashReport, text: String, zip: URL, setup: Setup) throws {
        let session = LogStore.sessions().first { $0.id == crash.id }
        let report = FeedbackReport.json(kind: .crash, answers: nil, session: session, setup: setup, crash: crash)
        try ReportOutbox.shared.enqueue(report: report, summary: text, logs: zip, title: tr("Crash report") + " · " + crash.headline)
        Task { await ReportOutbox.shared.flush() }
    }

    static func title(_ kind: FeedbackKind, _ answers: FeedbackAnswers) -> String {
        let stars = answers.rating > 0 ? String(repeating: "★", count: answers.rating) + String(repeating: "☆", count: 5 - answers.rating) + " · " : ""
        return stars + kind.title
    }

    /// The diagnostics zip (Diagnostics.exportBundle: secrets removed), made off the main thread.
    private static func logsZip(_ setup: Setup) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("metalhorizon-feedback-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try? Diagnostics.exportBundle(setup, to: folder)
        }.value
    }

    private static func openIssue(summary: String, title: String, edition: Edition, zip: URL?) {
        var components = URLComponents(string: "https://github.com/alexandreunitypro/MetalHorizon-FH6-Mac-Launcher/issues/new")!
        let body = summary.count > 6000 ? String(summary.prefix(6000)) + "\n\n(cut)" : summary
        components.queryItems = [URLQueryItem(name: "title", value: "[feedback] [\(edition.rawValue)] \(title)"),
                                 URLQueryItem(name: "body", value: body + (zip == nil ? "" : "\n\n**Logs**: attached zip (secrets removed)."))]
        if let url = components.url { NSWorkspace.shared.open(url) }
        if let zip { NSWorkspace.shared.activateFileViewerSelecting([zip]) }
    }
}
