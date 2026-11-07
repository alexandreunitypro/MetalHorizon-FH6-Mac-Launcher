import AppKit
import SwiftUI

// MetalHorizon 0.5's window: the game's name, the road to Play, and one button that always does the next step.
// Everything else is one step away: the activity log in the inspector, the settings in MetalHorizon › Settings.

/// The few values the window is drawn with; nothing below picks a colour or a size of its own.
enum Theme {
    /// Industrial: graphite and black, no hue. The signal is a dark steel the white label reads on
    /// (about 14:1 in light mode, 9:1 in dark mode).
    static let accent = Color(nsColor: NSColor(name: "MetalHorizonAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.28, green: 0.28, blue: 0.30, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    })
    /// Behind the glass: a cold steel haze, fading towards the middle of the window.
    static let sky = Color(nsColor: NSColor(name: "MetalHorizonSky") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.45, green: 0.46, blue: 0.48, alpha: 0.35)
            : NSColor(srgbRed: 0.40, green: 0.41, blue: 0.43, alpha: 0.30)
    })
    static let track = Color(nsColor: .separatorColor)
    static let panel = Color(nsColor: .quaternaryLabelColor).opacity(0.35)
    static let titleSize: CGFloat = 40
    static let gutter: CGFloat = 40
    static let measure: CGFloat = 620
    static let radius: CGFloat = 12
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @StateObject private var controllers = ControllerMonitor()
    @State private var showActivity: Bool = ProcessInfo.processInfo.environment["MH_SNAPSHOT_ACTIVITY"] == "1"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                JourneyBar(steps: model.journey, busy: model.isBusy)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .glassPanel()
                    .padding(.top, 32)
                stage
                    .padding(.top, 40)
                if !model.attention.isEmpty {
                    AttentionList(items: model.attention, copyRosetta: model.copyRosettaCommand, report: model.reportIssue)
                        .padding(.top, 40)
                }
                Spacer(minLength: 32)
                footer
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(HorizonBackdrop())
        .tint(Theme.accent)
        .toolbar {
            ToolbarItem(placement: .principal) {
                EditionSwitch(edition: $model.edition)
                    .disabled(model.isBusy)
            }
            if #available(macOS 26, *) {
                ToolbarSpacer(.flexible)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showActivity.toggle() } label: { Label("Activity", systemImage: "sidebar.right") }
                    .help("Show or hide the activity log")
            }
        }
        .hidingToolbarTitle()
        .inspector(isPresented: $showActivity) {
            ActivityInspector(model: model)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 640)
        }
        .sheet(isPresented: Binding(get: { model.showWelcome }, set: { if !$0 { model.finishWelcome() } })) {
            WelcomeSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.licenseText != nil }, set: { if !$0 { model.answerLicense(false) } })) {
            LicenseSheet(text: model.licenseText ?? "", answer: model.answerLicense)
        }
        .sheet(item: Binding(get: { model.licenseText == nil && !model.showWelcome ? model.crashReport : nil },
                             set: { if $0 == nil && model.crashReport != nil && !model.crashReportSending { model.dismissCrashReport() } })) { report in
            CrashReportSheet(report: report, sending: model.crashReportSending,
                             send: { model.sendCrashReport(report) }, dismiss: model.dismissCrashReport)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Forza Horizon 6")
                .font(.system(size: Theme.titleSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(model.edition == .xbox ? "Your Xbox copy, on this Mac." : "Your Steam copy, on this Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: The next step

    private var stage: some View {
        let next = model.next
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Button(action: model.performNext) {
                    HStack(spacing: 10) {
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: next.symbol)
                        }
                        Text(model.isBusy ? model.busyTitle : next.title)
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .frame(minWidth: 200, minHeight: 28)
                    .padding(.horizontal, 12)
                }
                .primaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(model.isBusy)

                if model.isBusy {
                    Button(model.activity == .game ? "Force Quit" : "Stop", action: model.stop)
                        .secondaryGlassButton()
                        .help(model.activity == .game
                              ? "Quit from the game's menu when you can: force-quitting skips the cloud save upload."
                              : "Stop what is running")
                }
            }

            if model.activity == .install, let fraction = model.installFraction {
                ProgressView(value: fraction).frame(maxWidth: 360)
            } else if model.activity == .download {
                ProgressView().progressViewStyle(.linear).frame(maxWidth: 360)
            }

            Text(model.isBusy || model.status != "Ready." ? model.status : next.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .animation(nil, value: model.status)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                controllersSummary
                Spacer(minLength: 12)
                if model.edition == .xbox {
                    Button {
                        model.chooseGameDirectory()
                    } label: {
                        Label(Setup.tildePath(model.gameDirectory.isEmpty ? "~/FH6" : model.gameDirectory), systemImage: "folder")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Where the game is. Click to choose another folder.")
                    .disabled(model.isBusy)
                } else if model.setup.steam.installed {
                    Button("Open Steam", action: model.openSteam)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(model.isBusy && model.activity != .game)
                    Button("Stop Steam", action: model.stopSteam)
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(model.isBusy || !model.steamStatus.clientRunning)
                }
            }
            .font(.callout)
        }
    }

    private var controllersSummary: some View {
        let pads = controllers.controllers
        let text: String
        if model.controllerMode == .off { text = "Controllers off" }
        else if pads.isEmpty { text = "No controller" }
        else if pads.count == 1 { text = pads[0].name }
        else { text = "\(pads.count) controllers" }
        return SettingsLink {
            Label(text, systemImage: pads.first?.kind == "Racing wheel" ? "steeringwheel" : "gamecontroller")
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .foregroundStyle(pads.isEmpty ? .secondary : .primary)
        .help(pads.isEmpty
              ? "Xbox, PlayStation, Switch Pro, 8BitDo and most USB or Bluetooth pads work. Plug one in before Play."
              : pads.map { "\($0.name): \($0.route)" }.joined(separator: "\n"))
    }
}

// MARK: - The edition switch

/// Which copy you own, in the middle of the toolbar: two short, equal segments; the full names are in the tooltip. On macOS 26 the toolbar draws it in glass.
struct EditionSwitch: View {
    @Binding var edition: Edition

    var body: some View {
        Picker("Edition", selection: $edition) {
            ForEach(Edition.allCases) { item in
                Text(item.shortTitle).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 190)
        .help("Which copy of Forza Horizon 6 you own: \(Edition.allCases.map(\.title).joined(separator: " or "))")
        .accessibilityLabel("Edition")
    }
}

extension View {
    /// The window's name stays for the Window menu and Mission Control; the bar itself shows only the switch, since
    /// the window already opens on the game's name.
    @ViewBuilder
    func hidingToolbarTitle() -> some View {
        if #available(macOS 15, *) {
            self.toolbar(removing: .title)
        } else {
            self
        }
    }
}

// MARK: - Liquid Glass

/// The sky the glass sits on: a blue horizon at the top of the window, fading out before the middle. Liquid Glass
/// needs something behind it to bend; this is all there is, no picture.
struct HorizonBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.sky, Theme.sky.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
            RadialGradient(colors: [Theme.sky, .clear], center: .topTrailing, startRadius: 0, endRadius: 520)
                .opacity(0.8)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A panel of Liquid Glass on macOS 26 and later (optionally tinted, and reacting to the pointer when
    /// interactive); a quiet filled panel before.
    @ViewBuilder
    func glassPanel(tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius + 6, style: .continuous)
        if #available(macOS 26, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            self.glassEffect(interactive ? glass.interactive() : glass, in: shape)
        } else {
            self.background(tint ?? Theme.panel, in: shape)
        }
    }

    /// The one button: prominent glass in the signal blue on macOS 26 and later, a filled button before.
    @ViewBuilder
    func primaryButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.extraLarge)
                .tint(Theme.accent)
        } else {
            self.buttonStyle(PrimaryButtonStyle())
        }
    }

    @ViewBuilder
    func compactPrimaryButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent).controlSize(.large).tint(Theme.accent)
        } else {
            self.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    @ViewBuilder
    func secondaryGlassButton() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.extraLarge)
        } else {
            self.controlSize(.large)
        }
    }
}

