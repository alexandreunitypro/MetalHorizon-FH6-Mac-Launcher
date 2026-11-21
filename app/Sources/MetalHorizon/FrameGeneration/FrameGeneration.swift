import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// Frame generation while the game plays (Settings › Graphics), after MetalDuck (Roberto Camargo,
// https://github.com/Lospi/MetalDuck, GPL-3.0): MetalHorizon finds the game's window by itself, captures it at the
// size the interpolation model takes, has Apple's model make the frames in between, and shows them over the window.
// It starts when the game starts and stops when it ends; MetalDuck's own menu-bar app is not needed.

@MainActor
final class FrameGeneration: ObservableObject {
    static let shared = FrameGeneration()

    @Published private(set) var status = ""
    @Published private(set) var active = false
    private var task: Task<Void, Never>?
    private var gamePlaying = false

    private init() { status = Self.idleStatus(FrameGenerationSettings.load()) }

    static var supported: Bool { frameGenerationSupported() }
    static var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// macOS asks the player once; after that, the switch is in System Settings › Privacy & Security.
    static func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The launcher's activity: frame generation runs while the game does.
    func gameStateChanged(playing: Bool) {
        guard playing != gamePlaying else { return }
        gamePlaying = playing
        playing ? start() : stop()
    }

    /// The settings changed: applied at once if the game is playing.
    func settingsChanged() {
        if gamePlaying { start() } else { status = Self.idleStatus(FrameGenerationSettings.load()) }
    }

    private func start() {
        cancel()
        let settings = FrameGenerationSettings.load()
        guard settings.enabled else { status = Self.idleStatus(settings); return }
        guard Self.supported else { status = "Needs macOS 26 on Apple silicon."; return }
        guard Self.screenRecordingAllowed else {
            status = "MetalHorizon needs the Screen Recording permission to see the game's window (the button above)."
            return
        }
        guard #available(macOS 26.0, *) else { return }
        active = true
        status = "Waiting for the game's window…"
        let pipeline = FrameGenerationPipeline(settings: settings) { [weak self] text in self?.status = text }
        task = Task { [weak self] in
            await pipeline.run()
            await MainActor.run { self?.active = false }
        }
    }

    private func stop() {
        cancel()
        status = Self.idleStatus(FrameGenerationSettings.load())
    }

    private func cancel() {
        task?.cancel()
        task = nil
        active = false
    }

    private static func idleStatus(_ settings: FrameGenerationSettings) -> String {
        settings.enabled ? "Starts with the game." : "Off."
    }
}

