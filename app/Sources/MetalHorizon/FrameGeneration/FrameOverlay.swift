import AppKit
import AVFoundation
import QuartzCore
import CoreMedia
import CoreVideo

// The window frame generation shows its frames in: borderless, transparent, click-through, laid exactly over the
// game's window and just above its level, following it as it moves, and out of the way whenever the game is not the
// app in front (so it never covers another app's windows). Frames are presented on a timebase, as MetalDuck's overlay
// does (Roberto Camargo, https://github.com/Lospi/MetalDuck, GPL-3.0), with an AVSampleBufferDisplayLayer.

@MainActor
final class FrameOverlay {
    private let windowID: CGWindowID
    private let ownerPID: pid_t
    private var panel: NSPanel?
    private var layer: AVSampleBufferDisplayLayer?
    private var stats: NSTextField?
    private var tracking: Timer?

    init(windowID: CGWindowID, ownerPID: pid_t, showStats: Bool) {
        self.windowID = windowID
        self.ownerPID = ownerPID
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.sharingType = .none   // never captured itself: no image of the overlay goes back into the overlay

        let view = NSView(frame: panel.contentLayoutRect)
        view.wantsLayer = true
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resize
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            layer.controlTimebase = timebase
        }
        view.layer?.addSublayer(layer)
        panel.contentView = view
        self.panel = panel
        self.layer = layer
        if showStats { addStats(to: view) }
        follow()
        tracking = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }
    }

    /// The game's window: where it is (AppKit coordinates), its level, and whether it is on screen at all.
    static func gameWindowInfo(_ id: CGWindowID) -> (frame: NSRect, level: Int, onScreen: Bool)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[CFString: Any]],
              let info = list.first,
              let bounds = info[kCGWindowBounds] as? [String: CGFloat]
        else { return nil }
        let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        // window-server coordinates start at the top left of the primary screen, AppKit's at its bottom left
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        let frame = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        let level = info[kCGWindowLayer] as? Int ?? 0
        let onScreen = info[kCGWindowIsOnscreen] as? Bool ?? true
        return (frame, level, onScreen)
    }

    /// Over the game's window, just above its level, while the game is the app in front; hidden otherwise.
    private func follow() {
        guard let panel else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID
        guard front, let info = Self.gameWindowInfo(windowID), info.onScreen, info.frame.width > 1 else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let level = NSWindow.Level(rawValue: max(info.level + 1, NSWindow.Level.floating.rawValue))
        if panel.level != level { panel.level = level }
        if panel.frame != info.frame { panel.setFrame(info.frame, display: false) }
        // the video layer follows the window's size itself: a sublayer is not resized with its view (MetalHorizon
        // 2.1.0 drew the game in a 640×360 corner of the overlay, issue #15)
        if let layer, let bounds = panel.contentView?.bounds, layer.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = bounds
            CATransaction.commit()
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Shows a frame `delay` seconds from now. Frames are queued only while the renderer takes them, so a stall in
    /// the window server never builds up latency.
    func show(_ buffer: CVPixelBuffer, in delay: Double) {
        guard let layer, let timebase = layer.controlTimebase else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        guard renderer.isReadyForMoreMediaData else { return }
        let when = CMTimeAdd(CMTimebaseGetTime(timebase), CMTime(seconds: max(0, delay), preferredTimescale: 1_000_000))
        guard let sample = Self.sample(buffer, at: when) else { return }
        renderer.enqueue(sample)
    }

    /// Shows a frame now, dropping what is queued (the game's own frame while the model loads).
    func showNow(_ buffer: CVPixelBuffer) {
        guard let layer, let timebase = layer.controlTimebase else { return }
        layer.sampleBufferRenderer.flush()
        if let sample = Self.sample(buffer, at: CMTimebaseGetTime(timebase)) { layer.sampleBufferRenderer.enqueue(sample) }
    }

    func setStats(_ text: String) {
        stats?.stringValue = text
    }

    func close() {
        tracking?.invalidate()
        tracking = nil
        layer?.sampleBufferRenderer.flush()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        layer = nil
    }

    private func addStats(to view: NSView) {
        let label = NSTextField(labelWithString: "MetalDuck")
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .white
        label.drawsBackground = true
        label.backgroundColor = NSColor(white: 0, alpha: 0.55)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
        stats = label
    }

    private static func sample(_ buffer: CVPixelBuffer, at time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr, let format
        else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}