// MARK: - The one button

/// The next step, set big in the signal colour: it stays that colour when the window is behind another one, as the
/// thing to come back to. Pressed, it sinks a little; disabled, it fades.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(minWidth: 240, minHeight: 52)
            .padding(.horizontal, 24)
            .background(Theme.accent.opacity(isEnabled ? 1 : 0.55),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

// MARK: - The road to Play

/// Four stops on one line: what is done is filled, the next step is ringed in the signal colour.
struct JourneyBar: View {
    let steps: [JourneyStep]
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Capsule()
                        .fill(step.state == .upcoming ? Theme.track : Theme.accent)
                        .frame(height: 2)
                        .padding(.top, 11)
                        .frame(maxWidth: .infinity)
                }
                VStack(spacing: 8) {
                    node(step)
                    Text(step.title)
                        .font(.callout.weight(step.state == .current ? .semibold : .regular))
                        .foregroundStyle(step.state == .upcoming ? .secondary : .primary)
                        .fixedSize()
                }
                .frame(width: 64)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(step.title): \(step.state == .done ? "done" : step.state == .current ? "next" : "to do")")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: steps.map(\.state.hashValue))
    }

    @ViewBuilder
    private func node(_ step: JourneyStep) -> some View {
        switch step.state {
        case .done:
            Circle().fill(Theme.accent)
                .frame(width: 24, height: 24)
                .overlay(Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
        case .current:
            Circle().strokeBorder(Theme.accent, lineWidth: 2.5)
                .frame(width: 24, height: 24)
                .overlay(Circle().fill(Theme.accent).frame(width: 9, height: 9))
        case .upcoming:
            Circle().strokeBorder(Theme.track, lineWidth: 2)
                .frame(width: 24, height: 24)
        }
    }
}

