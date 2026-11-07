import SwiftUI

// MetalHorizon › Settings (Cmd-,): what the main window keeps out of the way. Nothing here is needed to play.

struct SettingsView: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            GraphicsSettings(model: model)
                .tabItem { Label("Graphics", systemImage: "display") }
            ControllerSettings(model: model)
                .tabItem { Label("Controllers", systemImage: "gamecontroller") }
            AdvancedSettings(model: model)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 560)
        .tint(Theme.accent)
    }
}

/// One line of a check: the light, what was found, and a button when there is something to do.
private struct CheckRow: View {
    let title: String
    let check: Check
    var button: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let button, let action { Button(button, action: action) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: check.ok ? (check.fix == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill") : "xmark.circle.fill")
                    .foregroundStyle(check.ok ? (check.fix == nil ? Color.green : Color.orange) : Color.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(check.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(check.fix ?? check.text)
                }
            }
        }
    }
}

private struct GeneralSettings: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section {
                Picker("Edition", selection: $model.edition) {
                    ForEach(Edition.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.isBusy)
            }
            Section("Game") {
                if model.edition == .xbox {
                    CheckRow(title: "Game folder", check: model.setup.gameCheck, button: "Choose…", action: model.chooseGameDirectory)
                } else {
                    CheckRow(title: "Steam", check: model.setup.steamClientCheck)
                    CheckRow(title: "Forza Horizon 6", check: model.setup.steamGameCheck)
                    LabeledContent("Steam's space on this Mac") {
                        HStack {
                            if !model.steamPrefix.isEmpty { Button("Use MetalHorizon's", action: model.useDefaultSteamPrefix) }
                            Button("Choose…", action: model.chooseSteamPrefix)
                        }
                    }
                    Text(Setup.tildePath(model.setup.steamPrefixPath) + ". An existing Highball, CrossOver or Whisky bottle with Steam works too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Components") {
                CheckRow(title: "Blackwell Engine", check: model.setup.engineCheck,
                         button: model.setup.engineCheck.ok ? nil : "Install",
                         action: { Task { await model.installComponents() } })
                CheckRow(title: "Apple D3DMetal", check: model.setup.d3dmetalCheck,
                         button: model.setup.d3dmetalCheck.ok ? nil : "Install…",
                         action: { Task { await model.installComponents() } })
                Text("Both install and update by themselves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.edition == .xbox {
                Section("Xbox account") {
                    LabeledContent(model.accountSaved ? "Signed in, kept in the macOS Keychain" : "Not signed in") {
                        Button(model.accountSaved ? "Sign In Again…" : "Sign In…", action: model.connectMicrosoft)
                            .disabled(model.isBusy)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 420)
    }
}

private struct GraphicsSettings: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section {
                Toggle("Metal Performance HUD", isOn: $model.metalHUD)
                Toggle("MetalFX upscaling", isOn: $model.metalFX)
                Text("Turns DLSS on in the game's own settings, drawn by Apple's MetalFX.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Frame cap", selection: $model.maxFPS) {
                    Text("None").tag(0)
                    ForEach([30, 40, 45, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 260)
    }
}

private struct ControllerSettings: View {
    @ObservedObject var model: LauncherModel
    @StateObject private var monitor = ControllerMonitor()

    var body: some View {
        Form {
            Section {
                Picker("In the game", selection: $model.controllerMode) {
                    ForEach(ControllerMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Connected") {
                if monitor.controllers.isEmpty {
                    Text("None. Xbox, PlayStation, Switch Pro, 8BitDo and most USB or Bluetooth pads work: plug one in, or pair it in System Settings › Bluetooth.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(monitor.controllers) { pad in
                    LabeledContent {
                        Text(pad.route).foregroundStyle(.secondary)
                    } label: {
                        Label(pad.name, systemImage: pad.kind == "Racing wheel" ? "steeringwheel" : "gamecontroller")
                    }
                }
            }
            Section {
                LabeledContent("Wine's controller panel") {
                    Button("Test…") { model.runTool("joycpl") }
                        .disabled(model.isBusy && model.edition == .xbox)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 340)
    }
}

private struct AdvancedSettings: View {
    @ObservedObject var model: LauncherModel

    var body: some View {
        Form {
            Section {
                Toggle("Relaunch after D3DMetal's start-up failure", isOn: $model.autoRetry)
                Picker("Crash reports", selection: $model.crashReportMode) {
                    ForEach(CrashReportMode.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                LabeledContent("Wine prefix") { Button("Show in Finder", action: model.revealPrefix) }
                LabeledContent("Wine configuration") { Button("Open…") { model.runTool("winecfg") } }
                LabeledContent("Logs") { Button("Show in Finder", action: model.revealLogs) }
                LabeledContent("Diagnostics for an issue") { Button("Export…", action: model.exportDiagnostics) }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 320)
    }
}
