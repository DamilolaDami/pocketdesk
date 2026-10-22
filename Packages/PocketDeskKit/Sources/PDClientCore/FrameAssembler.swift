import CoreMedia
import PDProtocol

/// Turns wire frames (`VideoFrameHeader` + length-prefixed HEVC NAL units) into
/// `CMSampleBuffer`s a hardware decoder accepts.
///
/// Keeps the format description from the last keyframe's VPS/SPS/PPS, and drops frames it
/// can't decode: deltas before the first keyframe, and anything from a stale source
/// generation until that generation's keyframe arrives.
public struct FrameAssembler {
    public private(set) var format: CMVideoFormatDescription?
    public private(set) var needsKeyframe = true
    private var generation: UInt32?

    public init() {}

    /// After a decoder failure: decode nothing until the next keyframe.
    public mutating func requireKeyframe() {
        needsKeyframe = true
    }

    /// `nil` means the frame was dropped (see `needsKeyframe`).
    public mutating func assemble(header: VideoFrameHeader, payload: [UInt8], displayImmediately: Bool = true) throws(AssemblyError) -> CMSampleBuffer? {
        if header.sourceGeneration != generation {
            generation = header.sourceGeneration
            needsKeyframe = true
        }
        let isKeyframe = header.flags.contains(.keyframe)
        if needsKeyframe, !isKeyframe { return nil }

        var slices: [UInt8]
        if header.flags.contains(.parameterSets) {
            var parameterSets: [[UInt8]] = []
            slices = []
            slices.reserveCapacity(payload.count)
            let units: [ArraySlice<UInt8>]
            do { units = try NALUnits.split(payload) } catch { throw .malformedPayload }
            for unit in units {
                if let type = NALUnits.hevcType(of: unit), (NALUnits.HEVCType.vps.rawValue...NALUnits.HEVCType.pps.rawValue).contains(type) {
                    parameterSets.append(Array(unit))
                } else {
                    NALUnits.append(unit, to: &slices)
                }
            }
            format = try Self.makeFormat(parameterSets)
        } else {
            slices = payload
        }
        guard let format, !slices.isEmpty else { return nil }

        let sample = try Self.makeSample(slices, format: format,
                                         presentationTime: CMTime(value: CMTimeValue(header.captureTimeMicros), timescale: 1_000_000),
                                         isKeyframe: isKeyframe, displayImmediately: displayImmediately)
        if isKeyframe { needsKeyframe = false }
        return sample
    }

    private static func makeFormat(_ parameterSets: [[UInt8]]) throws(AssemblyError) -> CMVideoFormatDescription {
        guard parameterSets.count >= 3 else { throw .missingParameterSets }
        var description: CMFormatDescription?
        let pointers = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            pointer.initialize(from: set, count: set.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: parameterSets.count,
            parameterSetPointers: pointers.map { UnsafePointer($0) }, parameterSetSizes: parameterSets.map(\.count),
            nalUnitHeaderLength: Int32(NALUnits.lengthPrefixSize), extensions: nil, formatDescriptionOut: &description)
        guard status == noErr, let description else { throw .formatDescription(status) }
        return description
    }

    private static func makeSample(_ bytes: [UInt8], format: CMVideoFormatDescription, presentationTime: CMTime,
                                   isKeyframe: Bool, displayImmediately: Bool) throws(AssemblyError) -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw .sampleBuffer(status) }
        status = bytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == kCMBlockBufferNoErr else { throw .sampleBuffer(status) }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw .sampleBuffer(status) }

        // Video-only sessions display immediately; audio sessions use the shared timebase.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(displayImmediately ? kCFBooleanTrue : kCFBooleanFalse).toOpaque())
            if !isKeyframe {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}

public enum AssemblyError: Error, Sendable, Equatable {
    case malformedPayload
    case missingParameterSets
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}
