#if os(macOS)
import CoreMedia
import CoreVideo
import PDProtocol
import VideoToolbox

/// One encoded access unit, ready for the wire (see `NALUnits` for the payload layout).
public struct EncodedFrame: Sendable {
    public var payload: [UInt8]
    public var isKeyframe: Bool
    public var presentationTimeMicros: UInt64
}

/// Hardware HEVC encoder tuned for interactive screen streaming: real-time, no frame
/// reordering (B-frames would add latency), low-latency rate control, keyframes on demand.
///
/// `@unchecked Sendable`: VideoToolbox sessions are thread-safe for `encode` calls, and the
/// only mutable state (`forceNextKeyframe`) is behind a lock. Outputs arrive on
/// VideoToolbox's thread and are handed to `frames`.
public final class HEVCEncoder: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let frames: AsyncStream<EncodedFrame>

    private let session: VTCompressionSession
    private let continuation: AsyncStream<EncodedFrame>.Continuation
    private let keyframeLock = NSLock()
    private var forceNextKeyframe = true

    public init(width: Int, height: Int, fps: Int, bitrateKbps: Int) throws(EncoderError) {
        self.width = width
        self.height = height
        // Unbounded on purpose: dropping here could drop a keyframe. Backlog is bounded
        // upstream, where `HostSession` drops frames before they reach the encoder.
        (frames, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)

        var created: VTCompressionSession?
        // Low-latency rate control first; fall back if this Mac's encoder doesn't offer it for HEVC.
        for lowLatency in [true, false] {
            var specification: [CFString: Any] = [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            ]
            if lowLatency { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            let status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_HEVC, encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if status == noErr { break }
            if !lowLatency { throw .sessionCreation(status) }
        }
        session = created!

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrateKbps * 1_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            // Keyframes come on request; this is only a safety net for a lost one.
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 60,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            // Tag the stream so the phone converts YCbCr → RGB with the same matrix the capture used.
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            // Not every key is supported by every encoder; unsupported ones are optional tuning.
            _ = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        let status = VTCompressionSessionPrepareToEncodeFrames(session)
        guard status == noErr else { throw .sessionCreation(status) }
    }

    deinit {
        VTCompressionSessionInvalidate(session)
        continuation.finish()
    }

    /// The next frame will be a keyframe (after loss, a new viewer, or a source change).
    public func requestKeyframe() {
        keyframeLock.withLock { forceNextKeyframe = true }
    }

    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let forceKeyframe = keyframeLock.withLock {
            defer { forceNextKeyframe = false }
            return forceNextKeyframe
        }
        let frameProperties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let continuation = continuation
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let frame = Self.package(sampleBuffer) else { return }
            continuation.yield(frame)
        }
    }

    /// Blocks until every submitted frame has been emitted. For tests and shutdown.
    public func flush() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
    }

    private static func package(_ sampleBuffer: CMSampleBuffer) -> EncodedFrame? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var payload: [UInt8] = []
        payload.reserveCapacity(CMBlockBufferGetDataLength(dataBuffer) + (isKeyframe ? 256 : 0))
        if isKeyframe {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if let pointer { NALUnits.append(UnsafeBufferPointer(start: pointer, count: size), to: &payload) }
            }
        }

        // The slice data is already 4-byte length-prefixed (HVCC), so it's appended as-is.
        let sliceStart = payload.count
        let sliceLength = CMBlockBufferGetDataLength(dataBuffer)
        payload.append(contentsOf: repeatElement(0, count: sliceLength))
        let copied = payload.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: sliceLength,
                                       destination: raw.baseAddress! + sliceStart)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = pts.isValid ? UInt64(max(0, pts.seconds * 1_000_000)) : 0
        return EncodedFrame(payload: payload, isKeyframe: isKeyframe, presentationTimeMicros: micros)
    }
}

public enum EncoderError: Error, Sendable {
    case sessionCreation(OSStatus)
}
#endif