// MARK: - What needs attention

struct AttentionList: View {
    let items: [AttentionItem]
    var copyRosetta: () -> Void
    var report: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Divider().padding(.leading, 44) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    icon(item.severity)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).fontWeight(.semibold)
                        Text(item.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if item.rosetta {
                        Button("Copy Command", action: copyRosetta)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 12)
            }
            Divider().padding(.leading, 44)
            HStack {
                Spacer()
                Button("Report an Issue…", action: report)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(12)
        }
        .glassPanel()
    }

    private func icon(_ severity: Severity) -> some View {
        let (name, color): (String, Color) = switch severity {
        case .error: ("xmark.octagon.fill", .red)
        case .warning: ("exclamationmark.triangle.fill", .orange)
        case .info: ("info.circle.fill", .secondary)
        }
        return Image(systemName: name).foregroundStyle(color)
    }
}

// MARK: - The activity log

struct ActivityInspector: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Log", selection: $model.logView) {
                    ForEach(LogView.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 10) {
                    TextField("Search", text: $model.search)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: model.search) { _ in model.filterChanged() }
                    Toggle("Errors only", isOn: $model.errorsOnly)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                        .onChange(of: model.errorsOnly) { _ in model.filterChanged() }
                }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if model.logLines.isEmpty {
                            Text("Nothing has run yet. What MetalHorizon and the game print shows here.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .foregroundStyle(LogFilter.isProblem(line) ? Color(nsColor: .systemRed) : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                }
                .onChange(of: model.logLines.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            Divider()
            HStack {
                Button("Show in Finder", action: model.revealLogs)
                Spacer()
                Button("Export Diagnostics…", action: model.exportDiagnostics)
            }
            .controlSize(.small)
            .padding(12)
        }
    }
}

// MARK: - First launch

/// The first-launch guide: which copy you own, and what happens next. The rest is the main window's one button.
struct WelcomeSheet: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Play Forza Horizon 6 on your Mac.")
                .font(.system(size: 28, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Which copy do you own?")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 12) {
                tile(.xbox, detail: "MetalHorizon downloads it from your Xbox account.")
                tile(.steam, detail: "Steam runs on this Mac, in a space of its own.")
            }
            .padding(.top, 24)

            Text("MetalHorizon then installs its engine and Apple's D3DMetal by itself. Accept Apple's licence when it asks; after that, one button takes you to Play.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            Text("Early alpha. Unofficial, not affiliated with Microsoft, Valve or Apple. You need your own copy of the game.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            HStack {
                Button("Support MetalHorizon…", action: model.openSupportPage)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button("Continue", action: model.finishWelcome)
                    .compactPrimaryButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
        }
        .padding(32)
        .frame(width: 560)
        .background(HorizonBackdrop())
        .tint(Theme.accent)
    }

    private func tile(_ edition: Edition, detail: String) -> some View {
        let selected = model.edition == edition
        return Button { model.edition = edition } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                Text(edition.title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(16)
            .glassPanel(tint: selected ? Theme.accent.opacity(0.25) : nil, interactive: true)
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
