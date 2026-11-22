import AppKit
import SwiftUI

// MetalHorizon 0.5's window: the game's name, the road to Play, and one button that always does the next step.
// Everything else is one step away: the activity log in its panel, the settings in MetalHorizon › Settings.

/// The few values the window is drawn with; nothing below picks a colour or a size of its own.
enum Theme {
    /// Industrial: graphite and black, no hue. The signal is a dark steel the white label reads on
    /// (about 14:1 in light mode, 9:1 in dark mode).
    static let accent = Color(nsColor: NSColor(name: "MetalHorizonAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.28, green: 0.28, blue: 0.30, alpha: 1)
            : NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    })
    /// Behind the glass: deep black, lit from above like a studio shot (the window is always dark: black glass).
    static let void = Color(red: 0.012, green: 0.012, blue: 0.016)
    /// The studio light above the title and its sheen on the glossy floor.
    static let sky = Color(red: 0.62, green: 0.64, blue: 0.68).opacity(0.22)
    static let floorSheen = Color(red: 0.55, green: 0.57, blue: 0.62).opacity(0.10)
    static let track = Color(nsColor: .separatorColor)
    /// Black glass: the panel's body, its lit top edge and its specular highlight.
    static let panel = Color.black.opacity(0.55)
    static let glassTint = Color.black.opacity(0.45)
    static let edgeLight = Color.white.opacity(0.22)
    static let edgeShade = Color.white.opacity(0.03)
    static let specular = Color.white.opacity(0.07)
    /// A lit control: brushed steel, its top edge catching the light; and the groove an unlit one sits in.
    static let steel = LinearGradient(colors: [Color(white: 0.42), Color(white: 0.26)], startPoint: .top, endPoint: .bottom)
    static let litEdge = LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
    static let groove = LinearGradient(colors: [Color.white.opacity(0.03), Color.white.opacity(0.11)], startPoint: .top, endPoint: .bottom)
    static let titleSize: CGFloat = 40
    static let gutter: CGFloat = 40
    static let measure: CGFloat = 620
    static let radius: CGFloat = 12
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @StateObject private var controllers = ControllerMonitor()
    @State private var showActivity: Bool = ProcessInfo.processInfo.environment["MH_SNAPSHOT_ACTIVITY"] == "1"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            topRow
            VStack(alignment: .leading, spacing: 0) {
                header
                JourneyBar(steps: model.journey, busy: model.isBusy)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .glassPanel()
                    .padding(.top, 32)
                stage
                    .padding(.top, 40)
                if !model.pendingFixes.isEmpty {
                    FixesList(fixes: model.pendingFixes, busy: model.isBusy, apply: model.applyFix)
                        .padding(.top, 40)
                }
                if !model.attention.isEmpty {
                    AttentionList(items: model.attention, copyRosetta: model.copyRosettaCommand, report: model.reportIssue)
                        .padding(.top, model.pendingFixes.isEmpty ? 40 : 16)
                }
                if !model.recentRepairs.isEmpty {
                    RepairsList(repairs: model.recentRepairs)
                        .padding(.top, model.attention.isEmpty ? 40 : 16)
                }
                Spacer(minLength: 32)
                footer
            }
            .frame(maxWidth: Theme.measure, alignment: .leading)
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
            }
        }
        // the window's content starts at its very top: no empty band above the switch
        .ignoresSafeArea(.container, edges: .top)
        .background(HorizonBackdrop())
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        // no toolbar: the black glass runs to the top of the window; the edition switch and the activity log's
        // button sit in the window itself, above the title
        .hidingToolbarTitle()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .overlay(alignment: .trailing) {
            if showActivity {
                // a narrow column the full height of the window, against its right edge
                ActivityPanel(model: model, close: { showActivity = false })
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.88), value: showActivity)
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
        .sheet(item: Binding(get: { model.licenseText == nil && !model.showWelcome && model.crashReport == nil ? model.feedback : nil },
                             set: { if $0 == nil && model.feedback != nil && !model.feedbackSending { model.dismissFeedback(FeedbackChoice.current) } })) { request in
            FeedbackSheet(request: request, edition: model.edition, frameGeneration: FrameGenerationSettings.load().enabled,
                          sending: model.feedbackSending,
                          send: { answers, choice in model.sendFeedback(request, answers: answers, choice: choice) },
                          dismiss: { choice in model.dismissFeedback(choice) })
        }
    }

    // MARK: Header

    /// What the toolbar used to hold: which copy you own, and the activity log.
    /// On the line of the window's traffic lights: the edition switch in the middle, the activity log's button at
    /// the right edge (where the toolbar had them, without the toolbar's band).
    private var topRow: some View {
        EditionSwitch(edition: $model.edition)
            .disabled(model.isBusy)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                GlassIconButton(systemImage: "sidebar.right", active: showActivity,
                                help: "Show or hide the activity log (⌥⌘L)") { showActivity.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .padding(.trailing, 14)
            }
            .frame(height: 52)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Forza Horizon 6")
                .font(.system(size: Theme.titleSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(tr(model.edition == .steam ? "Your Steam copy, on this Mac."
                 : model.ownership == .gamePass ? "Your Game Pass copy, on this Mac." : "Your Xbox copy, on this Mac."))
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .reflection()
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
                    Button(model.activity == .game ? tr("Force Quit") : tr("Stop"), action: model.stop)
                        .secondaryGlassButton()
                        .help(model.activity == .game
                              ? tr("Quit from the game's menu when you can: force-quitting skips the cloud save upload.")
                              : tr("Stop what is running"))
                }
            }

            if model.activity == .install, let fraction = model.installFraction {
                ProgressView(value: fraction).frame(maxWidth: 360)
            } else if model.activity == .download {
                DownloadProgressView(meter: model.downloadMeter)
            }

            Text(model.isBusy || model.status != "Ready." ? model.status : next.hint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .animation(nil, value: model.status)

            if model.edition == .xbox && !model.routeDecision.reason.isEmpty {
                EngineLine(decision: model.routeDecision)
            }
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
        if model.controllerMode == .off { text = tr("Controllers off") }
        else if pads.isEmpty { text = tr("No controller") }
        else if pads.count == 1 { text = pads[0].name }
        else { text = tr("%lld controllers", pads.count) }
        return SettingsLink {
            Label(text, systemImage: pads.first?.kind == "Racing wheel" ? "steeringwheel" : "gamecontroller")
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .foregroundStyle(pads.isEmpty ? .secondary : .primary)
        .help(pads.isEmpty
              ? tr("Xbox, PlayStation, Switch Pro, 8BitDo and most USB or Bluetooth pads work. Plug one in before Play.")
              : pads.map { "\($0.name): \($0.route)" }.joined(separator: "\n"))
    }
}

// MARK: - The download

/// The game's download: a filling bar with the percentage, and "12.3 GB of 158 GB · 45 MB/s · about 52 min left".
/// Indeterminate until xodus-cli's first progress line, and for good with an older xodus-cli that prints none.
struct DownloadProgressView: View {
    let meter: DownloadMeter?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let meter, let fraction = meter.fraction {
                GlassProgressBar(fraction: fraction)
                    .accessibilityElement()
                    .accessibilityLabel("Download")
                    .accessibilityValue("\(meter.percent ?? ""), \(meter.summary)")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(meter.summary)
                    Spacer(minLength: 8)
                    Text(meter.percent ?? "").fontWeight(.medium).foregroundStyle(.primary)
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            } else {
                ProgressView().progressViewStyle(.linear)
                if let meter {
                    Text(meter.summary).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }
}

/// A bar in black glass: a dark groove with a lit edge, filled with polished steel that glows a little.
struct GlassProgressBar: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.6))
                    .overlay(Capsule().strokeBorder(LinearGradient(colors: [Theme.edgeShade, Theme.edgeLight.opacity(0.6)],
                                                                   startPoint: .top, endPoint: .bottom), lineWidth: 1))
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.95), Color(white: 0.70), Color(white: 0.55)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: max(8, geometry.size.width * min(max(fraction, 0), 1)))
                    .shadow(color: .white.opacity(0.28), radius: 5)
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: fraction)
    }
}

