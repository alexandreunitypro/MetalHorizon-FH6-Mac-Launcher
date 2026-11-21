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
    /// The engine the next Play uses is installed (the native one, or Blackwell Engine with D3DMetal and the shim).
    private var componentsDone: Bool {
        edition == .xbox && routeDecision.route == .native ? setup.componentsReady(for: .native) : setup.componentsReady
    }

    /// Steam is signed in once and the game is in its library, fully downloaded.
    private var steamLibraryDone: Bool { setup.steam.signedInOnce && setup.steamGameCheck.ok }

    var journey: [JourneyStep] {
        let done: [(String, String, Bool)]
        switch edition {
        case .xbox:
            done = [("engine", tr("Engine"), componentsDone),
                    ("account", tr("Account"), accountSaved && !signInExpired),
                    ("game", tr("Game"), setup.gameCheck.ok)]
        case .steam:
            done = [("engine", tr("Engine"), componentsDone),
                    ("steam", tr("Steam"), setup.steam.installed),
                    ("library", tr("Library"), steamLibraryDone)]
        }
        var current = done.firstIndex { !$0.2 } ?? done.count
        if activity == .game { current = done.count }
        var steps = done.enumerated().map { index, step in
            JourneyStep(id: step.0, title: step.1,
                        state: step.2 && index != current ? .done : index == current ? .current : .upcoming)
        }
        steps.append(JourneyStep(id: "play", title: tr("Play"), state: current >= done.count ? .current : .upcoming))
        return steps
    }

    var next: NextStep {
        let quit = edition == .xbox ? tr("Quit from the game's own menu, then give the cloud save 30 seconds.")
                                    : tr("Quit from the game's own menu. Steam stays open in the background.")
        if !componentsDone {
            return NextStep(action: .installComponents, title: tr("Install the Engine"), symbol: "arrow.down.circle",
                            hint: tr("Blackwell Engine and Apple's D3DMetal, set up by MetalHorizon. Nothing to download by hand."))
        }
        switch edition {
        case .xbox:
            if signInExpired {
                return NextStep(action: .signIn, title: tr("Sign In Again"), symbol: "person.crop.circle.badge.exclamationmark",
                                hint: tr("Xbox no longer accepts the saved sign-in. Your profile and saves are safe; sign in again on Microsoft's page."))
            }
            if !accountSaved {
                return NextStep(action: .signIn, title: tr("Sign In with Microsoft"), symbol: "person.crop.circle",
                                hint: ownership == .gamePass
                                    ? tr("With the account that has PC Game Pass or Game Pass Ultimate, on Microsoft's own page. MetalHorizon never sees your password.")
                                    : tr("On Microsoft's own page. MetalHorizon never sees your password."))
            }
            if !setup.gameCheck.ok {
                return NextStep(action: .download, title: tr("Download the Game"), symbol: "icloud.and.arrow.down",
                                hint: ownership == .gamePass
                                    ? tr("About 160 GB into %@. Your Game Pass plan must include PC games.", Setup.tildePath(gameDirectory))
                                    : tr("About 160 GB into %@. Your account must own the game.", Setup.tildePath(gameDirectory)))
            }
        case .steam:
            if !setup.steam.installed {
                return NextStep(action: .installSteam, title: tr("Install Steam"), symbol: "arrow.down.circle",
                                hint: tr("Valve's installer, in a space of its own on this Mac. About 30 seconds."))
            }
            if !setup.steam.signedInOnce {
                return NextStep(action: .openSteam, title: tr("Open Steam"), symbol: "macwindow",
                                hint: tr("Sign in in Steam's window; its first start updates Steam and can take 20 minutes. The game's install window follows by itself."))
            }
            if !setup.steamGameCheck.ok {
                if setup.steam.manifest != nil {
                    return NextStep(action: .openSteam, title: tr("Open Steam"), symbol: "macwindow",
                                    hint: tr("Steam is downloading Forza Horizon 6. Play lights up when it is done."))
                }
                return NextStep(action: .openSteam, title: tr("Install the Game"), symbol: "icloud.and.arrow.down",
                                hint: tr("Steam's own install window for Forza Horizon 6. Click Install there."))
            }
        }
        return NextStep(action: .play, title: tr("Play"), symbol: "play.fill", hint: quit)
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
        case .signIn: return tr("Signing In…")
        case .install: return tr("Installing…")
        case .download: return tr("Downloading…")
        case .game: return tr("Playing")
        case .steam: return tr("Steam Is Working…")
        case .preparing: return tr("Getting Ready…")
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
