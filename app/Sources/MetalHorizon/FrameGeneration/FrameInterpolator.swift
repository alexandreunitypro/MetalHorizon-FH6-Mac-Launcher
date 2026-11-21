import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import VideoToolbox

// Apple's low-latency frame interpolation (VideoToolbox, macOS 26) on live frames: given the game's previous frame and
// its new one, the frames in between. Adapted from MetalDuck's RealTimeFrameInterpolation (Roberto Camargo,
// https://github.com/Lospi/MetalDuck, GPL-3.0): one pixel transfer session reused for every copy instead of one per
// frame, the phases the model actually offers (frameGenerationPlan), and a model that does not load in time reported
// as such, so the caller steps the size down.

@available(macOS 26.0, *)
actor FrameInterpolator {
    enum Fault: Error {
        case unsupported, noConfiguration, noPool, noBuffer, noFrame, noParameters, transferFailed
    }

    /// How long the model may take to give its first frame before this size counts as not supported here.
    static let modelLoadTimeout: TimeInterval = 5

    let size: CMVideoDimensions
    let phases: [Float]
    private let configuration: VTLowLatencyFrameInterpolationConfiguration
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private nonisolated(unsafe) let processor = VTFrameProcessor()
    private var transfer: VTPixelTransferSession?
    private var started = false
    private var previous: (buffer: CVPixelBuffer, time: CMTime)?
    private var firstTry: Date?
    private(set) var ready = false
    private(set) var failed = false

    init(width: Int, height: Int, multiplier: Int) throws {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { throw Fault.unsupported }
        let plan = frameGenerationPlan(multiplier: multiplier)
        guard plan.frames > 0,
              let configuration = VTLowLatencyFrameInterpolationConfiguration(
                frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: plan.frames)
        else { throw Fault.noConfiguration }
        self.size = CMVideoDimensions(width: Int32(width), height: Int32(height))
        self.phases = plan.phases
        self.configuration = configuration
        self.sourcePool = try Self.pool(configuration.sourcePixelBufferAttributes)
        self.destinationPool = try Self.pool(configuration.destinationPixelBufferAttributes)
        var session: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr {
            transfer = session
        }
    }

    /// The pixel format the model takes (the capture is asked for it, so most frames need no conversion).
    nonisolated var sourcePixelFormat: OSType {
        (configuration.sourcePixelBufferAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value
            ?? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    func start() throws {
        guard !started else { return }
        try processor.startSession(configuration: configuration)
        started = true
    }

    func stop() {
        guard started else { return }
        processor.endSession()
        started = false
        previous = nil
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
        transfer = nil
    }

    /// The frames to show between the previous frame and this one, in order (empty for the first frame, while the
    /// model loads, and once it has failed to load). The caller shows them, then the frame itself.
    func interpolate(_ frame: CVPixelBuffer, at time: CMTime) async throws -> [CVPixelBuffer] {
        guard started else { return [] }
        let current = try compatible(frame)
        defer { previous = (current, time) }
        guard let before = previous, CMTimeCompare(time, before.time) > 0, !failed else { return [] }

        guard let source = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: time),
              let earlier = VTFrameProcessorFrame(buffer: before.buffer, presentationTimeStamp: before.time)
        else { throw Fault.noFrame }
        let span = CMTimeGetSeconds(time) - CMTimeGetSeconds(before.time)
        var destinations: [VTFrameProcessorFrame] = []
        for phase in phases {
            let at = CMTime(seconds: CMTimeGetSeconds(before.time) + span * Double(phase), preferredTimescale: time.timescale)
            guard let target = VTFrameProcessorFrame(buffer: try Self.buffer(destinationPool), presentationTimeStamp: at)
            else { throw Fault.noFrame }
            destinations.append(target)
        }
        guard let parameters = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: source, previousFrame: earlier, interpolationPhase: phases, destinationFrames: destinations)
        else { throw Fault.noParameters }

        var out: [CVPixelBuffer] = []
        do {
            for try await result in processor.process(parameters: parameters) {
                let copy = try Self.buffer(destinationPool)
                let status = result.frame.withUnsafeBuffer { pixels -> OSStatus in
                    guard let transfer else { return -1 }
                    return VTPixelTransferSessionTransferImage(transfer, from: pixels, to: copy)
                }
                guard status == noErr else { throw Fault.transferFailed }
                out.append(copy)
            }
        } catch let error as NSError where error.domain == "com.apple.VideoProcessing" && error.code == -12911 {
            // the model is still loading: show the game's frame alone, and give up on this size after a while
            if firstTry == nil { firstTry = Date() }
            if let firstTry, Date().timeIntervalSince(firstTry) > Self.modelLoadTimeout { failed = true }
            return []
        }
        if !out.isEmpty { ready = true }
        return out
    }

    /// The frame as the model takes it: its size and format, converted when the capture gave something else.
    private func compatible(_ frame: CVPixelBuffer) throws -> CVPixelBuffer {
        let same = CVPixelBufferGetWidth(frame) == Int(size.width) && CVPixelBufferGetHeight(frame) == Int(size.height) &&
            CVPixelBufferGetPixelFormatType(frame) == sourcePixelFormat
        guard !same, let transfer else { return frame }
        let converted = try Self.buffer(sourcePool)
        guard VTPixelTransferSessionTransferImage(transfer, from: frame, to: converted) == noErr else { throw Fault.transferFailed }
        return converted
    }

    private static func pool(_ attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as NSDictionary,
                                             attributes as NSDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw Fault.noPool }
        return pool
    }

    private static func buffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer
        else { throw Fault.noBuffer }
        return buffer
    }
}

/// The model's limits on this Mac (macOS 27 says them; on macOS 26 they are found by trying, and nil here).
func frameGenerationLimits() -> (maxSide: Int?, maxPixels: Int?) {
    if #available(macOS 27.0, *) {
        return (VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1),
                VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1))
    }
    return (nil, nil)
}

/// Apple's frame interpolation runs here: macOS 26 or later, on a chip that has the model.
func frameGenerationSupported() -> Bool {
    if #available(macOS 26.0, *) { return VTLowLatencyFrameInterpolationConfiguration.isSupported }
    return false
}
