import CoreMedia
import CoreVideo
import XCTest
@testable import MetalHorizon

/// Frame generation (MetalDuck, Settings › Graphics): what can be checked without the game or the screen, and Apple's
/// model itself on synthetic frames when this Mac has it.
final class FrameGenerationTests: XCTestCase {
    func testTheSettingsAreKept() {
        let defaults = UserDefaults(suiteName: "metalhorizon.tests.frame-generation")!
        defaults.removePersistentDomain(forName: "metalhorizon.tests.frame-generation")
        XCTAssertEqual(FrameGenerationSettings.load(defaults), FrameGenerationSettings(), "off until the player turns it on")
        let chosen = FrameGenerationSettings(mode: .triple, quality: .p720, showStats: true)
        chosen.save(defaults)
        XCTAssertEqual(FrameGenerationSettings.load(defaults), chosen)
        XCTAssertTrue(chosen.enabled)
    }

    func testTheGameIsCappedSoItsFramesComeEvenly() {
        XCTAssertEqual(FrameGenerationSettings.gameFrameCap(playerCap: 0, multiplier: 1, refresh: 120), 0, "off: no cap of ours")
        XCTAssertEqual(FrameGenerationSettings.gameFrameCap(playerCap: 45, multiplier: 2, refresh: 120), 45, "the player's cap wins")
        XCTAssertEqual(FrameGenerationSettings.gameFrameCap(playerCap: 0, multiplier: 2, refresh: 60), 30)
        XCTAssertEqual(FrameGenerationSettings.gameFrameCap(playerCap: 0, multiplier: 2, refresh: 120), 60)
        XCTAssertEqual(FrameGenerationSettings.gameFrameCap(playerCap: 0, multiplier: 3, refresh: 120), 40)
        XCTAssertEqual(FrameGenerationSettings.gameFrameCap(playerCap: 0, multiplier: 4, refresh: 120), 30)
        XCTAssertEqual(FrameGenerationSettings.gameFrameCap(playerCap: 0, multiplier: 2, refresh: 0), 30, "a screen that says nothing: 60 Hz")
    }

    func testTheSizeKeepsTheWindowsShapeWithinWhatTheModelTakes() {
        // an M5 Pro on macOS 27: 1920 at most on a side, 1920×1080 pixels at most
        let retina = frameGenerationSize(window: CGSize(width: 3456, height: 2234), maxSide: 1920, maxPixels: 2_073_600, quality: .automatic)
        XCTAssertLessThanOrEqual(retina.width * retina.height, 2_073_600)
        XCTAssertLessThanOrEqual(max(retina.width, retina.height), 1920)
        XCTAssertEqual(retina.width / retina.height, 3456.0 / 2234.0, accuracy: 0.01)
        XCTAssertEqual(Int(retina.width) % 2, 0)
        XCTAssertEqual(Int(retina.height) % 2, 0)
        XCTAssertGreaterThan(retina.width * retina.height, 2_073_600 * 0.95, "as large as allowed")
        XCTAssertEqual(frameGenerationSize(window: CGSize(width: 1280, height: 720), maxSide: 1920, maxPixels: 2_073_600, quality: .automatic),
                       CGSize(width: 1280, height: 720), "a small window: its own size")
        XCTAssertEqual(frameGenerationSize(window: CGSize(width: 3840, height: 2160), maxSide: nil, maxPixels: nil, quality: .p720),
                       CGSize(width: 1280, height: 720), "a quality chosen by the player")
        XCTAssertEqual(frameGenerationSize(window: .zero, maxSide: nil, maxPixels: nil, quality: .automatic), .zero)
        XCTAssertEqual(FrameGenerationQuality.automatic.lower, .p720)
        XCTAssertNil(FrameGenerationQuality.p360.lower)
    }

