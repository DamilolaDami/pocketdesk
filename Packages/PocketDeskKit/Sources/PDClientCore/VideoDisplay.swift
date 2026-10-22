import AVFoundation
import Foundation
import PDProtocol

/// Feeds decoded-on-the-GPU video into whichever `AVSampleBufferDisplayLayer` the stream view
/// has attached. Frames go transport → here → layer directly, never through the store.
///
/// `@unchecked Sendable`: called from the connection's video task and from the main thread
/// (attach); all state is behind `lock`. The renderer itself accepts enqueues from any thread.
public final class VideoDisplay: @unchecked Sendable {
    private let lock = NSLock()
    private var layer: AVSampleBufferDisplayLayer?
    private var assembler = FrameAssembler()
    private var keyframeRequested = false

    public init() {}

    /// The stream view's layer, or `nil` when it goes away. A new layer needs a keyframe.
    public func attach(_ layer: AVSampleBufferDisplayLayer?) {
        lock.withLock {
            self.layer = layer
            assembler.requireKeyframe()
            keyframeRequested = false
        }
    }

    /// Decodes and shows one frame. Returns `true` when the host should be asked for a
    /// keyframe (once per gap, not once per dropped frame).
    public func enqueue(header: VideoFrameHeader, payload: [UInt8]) -> Bool {
        lock.withLock {
            guard let renderer = layer?.sampleBufferRenderer else {
                assembler.requireKeyframe()
                return false
            }
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush()
                assembler.requireKeyframe()
            }
            do {
                if let sample = try assembler.assemble(header: header, payload: payload) {
                    renderer.enqueue(sample)
                    if header.flags.contains(.keyframe) { keyframeRequested = false }
                    return false
                }
            } catch {
                assembler.requireKeyframe()
            }
            guard assembler.needsKeyframe, !keyframeRequested else { return false }
            keyframeRequested = true
            return true
        }
    }
}
