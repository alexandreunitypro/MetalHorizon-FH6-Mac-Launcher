import Foundation

// MetalHorizon speaks the Mac's language. Its screens (the window, the menus, Settings, the activity log, the first
// launch, the download) are translated in app/Resources/Localization/<language>.lproj/Localizable.strings, which
// build-app.sh puts in the app; macOS picks the language from System Settings › General › Language & Region (or the
// app's own choice there), with nothing to set in MetalHorizon. A language without a translation, or a sentence
// without one, shows in English. The detailed messages (diagnostics, repairs, the status line) are English for now.
//
// SwiftUI translates the text written in a view (Text("Play"), Button("Stop")) by itself. tr() is for the text a view
// gets from elsewhere: a step's title, a menu choice's name, a sentence with a value in it.

/// The English text in the Mac's language when MetalHorizon has it, else as it is.
func tr(_ english: String) -> String {
    Bundle.main.localizedString(forKey: english, value: english, table: nil)
}

/// A sentence with values: the English key has %@ (text) or %lld (a whole number) where they go.
func tr(_ format: String, _ arguments: CVarArg...) -> String {
    String(format: tr(format), locale: Locale.current, arguments: arguments)
}
