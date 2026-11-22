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

/// The sizes to try, largest first, for a window of `window` pixels. Apple's model takes some sizes and not others,
/// with no rule it states: on an M5 Pro, 1920×1080, 1728×1116 and 1600×1001 load, 1920×1072, 1790×1158 and 1776×1158
/// never do (MetalHorizon 2.1.0 tried the window's own shape and sat on "loading", issue #15). So each candidate is
/// tried on the model before anything is shown: widths of a common size, the window's shape kept, the standard 16:9
/// sizes for a 16:9 window, all within the model's stated limits and the chosen quality.
func frameGenerationCandidates(window: CGSize, maxSide: Int?, maxPixels: Int?, quality: FrameGenerationQuality) -> [CGSize] {
    guard window.width >= 2, window.height >= 2 else { return [] }
    let aspect = Double(window.width / window.height)
    let longestAllowed = [maxSide, quality.maxSide].compactMap { $0 }.min() ?? Int.max
    func fits(_ s: CGSize) -> Bool {
        let longest = Int(max(s.width, s.height))
        return s.width >= 2 && s.height >= 2 && longest <= longestAllowed && s.width <= window.width && s.height <= window.height
            && (maxPixels.map { Int(s.width * s.height) <= $0 } ?? true)
    }
    var sizes: [CGSize] = []
    if abs(aspect - 16.0 / 9.0) < 0.02 {
        sizes += [CGSize(width: 1920, height: 1080), CGSize(width: 1600, height: 900), CGSize(width: 1280, height: 720),
                  CGSize(width: 960, height: 540), CGSize(width: 640, height: 360)]
    }
    for width in [1920, 1792, 1728, 1664, 1600, 1536, 1440, 1344, 1280, 1152, 1024, 960, 896, 800, 768, 640] {
        let height = max(2, Int((Double(width) / aspect).rounded()) & ~1)
        sizes.append(CGSize(width: width, height: height))
    }
    // a window smaller than every common size: its own (even) size
    sizes.append(CGSize(width: Int(window.width) & ~1, height: Int(window.height) & ~1))
    var seen = Set<String>()
    return sizes.filter(fits)
        .filter { seen.insert("\(Int($0.width))x\(Int($0.height))").inserted }
        .sorted { $0.width * $0.height > $1.width * $1.height }
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