// MARK: - The edition switch

/// Which copy you own, above the title: two short, equal segments of black glass; the full names are in the tooltip.
struct EditionSwitch: View {
    @Binding var edition: Edition

    var body: some View {
        GlassSegments(selection: $edition, options: Edition.allCases.map { ($0, $0.shortTitle) })
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

/// The studio the glass sits in: deep black, one soft light above the title, and a glossy floor further down whose
/// faint sheen is where the reflections fall. Liquid Glass needs something behind it to bend; this is all there is,
/// no picture.
struct HorizonBackdrop: View {
    var body: some View {
        ZStack {
            Theme.void
            // the light above, falling off before the middle of the window
            RadialGradient(colors: [Theme.sky, Theme.sky.opacity(0.25), .clear], center: UnitPoint(x: 0.5, y: -0.08),
                           startRadius: 0, endRadius: 620)
            // the glossy floor: a faint band where the light comes back, then black again
            LinearGradient(stops: [.init(color: .clear, location: 0.30), .init(color: Theme.floorSheen, location: 0.44),
                                   .init(color: Theme.floorSheen.opacity(0.35), location: 0.62), .init(color: .clear, location: 0.9)],
                           startPoint: .top, endPoint: .bottom)
            // the edges sink into black
            RadialGradient(colors: [.clear, .black.opacity(0.65)], center: .center, startRadius: 320, endRadius: 900)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A panel of deep black glass: Liquid Glass tinted black on macOS 26 and later (reacting to the pointer when
    /// interactive), a dark translucent panel before; on both, a lit top edge and a soft specular highlight, as on
    /// polished black glass.
    @ViewBuilder
    func glassPanel(tint: Color? = nil, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius + 6, style: .continuous)
        let polished = self
            .overlay {
                // the highlight across the top of the glass
                shape.fill(LinearGradient(stops: [.init(color: Theme.specular, location: 0), .init(color: .clear, location: 0.45)],
                                          startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [Theme.edgeLight, Theme.edgeShade, Theme.edgeShade.opacity(0.5)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        if #available(macOS 26, *) {
            let glass = Glass.regular.tint(tint ?? Theme.glassTint)
            polished.glassEffect(interactive ? glass.interactive() : glass, in: shape)
                .shadow(color: .black.opacity(0.6), radius: 24, y: 14)
        } else {
            polished.background(tint ?? Theme.panel, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .shadow(color: .black.opacity(0.6), radius: 24, y: 14)
        }
    }

    /// The view mirrored on the glossy floor below it, fading out quickly, behind what comes next: the reflection of
    /// a product shot. Drawn as an overlay, it takes no room; it is decoration only (no clicks, not read aloud).
    func reflection(opacity: Double = 0.2, depth: Double = 0.45) -> some View {
        overlay(alignment: .bottom) {
            self
                .mask(LinearGradient(stops: [.init(color: .clear, location: 1 - depth), .init(color: .white, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .scaleEffect(x: 1, y: -1, anchor: .bottom)
                .offset(y: 2)
                .opacity(opacity)
                .blur(radius: 1.4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
            // black glass: a dark body lit from the top, with its bright edge
            .background(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.08), Color(white: 0.04)],
                                       startPoint: .top, endPoint: .bottom).opacity(isEnabled ? 1 : 0.55),
                        in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Theme.edgeLight, Theme.edgeShade], startPoint: .top, endPoint: .bottom), lineWidth: 1))
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

// MARK: - The engine and the Autopilot

/// Which engine the next Play uses, in one line; the reason in the tooltip and in Settings › Graphics.
struct EngineLine: View {
    let decision: RouteDecision

    var body: some View {
        SettingsLink {
            Label {
                Text("\(decision.route.title) engine. ").fontWeight(.medium) + Text(decision.route.shortExplanation)
            } icon: {
                Image(systemName: decision.route == .native ? "cpu" : "cube.transparent")
            }
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .help(decision.reason + " " + tr("Change it in Settings › Graphics."))
    }
}

/// What the Doctor found and can fix with one click: what it saw, what the click does, and the button.
struct FixesList: View {
    let fixes: [PendingFix]
    let busy: Bool
    var apply: (PendingFix) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MetalHorizon can fix this")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(Array(fixes.enumerated()), id: \.element.id) { index, fix in
                if index > 0 { Divider().padding(.leading, 44) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fix.title).fontWeight(.semibold)
                        Text(fix.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button(fix.button) { apply(fix) }
                        .disabled(busy)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 4)
        .glassPanel()
    }
}

/// What the Autopilot did in the last day: what it saw and what it changed, newest first.
struct RepairsList: View {
    let repairs: [Repair]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Fixed by MetalHorizon")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(Array(repairs.prefix(4).enumerated()), id: \.element.id) { index, repair in
                if index > 0 { Divider().padding(.leading, 44) }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: symbol(repair.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(repair.title).fontWeight(.semibold)
                            Spacer(minLength: 8)
                            Text(repair.date, style: .relative).font(.caption).foregroundStyle(.tertiary)
                        }
                        Text(repair.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 4)
        .glassPanel()
        .accessibilityElement(children: .contain)
    }

    private func symbol(_ kind: Repair.Kind) -> String {
        switch kind {
        case .fixed: return "wrench.and.screwdriver"
        case .reconfigured: return "slider.horizontal.3"
        case .relaunched: return "arrow.clockwise"
        case .switchedEngine: return "arrow.triangle.swap"
        case .note: return "info.circle"
        }
    }
}

// MARK: - The activity log

/// The activity log, in a panel of black glass that slides in over the right of the window (Esc or the cross closes
/// it): which log, a search, errors only, the lines, and the two ways out (Finder, diagnostics).
struct ActivityPanel: View {
    @ObservedObject var model: LauncherModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Activity")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                Spacer()
                // where the window's activity button is: the same place opens and closes the log
                GlassIconButton(systemImage: "xmark", size: 28, help: "Close the activity log (Esc)", action: close)
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .frame(height: 52)

            VStack(alignment: .leading, spacing: 10) {
                GlassSegments(selection: $model.logView, options: LogView.allCases.map { ($0, $0.title) })
                HStack(spacing: 8) {
                    GlassSearchField(text: $model.search)
                        .onChange(of: model.search) { _ in model.filterChanged() }
                    GlassChip(title: "Errors", systemImage: "exclamationmark.triangle", isOn: $model.errorsOnly)
                        .help("Show only the lines that look like a problem")
                        .onChange(of: model.errorsOnly) { _ in model.filterChanged() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .foregroundStyle(LogFilter.isProblem(line) ? Color(red: 1, green: 0.45, blue: 0.42) : Color.white.opacity(0.78))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(16)
                }
                .overlay {
                    if model.logLines.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "text.alignleft")
                                .font(.system(size: 22, weight: .light))
                            Text(tr(model.search.isEmpty && !model.errorsOnly
                                 ? "Nothing has run yet.\nWhat MetalHorizon and the game print shows here."
                                 : "No line matches."))
                                .font(.callout)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(24)
                    }
                }
                .onChange(of: model.logLines.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }

            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            HStack {
                GlassTextButton(title: "Show in Finder", systemImage: "folder", action: model.revealLogs)
                Spacer()
                GlassTextButton(title: "Export Diagnostics…", systemImage: "square.and.arrow.up", action: model.exportDiagnostics)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        // nearly opaque black glass, its left edge catching the light, casting a shadow on the window
        .background(Theme.void.opacity(0.985))
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(colors: [Theme.edgeLight, Theme.edgeShade, Theme.edgeLight.opacity(0.4)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1)
        }
        .shadow(color: .black.opacity(0.7), radius: 24, x: -10)
        .onExitCommand(perform: close)
    }
}

// MARK: - Black glass controls

/// Segments in black glass: the chosen one is lit (bright steel, white label) and the light slides to a new choice;
/// the others stay in the dark.
struct GlassSegments<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var light

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Theme.steel)
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.litEdge, lineWidth: 1))
                                    .shadow(color: .white.opacity(0.10), radius: 4)
                                    .matchedGeometryEffect(id: "light", in: light)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.groove, lineWidth: 1))
        .opacity(isEnabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: selection)
        .accessibilityElement(children: .contain)
    }
}

/// A round button of black glass with one symbol: dim at rest, brighter under the pointer, lit steel while what it
/// opens is open.
struct GlassIconButton: View {
    let systemImage: String
    var size: CGFloat = 32
    var active = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        if #available(macOS 26, *) {
            // Liquid Glass: the system's round glass button, its glass lit a little while what it opens is open
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Color.white.opacity(active ? 1 : 0.85))
                    .frame(width: size * 0.62, height: size * 0.62)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(size >= 30 ? .large : .regular)
            .tint(active ? Color.white.opacity(0.28) : nil)
            .animation(.easeOut(duration: 0.2), value: active)
            .help(tr(help))
            .accessibilityLabel(tr(help))
        } else {
            classic
        }
    }

    /// Before macOS 26: a round button of black glass drawn by hand.
    private var classic: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(Color.white.opacity(active ? 1 : hovering ? 0.9 : 0.6))
                .frame(width: size, height: size)
                .background(Circle().fill(active ? AnyShapeStyle(Theme.steel) : AnyShapeStyle(Color.black.opacity(hovering ? 0.35 : 0.5))))
                .overlay(Circle().strokeBorder(active ? Theme.litEdge : Theme.groove, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: active)
        .help(tr(help))
        .accessibilityLabel(tr(help))
    }
}

