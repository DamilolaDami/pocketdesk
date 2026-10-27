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
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private var clockStarted = false
    private var expectedGeneration: UInt32?
    private var decodedGeneration: UInt32?
    private var generation: UInt32?
    private var audioEnabled = true
    private var sessionID: UUID?
    private var requestKeyframe: (@Sendable () -> Void)?

    public init() {
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.addRenderer(audioRenderer)
    }

    /// Called at connection boundaries so old host timestamps and queued sound cannot leak.
    func beginSession(audioEnabled: Bool) -> UUID {
        lock.withLock {
            resetLocked()
            let id = UUID()
            sessionID = id
            self.audioEnabled = audioEnabled
            audioRenderer.isMuted = !audioEnabled
            return id
        }
    }

    func isCurrentSession(_ id: UUID) -> Bool { lock.withLock { sessionID == id } }

    func endSession(_ id: UUID) {
        lock.withLock {
            // A cancelled connection may finish after its replacement has begun.
            guard sessionID == id else { return }
            resetLocked()
            sessionID = nil
        }
    }

    private func resetLocked() {
        audioRenderer.flush()
        layer?.sampleBufferRenderer.flush()
        synchronizer.setRate(0, time: .zero)
        clockStarted = false
        generation = nil
        expectedGeneration = nil
        decodedGeneration = nil
        assembler = FrameAssembler()
        keyframeRequested = false
        requestKeyframe = nil
    }

    func setKeyframeRequester(sessionID: UUID, _ request: @escaping @Sendable () -> Void) {
        let attached = lock.withLock {
            guard self.sessionID == sessionID else { return false }
            requestKeyframe = request
            return layer != nil
        }
        if attached { request() }
    }

    func expectGeneration(_ value: UInt32, sessionID: UUID) {
        lock.withLock {
            guard self.sessionID == sessionID else { return }
            if let expectedGeneration, !SourceGeneration.isNewer(value, than: expectedGeneration) { return }
            expectedGeneration = value; decodedGeneration = nil
            generation = value
            audioRenderer.flush(); layer?.sampleBufferRenderer.flush()
            synchronizer.setRate(0, time: .zero); clockStarted = false
            assembler = FrameAssembler(); keyframeRequested = false
        }
    }

    func hasDecodedGeneration(_ value: UInt32) -> Bool { lock.withLock { decodedGeneration == value } }

    public func setAudioEnabled(_ enabled: Bool) {
        lock.withLock {
            audioEnabled = enabled
            audioRenderer.isMuted = !enabled
            if !enabled { audioRenderer.flush() }
        }
    }

    private func startClock(at time: CMTime) {
        guard !clockStarted || synchronizer.rate == 0 else { return }
        clockStarted = true
        // Anchor remote timestamps to a local start; no wall-clock synchronization needed.
        synchronizer.setRate(1, time: time, atHostTime: CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                                                               CMTime(value: 120, timescale: 1000)))
    }

    public func enqueueAudio(header: AudioFrameHeader, payload: [UInt8], sessionID: UUID? = nil) throws {
        try lock.withLock {
            if let sessionID, self.sessionID != sessionID { return }
            guard expectedGeneration == nil || expectedGeneration == header.sourceGeneration else { return }
            guard audioEnabled, generation == nil || generation == header.sourceGeneration else { return }
            if generation == nil { generation = header.sourceGeneration }
            let sample = try AudioAssembler.assemble(header: header, payload: payload)
            startClock(at: sample.presentationTimeStamp)
            // Never build an unbounded renderer queue after a network stall.
            let lag = CMTimeSubtract(synchronizer.currentTime(), sample.presentationTimeStamp).seconds
            if audioRenderer.status == .failed { audioRenderer.flush() }
            guard lag < 0.05, audioRenderer.isReadyForMoreMediaData else { return }
            audioRenderer.enqueue(sample)
        }
    }

    /// The stream view's layer, or `nil` when it goes away. A new layer needs a keyframe.
    public func attach(_ layer: AVSampleBufferDisplayLayer?) {
        let request: (@Sendable () -> Void)? = lock.withLock {
            guard self.layer !== layer else { return nil }
            if let old = self.layer {
                synchronizer.removeRenderer(old.sampleBufferRenderer, at: .invalid)
            }
            self.layer = layer
            if let layer { synchronizer.addRenderer(layer.sampleBufferRenderer) }
            assembler.requireKeyframe()
            keyframeRequested = false
            return layer == nil ? nil : requestKeyframe
        }
        request?()
    }

    /// Decodes and shows one frame. Returns `true` when the host should be asked for a
    /// keyframe (once per gap, not once per dropped frame).
    public func enqueue(header: VideoFrameHeader, payload: [UInt8], sessionID: UUID? = nil) -> Bool {
        lock.withLock {
            if let sessionID, self.sessionID != sessionID { return false }
            guard expectedGeneration == nil || expectedGeneration == header.sourceGeneration else { return false }
            guard let renderer = layer?.sampleBufferRenderer else {
                assembler.requireKeyframe()
                return false
            }
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush()
                assembler.requireKeyframe()
            }
            do {
                if let sample = try assembler.assemble(header: header, payload: payload, displayImmediately: !audioEnabled) {
                    if generation != header.sourceGeneration {
                        generation = header.sourceGeneration
                        audioRenderer.flush()
                    }
                    if audioEnabled { startClock(at: sample.presentationTimeStamp) }
                    renderer.enqueue(sample)
                    decodedGeneration = header.sourceGeneration
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
