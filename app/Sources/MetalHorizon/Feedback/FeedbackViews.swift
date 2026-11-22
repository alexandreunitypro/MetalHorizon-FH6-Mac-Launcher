import SwiftUI

/// What the player chooses for next time, in the feedback window itself.
enum FeedbackChoice: String, CaseIterable, Identifiable {
    case ask, automatic, quiet
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: return tr("Ask me after each game")
        case .automatic: return tr("Send automatically, without asking")
        case .quiet: return tr("Don't ask after games")
        }
    }

    static var current: FeedbackChoice {
        if FeedbackPreferences.askAfterGames { return .ask }
        return CrashReport.mode == .automatic ? .automatic : .quiet
    }
}

/// After a game (or Tools › Report a Problem…): the stars, how far the game got, what worked, a comment, Send. One
/// click is enough: everything but Send is optional.
struct FeedbackSheet: View {
    let request: FeedbackRequest
    let edition: Edition
    let frameGeneration: Bool
    let sending: Bool
    var send: (FeedbackAnswers, FeedbackChoice) -> Void
    var dismiss: (FeedbackChoice) -> Void

    @State private var answers = FeedbackAnswers()
    @State private var choice = FeedbackChoice.current
    @State private var hovered = 0

    private var problem: Bool { request.kind == .problem }
    private var features: [FeedbackFeature] { FeedbackFeature.list(edition: edition, frameGeneration: frameGeneration) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if problem { commentBox }
                    GroupBox(label: Text("How far did the game get?")) {
                        Picker("", selection: $answers.reached) {
                            ForEach(ReachedPoint.allCases) { Text($0.title).tag(Optional($0)) }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                    GroupBox(label: Text("What worked?")) {
                        VStack(spacing: 6) {
                            ForEach(features) { feature in
                                HStack {
                                    Text(feature.title)
                                    Spacer()
                                    Picker("", selection: Binding(get: { answers.features[feature.id] ?? .untried },
                                                                  set: { answers.features[feature.id] = $0 })) {
                                        ForEach(FeatureState.allCases) { Text($0.title).tag($0) }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 250)
                                }
                            }
                        }
                        .padding(4)
                    }
                    if !problem { commentBox }
                    DisclosureGroup("What is sent") {
                        Text("Your answers, the versions of MetalHorizon, macOS and the engine, this Mac's chip and memory, the run's length and errors, your MetalHorizon settings, and the logs if attached. Never your name, your accounts or your files. This Mac is known only by an anonymous ID.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .font(.callout)
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 360)
            Toggle("Attach the logs (passwords, tokens, e-mail addresses, Xbox and Steam IDs and your Mac's user name are removed)",
                   isOn: $answers.attachLogs)
                .font(.callout)
            HStack {
                if !problem {
                    Picker("Next time", selection: $choice) {
                        ForEach(FeedbackChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 300)
                }
                Spacer()
                if sending { ProgressView().controlSize(.small) }
                Button("Not Now") { dismiss(choice) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(sending)
                Button("Send") { send(answers, choice) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || (problem && answers.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && answers.reached == nil))
            }
        }
        .padding(20)
        .frame(width: 580)
        .tint(Theme.accent)
        .onAppear { if problem { answers.attachLogs = true } }
    }

    private var commentBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tr(problem ? "What happens? What did you do just before?" : "Anything to add? (optional)"))
                .font(.callout)
            TextEditor(text: $answers.comment)
                .font(.body)
                .frame(height: 72)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
        }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr(problem ? "Report a Problem" : "How did Forza Horizon 6 run?"))
                .font(.title3.weight(.semibold))
            if let line = sessionLine {
                Text(line).font(.callout).foregroundStyle(.secondary)
            }
            if !problem {
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { star in
                        Button { answers.rating = answers.rating == star ? 0 : star } label: {
                            Image(systemName: star <= max(hovered, answers.rating) ? "star.fill" : "star")
                                .font(.system(size: 26))
                                .foregroundStyle(star <= max(hovered, answers.rating) ? Color.orange : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovered = $0 ? star : (hovered == star ? 0 : hovered) }
                        .help(tr("%lld out of 5", star))
                        .accessibilityLabel(tr("%lld out of 5", star))
                    }
                }
            } else {
                Text("The developer reads every report. The logs help the most.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var sessionLine: String? {
        guard let session = request.session else { return nil }
        let length = FeedbackReport.duration(session.duration ?? 0)
        switch session.route {
        case "native": return tr("You played %@, on the native engine.", length)
        case "d3dmetal": return tr("You played %@, on Rosetta and D3DMetal.", length)
        default: return tr("You played %@.", length)
        }
    }
}

/// Settings › Feedback: what is sent and when, what waits to be sent, the anonymous ID.
struct FeedbackSettings: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject private var outbox = ReportOutbox.shared
    @State private var askAfterGames = FeedbackPreferences.askAfterGames
    @State private var installation = FeedbackIdentity.installation

    var body: some View {
        Form {
            Section {
                Picker("Send reports", selection: $model.crashReportMode) {
                    ForEach(CrashReportMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Ask how the game ran after each game", isOn: $askAfterGames)
                    .onChange(of: askAfterGames) { _, value in FeedbackPreferences.askAfterGames = value }
                Text("Ask Me: nothing is sent until you click Send. Send Automatically: crash reports and each run's summary (play time, errors, engine) go without asking. Never: nothing is sent or asked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Report a Problem…") { model.reportProblem() }
                    Button("Rate the Last Game…") { model.rateLastGame() }
                }
            }
            Section("Waiting to be sent") {
                if outbox.endpoint == nil {
                    Text("This build has no report server: a problem report opens a GitHub issue instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if outbox.items.isEmpty {
                    Text("Nothing: every report has reached the developer.").foregroundStyle(.secondary)
                } else {
                    ForEach(outbox.items) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).lineLimit(1)
                            Text(state(of: item)).font(.caption).foregroundStyle(item.refused ? Color.red : Color.secondary)
                        }
                    }
                    HStack {
                        Button("Send Now") { Task { await outbox.flush(force: true) } }
                            .disabled(outbox.endpoint == nil)
                        Button("Discard All", role: .destructive) { outbox.discardAll() }
                    }
                    Text("A report waits here until the developer's Mac answers: MetalHorizon asks every minute while open, and drops it after 30 days.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Privacy") {
                LabeledContent("Anonymous ID of this Mac") {
                    HStack {
                        Text(String(installation.prefix(8))).font(.system(.body, design: .monospaced))
                        Button("New ID") { installation = FeedbackIdentity.renew() }
                    }
                }
                Text("Reports carry this ID so the developer can tell reports from the same Mac apart. It says nothing about you.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { outbox.load() }
    }

    private func state(of item: OutboxItem) -> String {
        let date = item.created.formatted(date: .abbreviated, time: .shortened)
        if item.refused { return tr("%@ · refused by the server: %@", date, item.lastError ?? "") }
        if outbox.reachable == false { return tr("%@ · waiting for the developer's Mac", date) }
        return tr("%@ · waiting to be sent", date)
    }
}
