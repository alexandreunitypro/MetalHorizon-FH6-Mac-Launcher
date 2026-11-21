import CoreGraphics
import Foundation

// Frame generation, after MetalDuck (https://github.com/Lospi/MetalDuck, Roberto Camargo, GPL-3.0 like MetalHorizon):
// the game's window is captured as it is drawn (ScreenCaptureKit), Apple's on-device frame interpolation model
// (VideoToolbox, macOS 26) makes one to three frames between each two of the game's, and the result is shown on top
// of the game's window in a click-through overlay. Twice the frames on screen for about one frame of latency, whatever
// the engine (D3DMetal, the native engine, the beta one) and the edition. This file holds what can be decided without
// the screen: the settings, the sizes, the phases, which window is the game's, and the game's frame cap.

enum FrameGenerationKey {
    static let mode = "metalhorizon.frameGeneration.mode"
    static let quality = "metalhorizon.frameGeneration.quality"
    static let showStats = "metalhorizon.frameGeneration.showStats"
}

/// How many frames on screen for each of the game's.
enum FrameGenerationMode: String, CaseIterable, Identifiable {
    case off
    case double = "2x"
    case triple = "3x"
    case quadruple = "4x"

    var id: String { rawValue }
    var multiplier: Int {
        switch self {
        case .off: return 1
        case .double: return 2
        case .triple: return 3
        case .quadruple: return 4
        }
    }
    var title: String {
        switch self {
        case .off: return "Off"
        case .double: return "2× the frames (recommended)"
        case .triple: return "3× the frames"
        case .quadruple: return "4× the frames"
        }
    }
}

/// The size frames are interpolated at. Automatic takes the largest this Mac's model takes, up to the window's size.
enum FrameGenerationQuality: String, CaseIterable, Identifiable {
    case automatic
    case p1080 = "1080p"
    case p720 = "720p"
    case p360 = "360p"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic (the most this Mac takes)"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p360: return "360p"
        }
    }
    /// The largest side it allows, nil for Automatic.
    var maxSide: Int? {
        switch self {
        case .automatic: return nil
        case .p1080: return 1920
        case .p720: return 1280
        case .p360: return 640
        }
    }
    /// The next one down, when the model does not take this one.
    var lower: FrameGenerationQuality? {
        switch self {
        case .automatic, .p1080: return .p720
        case .p720: return .p360
        case .p360: return nil
        }
    }
}

struct FrameGenerationSettings: Equatable {
    var mode = FrameGenerationMode.off
    var quality = FrameGenerationQuality.automatic
    var showStats = false

    var enabled: Bool { mode != .off }

    static func load(_ defaults: UserDefaults = settingsStore()) -> FrameGenerationSettings {
        var s = FrameGenerationSettings()
        s.mode = FrameGenerationMode(rawValue: defaults.string(forKey: FrameGenerationKey.mode) ?? "") ?? .off
        s.quality = FrameGenerationQuality(rawValue: defaults.string(forKey: FrameGenerationKey.quality) ?? "") ?? .automatic
        s.showStats = defaults.bool(forKey: FrameGenerationKey.showStats)
        return s
    }

    func save(_ defaults: UserDefaults = settingsStore()) {
        defaults.set(mode.rawValue, forKey: FrameGenerationKey.mode)
        defaults.set(quality.rawValue, forKey: FrameGenerationKey.quality)
        defaults.set(showStats, forKey: FrameGenerationKey.showStats)
    }

    /// The frame cap the game gets: the player's own when they set one, otherwise the screen's refresh rate divided by
    /// the multiplier, so that the game's frames come at an even pace and the interpolated ones fill the screen's
    /// (60 Hz at 2×: the game at 30; 120 Hz at 2×: at 60). 0 when frame generation is off and the player set none.
    static func gameFrameCap(playerCap: Int, multiplier: Int, refresh: Int) -> Int {
        if playerCap > 0 || multiplier <= 1 { return playerCap }
        let hz = refresh >= 30 ? refresh : 60
        return max(20, hz / multiplier)
    }
}

/// The size frames are captured and interpolated at: the window's pixels, scaled down to the largest side and the
/// pixel count the interpolation model takes on this Mac and to the chosen quality, the aspect kept, sides even.
func frameGenerationSize(window: CGSize, maxSide: Int?, maxPixels: Int?, quality: FrameGenerationQuality) -> CGSize {
    guard window.width >= 2, window.height >= 2 else { return .zero }
    var scale = 1.0
    let longest = Double(max(window.width, window.height))
    if let side = [maxSide, quality.maxSide].compactMap({ $0 }).min(), Double(side) < longest {
        scale = min(scale, Double(side) / longest)
    }
    if let pixels = maxPixels, pixels > 0 {
        let area = Double(window.width * window.height)
        if area * scale * scale > Double(pixels) { scale = min(scale, (Double(pixels) / area).squareRoot()) }
    }
    func even(_ v: CGFloat) -> CGFloat { CGFloat(max(2, Int(Double(v) * scale) & ~1)) }
    return CGSize(width: even(window.width), height: even(window.height))
}

/// The interpolation the model does for a multiplier: how many frames it is configured for and the phases asked of
/// it. The model offers 2^n - 1 evenly spaced points for n frames (0.5 for one; 0.25, 0.5, 0.75 for two): 2× and 4×
/// are exact, 3× takes the points nearest a third and two thirds (3/8 and 5/8 of eight).
func frameGenerationPlan(multiplier: Int) -> (frames: Int, phases: [Float]) {
    switch multiplier {
    case ...1: return (0, [])
    case 2: return (1, [0.5])
    case 3: return (3, [0.375, 0.625])
    default: return (2, [0.25, 0.5, 0.75])
    }
}

/// An on-screen window, as ScreenCaptureKit and the window server describe it.
struct FrameGenerationWindow: Equatable {
    var id: UInt32
    var title: String
    var appName: String
    var bundleID: String
    var pid: Int32
    var size: CGSize
    var onScreen: Bool
}

/// Which window is the game's: one whose title names it, the largest if several; otherwise the largest window of a
/// Wine process that is large enough to be a game and is not Steam's.
func pickGameWindow(_ windows: [FrameGenerationWindow]) -> FrameGenerationWindow? {
    let visible = windows.filter { $0.onScreen && $0.size.width >= 320 && $0.size.height >= 200 }
    func area(_ w: FrameGenerationWindow) -> CGFloat { w.size.width * w.size.height }
    let named = visible.filter { $0.title.range(of: "Forza Horizon", options: .caseInsensitive) != nil }
    if let best = named.max(by: { area($0) < area($1) }) { return best }
    let wine = visible.filter { w in
        let owner = (w.appName + " " + w.bundleID).lowercased()
        return (owner.contains("wine") || owner.contains("forzahorizon")) &&
            w.title.range(of: "steam", options: .caseInsensitive) == nil &&
            w.size.width >= 640 && w.size.height >= 360
    }
    return wine.max(by: { area($0) < area($1) })
}

/// The screen's refresh rate, from the main display's mode (60 when it says nothing, as some panels do).
func mainDisplayRefreshRate() -> Int {
    guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return 60 }
    let hz = Int(mode.refreshRate.rounded())
    return hz >= 30 ? hz : 60
}