/// One run: find the game's window, capture it, interpolate, show; again from the window if the game makes a new one.
@available(macOS 26.0, *)
final class FrameGenerationPipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let time: CMTime
    }

    /// The frames to show for one of the game's: the interpolated ones, then the game's own.
    private struct Batch: @unchecked Sendable {
        let made: [CVPixelBuffer]
        let own: CVPixelBuffer
    }

    private let settings: FrameGenerationSettings
    private let report: @MainActor (String) -> Void
    private let queue = DispatchQueue(label: "metalhorizon.frame-generation.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var frames: AsyncStream<Frame>.Continuation?

    init(settings: FrameGenerationSettings, report: @escaping @MainActor (String) -> Void) {
        self.settings = settings
        self.report = report
    }

    func run() async {
        var quality = settings.quality
        while !Task.isCancelled {
            let window: SCWindow
            do {
                guard let found = try await gameWindow() else {
                    await report("Waiting for the game's window…")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                window = found
            } catch {
                await report("The game's window cannot be seen: allow MetalHorizon in System Settings › Privacy & Security › Screen Recording, then play again.")
                return
            }
            let pixels = await Self.pixelSize(of: window)
            let limits = frameGenerationLimits()
            let size = frameGenerationSize(window: pixels, maxSide: limits.maxSide, maxPixels: limits.maxPixels, quality: quality)
            guard size.width >= 2 else { try? await Task.sleep(nanoseconds: 1_000_000_000); continue }

            let interpolator: FrameInterpolator
            do {
                interpolator = try FrameInterpolator(width: Int(size.width), height: Int(size.height),
                                                     multiplier: settings.mode.multiplier)
                try await interpolator.start()
            } catch {
                if let lower = quality.lower {
                    quality = lower
                    continue
                }
                await report("Apple's frame interpolation could not start on this Mac.")
                return
            }
            let pid = window.owningApplication?.processID ?? 0
            let overlay = await MainActor.run {
                FrameOverlay(windowID: window.windowID, ownerPID: pid, showStats: settings.showStats)
            }
            let modelFailed = await play(window: window, size: size, interpolator: interpolator, overlay: overlay)
            await stopCapture()
            await interpolator.stop()
            await MainActor.run { overlay.close() }
            if modelFailed {
                // the model did not load at this size (macOS 26 does not say its limits): one size down
                guard let lower = quality.lower else {
                    await report("Apple's frame interpolation does not work at any size on this Mac.")
                    return
                }
                quality = lower
            }
        }
    }

    /// Frames until the window goes away or the run is cancelled; true when the model never loaded at this size.
    private func play(window: SCWindow, size: CGSize, interpolator: FrameInterpolator, overlay: FrameOverlay) async -> Bool {
        let incoming: AsyncStream<Frame>
        do {
            incoming = try await startCapture(window: window, size: size, pixelFormat: interpolator.sourcePixelFormat)
        } catch {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return false
        }
        let multiplier = settings.mode.multiplier
        let label = "\(multiplier)× at \(Int(size.width))×\(Int(size.height))"
        await report("\(label): starting…")
        var previous: CMTime?
        var fromGame = 0, onScreen = 0
        var since = Date()
        for await frame in incoming {
            if Task.isCancelled { break }
            let made = (try? await interpolator.interpolate(frame.buffer, at: frame.time)) ?? []
            if await interpolator.failed { return true }
            let span = previous.map { CMTimeGetSeconds(frame.time) - CMTimeGetSeconds($0) } ?? 0
            previous = frame.time
            fromGame += 1
            onScreen += made.isEmpty ? 1 : made.count + 1
            let batch = Batch(made: made, own: frame.buffer)
            await MainActor.run {
                // the frames in between first, evenly paced over the game's last frame time, then the game's own
                if batch.made.isEmpty || span <= 0 || span > 0.25 {
                    overlay.showNow(batch.own)
                } else {
                    let step = span / Double(batch.made.count + 1)
                    for (i, buffer) in batch.made.enumerated() { overlay.show(buffer, in: step * Double(i)) }
                    overlay.show(batch.own, in: step * Double(batch.made.count))
                }
            }
            let elapsed = Date().timeIntervalSince(since)
            if elapsed >= 1 {
                let game = Double(fromGame) / elapsed, shown = Double(onScreen) / elapsed
                let ready = await interpolator.ready
                let text = ready ? String(format: "%@: %.0f → %.0f fps", label, game, shown) : "\(label): loading Apple's model…"
                await report(text)
                await MainActor.run { overlay.setStats(ready ? String(format: " MetalDuck %d×  %.0f → %.0f fps ", multiplier, game, shown) : " MetalDuck: loading ") }
                fromGame = 0
                onScreen = 0
                since = Date()
            }
        }
        return false
    }

    // MARK: The game's window

    private func gameWindow() async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let candidates = content.windows.map { w in
            FrameGenerationWindow(id: w.windowID, title: w.title ?? "", appName: w.owningApplication?.applicationName ?? "",
                                  bundleID: w.owningApplication?.bundleIdentifier ?? "", pid: w.owningApplication?.processID ?? 0,
                                  size: w.frame.size, onScreen: w.isOnScreen)
        }
        guard let pick = pickGameWindow(candidates) else { return nil }
        return content.windows.first { $0.windowID == pick.id }
    }

    /// The window's size in pixels, on the screen it is on.
    @MainActor
    private static func pixelSize(of window: SCWindow) -> CGSize {
        let scale = NSScreen.screens.first { screen in
            // SCWindow frames start at the top left of the primary screen, NSScreen frames at its bottom left
            let primary = NSScreen.screens.first?.frame.height ?? 0
            let center = CGPoint(x: window.frame.midX, y: primary - window.frame.midY)
            return screen.frame.contains(center)
        }?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
    }

    // MARK: Capture

    private func startCapture(window: SCWindow, size: CGSize, pixelFormat: OSType) async throws -> AsyncStream<Frame> {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.pixelFormat = pixelFormat
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        configuration.queueDepth = 6
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        // two frames at most wait for the model: a slow frame drops the oldest, it never adds latency
        let (incoming, continuation) = AsyncStream.makeStream(of: Frame.self, bufferingPolicy: .bufferingNewest(2))
        frames = continuation
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        return incoming
    }

    private func stopCapture() async {
        try? await stream?.stopCapture()
        stream = nil
        frames?.finish()
        frames = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = attachments[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = sampleBuffer.imageBuffer
        else { return }
        frames?.yield(Frame(buffer: buffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // the window closed, or the game made a new one: the run looks for it again
        frames?.finish()
    }
}