    func testThePhasesAreTheModelsOwnPoints() {
        XCTAssertEqual(frameGenerationPlan(multiplier: 2).frames, 1)
        XCTAssertEqual(frameGenerationPlan(multiplier: 2).phases, [0.5])
        XCTAssertEqual(frameGenerationPlan(multiplier: 4).phases, [0.25, 0.5, 0.75], "2 frames: points at quarters")
        let triple = frameGenerationPlan(multiplier: 3)
        XCTAssertEqual(triple.frames, 3, "8ths, for the points nearest a third and two thirds")
        XCTAssertEqual(triple.phases, [0.375, 0.625])
        for multiplier in 2...4 {
            let plan = frameGenerationPlan(multiplier: multiplier)
            XCTAssertEqual(plan.phases.count, multiplier - 1)
            let grid = (1..<(1 << plan.frames)).map { Float($0) / Float(1 << plan.frames) }
            XCTAssertTrue(plan.phases.allSatisfy { grid.contains($0) }, "\(multiplier)×: on the model's grid")
        }
        XCTAssertTrue(frameGenerationPlan(multiplier: 1).phases.isEmpty)
    }

    func testTheGamesWindowIsFoundAmongTheOthers() {
        func w(_ id: UInt32, _ title: String, _ app: String, _ width: CGFloat, _ height: CGFloat, onScreen: Bool = true) -> FrameGenerationWindow {
            FrameGenerationWindow(id: id, title: title, appName: app, bundleID: "", pid: 42, size: CGSize(width: width, height: height), onScreen: onScreen)
        }
        let steam = w(1, "Steam", "wine64-preloader", 1600, 1000)
        let game = w(2, "Forza Horizon 6", "wine", 1280, 720)
        let tiny = w(3, "Forza Horizon 6", "wine", 100, 50)
        let other = w(4, "Safari", "Safari", 2000, 1200)
        XCTAssertEqual(pickGameWindow([steam, game, tiny, other])?.id, 2, "its title names it")
        XCTAssertEqual(pickGameWindow([steam, w(5, "", "wine", 1920, 1080), other])?.id, 5, "else the largest Wine window that is not Steam's")
        XCTAssertNil(pickGameWindow([steam, other]), "never another app's window, never Steam's")
        XCTAssertNil(pickGameWindow([w(6, "Forza Horizon 6", "wine", 1280, 720, onScreen: false)]), "only a window on screen")
    }

    func testFrameGenerationIsOffUnlessTurnedOn() {
        var setup = Setup()
        setup.maxFPS = 0
        // the test settings domain has frame generation off: the game keeps its own pace
        if !FrameGenerationSettings.load().enabled {
            XCTAssertEqual(setup.frameGenerationMultiplier, 1)
            XCTAssertEqual(setup.optionsEnvironment(gameInput: false)["MH_MAX_FPS"], "0")
        }
    }

    /// Apple's model on two synthetic frames, as the pipeline feeds it: in the capture's own format (converted to the
    /// model's), and at a size this Mac takes. Skipped where the model is missing (before macOS 26).
    func testApplesModelMakesTheFrameInBetween() async throws {
        guard #available(macOS 26.0, *), frameGenerationSupported() else { throw XCTSkip("no frame interpolation model on this Mac") }
        let interpolator = try FrameInterpolator(width: 640, height: 360, multiplier: 2)
        try await interpolator.start()
        defer { Task { await interpolator.stop() } }
        func frame(_ shade: UInt8) throws -> CVPixelBuffer {
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
            XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, attributes, &buffer), kCVReturnSuccess)
            let b = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(b, [])
            memset(CVPixelBufferGetBaseAddress(b), Int32(shade), CVPixelBufferGetBytesPerRow(b) * CVPixelBufferGetHeight(b))
            CVPixelBufferUnlockBaseAddress(b, [])
            return b
        }
        var made: [CVPixelBuffer] = []
        let start = Date()
        var tick: Int64 = 0
        let first = try await interpolator.interpolate(frame(30), at: CMTime(value: tick, timescale: 60))
        XCTAssertTrue(first.isEmpty, "the first frame has nothing before it")
        while made.isEmpty && Date().timeIntervalSince(start) < 10 {
            tick += 1
            made = try await interpolator.interpolate(frame(tick % 2 == 0 ? 30 : 220), at: CMTime(value: tick, timescale: 60))
            if made.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertEqual(made.count, 1, "one frame between each two at 2×")
        let failed = await interpolator.failed
        XCTAssertFalse(failed)
        if let between = made.first {
            XCTAssertEqual(CVPixelBufferGetWidth(between), 640)
            XCTAssertEqual(CVPixelBufferGetHeight(between), 360)
        }
    }
}
