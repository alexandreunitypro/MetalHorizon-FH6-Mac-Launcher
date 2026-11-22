import AppKit
import SwiftUI

/// Settings › General › Language: the Mac's own language by default, or one the player picks. macOS reads the choice
/// when the app starts (AppleLanguages in the app's own settings), so it applies after a relaunch.
struct LanguagePicker: View {
    @State private var choice = LanguagePicker.current
    @State private var changed = false

    /// The languages MetalHorizon has, by their codes, English first.
    static var available: [String] {
        let codes = Bundle.main.localizations.filter { $0 != "Base" }
        return ["en"] + codes.filter { $0 != "en" }.sorted { name($0) < name($1) }
    }

    /// "" is the Mac's language.
    static var current: String {
        (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? appBundleID)?["AppleLanguages"] as? [String])?.first ?? ""
    }

    /// A language named in itself: "Deutsch", "Français", "日本語".
    static func name(_ code: String) -> String {
        Locale(identifier: code).localizedString(forIdentifier: code)?.capitalized(with: Locale(identifier: code)) ?? code
    }

    static func set(_ code: String) {
        if code.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }

    var body: some View {
        Picker("Language", selection: $choice) {
            Text("The Mac's language").tag("")
            ForEach(Self.available, id: \.self) { Text(Self.name($0)).tag($0) }
        }
        .onChange(of: choice) { _, new in
            Self.set(new)
            changed = true
        }
        if changed {
            LabeledContent("Applies when MetalHorizon starts again") {
                Button("Restart MetalHorizon") { Self.relaunch() }
            }
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}