/// An on/off chip of black glass, lit when on.
struct GlassChip: View {
    let title: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(tr(title), systemImage: systemImage)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(Color.white.opacity(isOn ? 1 : 0.55))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Capsule().fill(isOn ? AnyShapeStyle(Theme.steel) : AnyShapeStyle(Color.black.opacity(0.5))))
                .overlay(Capsule().strokeBorder(isOn ? Theme.litEdge : Theme.groove, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A search field set in the black glass.
struct GlassSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.white.opacity(0.4))
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.9))
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.white.opacity(0.4)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.groove, lineWidth: 1))
    }
}

/// A quiet text button for the panel's foot: dim, brighter under the pointer.
struct GlassTextButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(tr(title), systemImage: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(hovering ? 0.92 : 0.55))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// Pressed, a control sinks a little.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
                tile(.xbox, ownership: .purchase, title: "Xbox / Microsoft Store", detail: "Bought with your Microsoft account. MetalHorizon downloads it.")
                tile(.xbox, ownership: .gamePass, title: "PC Game Pass", detail: "Or Game Pass Ultimate, on your Microsoft account. MetalHorizon downloads it.")
                tile(.steam, ownership: nil, title: "Steam", detail: "Steam runs on this Mac, in a space of its own.")
            }
            .padding(.top, 24)

            Text("MetalHorizon then installs its engine and Apple's D3DMetal by itself. Accept Apple's licence when it asks; after that, one button takes you to Play.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)

            Text("1.0 Final Beta. Unofficial, not affiliated with Microsoft, Valve or Apple. You need your own copy of the game, or a Game Pass plan that includes it.")
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
        .frame(width: 660)
        .background(HorizonBackdrop())
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }

    private func tile(_ edition: Edition, ownership: XboxOwnership?, title: String, detail: String) -> some View {
        let selected = model.edition == edition && (ownership == nil || model.ownership == ownership)
        return Button {
            model.edition = edition
            if let ownership { model.ownership = ownership }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                Text(tr(title)).font(.headline)
                Text(tr(detail))
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
