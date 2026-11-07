import Foundation

// The road to Play: the few steps that are the player's, and the one thing to do next. The window is built on this:
// one button that always does the right next step, so nobody has to read a setup form.

enum StepState { case done, current, upcoming }

struct JourneyStep: Identifiable {
    let id: String
    let title: String
    let state: StepState
}

enum NextAction {
    case installComponents, signIn, download, installSteam, openSteam, play
}

struct NextStep {
    let action: NextAction
    let title: String
    let symbol: String
    let hint: String
}

extension LauncherModel {
    private var componentsDone: Bool { setup.componentsReady }

    /// Steam is signed in once and the game is in its library, fully downloaded.
    private var steamLibraryDone: Bool { setup.steam.signedInOnce && setup.steamGameCheck.ok }

    var journey: [JourneyStep] {
        let done: [(String, String, Bool)]
        switch edition {
        case .xbox:
            done = [("engine", "Engine", componentsDone),
                    ("account", "Account", accountSaved),
                    ("game", "Game", setup.gameCheck.ok)]
        case .steam:
            done = [("engine", "Engine", componentsDone),
                    ("steam", "Steam", setup.steam.installed),
                    ("library", "Library", steamLibraryDone)]
        }
        var current = done.firstIndex { !$0.2 } ?? done.count
        if activity == .game { current = done.count }
        var steps = done.enumerated().map { index, step in
            JourneyStep(id: step.0, title: step.1,
                        state: step.2 && index != current ? .done : index == current ? .current : .upcoming)
        }
        steps.append(JourneyStep(id: "play", title: "Play", state: current >= done.count ? .current : .upcoming))
        return steps
    }

    var next: NextStep {
        let quit = edition == .xbox ? "Quit from the game's own menu, then give the cloud save 30 seconds."
                                    : "Quit from the game's own menu. Steam stays open in the background."
        if !componentsDone {
            return NextStep(action: .installComponents, title: "Install the Engine", symbol: "arrow.down.circle",
                            hint: "Blackwell Engine and Apple's D3DMetal, set up by MetalHorizon. Nothing to download by hand.")
        }
        switch edition {
        case .xbox:
            if !accountSaved {
                return NextStep(action: .signIn, title: "Sign In with Microsoft", symbol: "person.crop.circle",
                                hint: "On Microsoft's own page. MetalHorizon never sees your password.")
            }
            if !setup.gameCheck.ok {
                return NextStep(action: .download, title: "Download the Game", symbol: "icloud.and.arrow.down",
                                hint: "About 160 GB into \(Setup.tildePath(gameDirectory)). Your account must own the game.")
            }
        case .steam:
            if !setup.steam.installed {
                return NextStep(action: .installSteam, title: "Install Steam", symbol: "arrow.down.circle",
                                hint: "Valve's installer, in a space of its own on this Mac. About 30 seconds.")
            }
            if !setup.steam.signedInOnce {
                return NextStep(action: .openSteam, title: "Open Steam", symbol: "macwindow",
                                hint: "Sign in in Steam's window. Its first start updates Steam and can take 20 minutes.")
            }
            if !setup.steamGameCheck.ok {
                return NextStep(action: .openSteam, title: "Open Steam", symbol: "macwindow",
                                hint: setup.steam.manifest != nil
                                    ? "Steam is still downloading Forza Horizon 6. Play lights up when it is done."
                                    : "Install Forza Horizon 6 from your Steam Library. Play lights up when it is done.")
            }
        }
        return NextStep(action: .play, title: "Play", symbol: "play.fill", hint: quit)
    }

    func performNext() {
        switch next.action {
        case .installComponents: Task { await installComponents() }
        case .signIn: connectMicrosoft()
        case .download: download()
        case .installSteam: installSteam()
        case .openSteam: openSteam()
        case .play: play()
        }
    }

    /// What the big button says while something runs.
    var busyTitle: String {
        switch activity {
        case .idle: return ""
        case .signIn: return "Signing In…"
        case .install: return "Installing…"
        case .download: return "Downloading…"
        case .game: return "Playing"
        case .steam: return "Steam Is Working…"
        }
    }

    /// The problems worth the player's attention, most serious first: the checks before Play, then the last run's.
    var attention: [AttentionItem] {
        var items = preflight.filter { $0.severity > .info }.sorted { $0.severity > $1.severity }.map {
            AttentionItem(id: "pre-" + $0.id, severity: $0.severity, title: $0.title, detail: $0.check.fix ?? $0.check.text,
                          rosetta: $0.id == "rosetta")
        }
        items += findings.prefix(3).map {
            AttentionItem(id: "run-\($0.id)", severity: $0.issue.severity, title: $0.issue.title, detail: $0.issue.fix, rosetta: false)
        }
        return items
    }
}

struct AttentionItem: Identifiable {
    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let rosetta: Bool
}

extension Setup {
    /// Where an Xbox copy already downloaded on this Mac is likely to be, so a reinstall or a new Mac finds it without
    /// a folder dialog: the usual short folders in the home folder, and the same on external disks.
    static func detectXboxGame(home: String = NSHomeDirectory(), volumes: String = "/Volumes") -> String? {
        var candidates = ["FH6", "Games/FH6", "Games/Forza Horizon 6", "Forza Horizon 6", "Documents/FH6",
                          "Documents/FORZA HORIZON 6", "Desktop/FH6"].map { home + "/" + $0 }
        let disks = (try? FileManager.default.contentsOfDirectory(atPath: volumes)) ?? []
        for disk in disks.sorted() where !disk.hasPrefix(".") {
            candidates += ["FH6", "Games/FH6", "Forza Horizon 6", "Games/Forza Horizon 6"].map { "\(volumes)/\(disk)/\($0)" }
        }
        return candidates.first { Setup(edition: .xbox, gameDirectory: $0).xboxGameCheck.ok }
    }
}
