import AVFoundation
import PDProtocol

/// Reconstitutes one raw AAC-LC access unit for the system audio renderer.
public enum AudioAssembler {
    public static func assemble(header: AudioFrameHeader, payload: [UInt8]) throws -> CMSampleBuffer {
        guard payload.count == Int(header.payloadLength), !payload.isEmpty,
              payload.count <= AudioFrameHeader.maxPayloadLength,
              header.captureTimeMicros <= UInt64(Int64.max) else { throw WireError.invalidValue }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 2 /* MPEG-4 Audio Object Type: AAC-LC */, mBytesPerPacket: 0, mFramesPerPacket: 1024,
            mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var format: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard formatStatus == noErr, let format else { throw AssemblyError.formatDescription(formatStatus) }
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: payload.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw AssemblyError.sampleBuffer(status) }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == noErr else { throw AssemblyError.sampleBuffer(copied) }
        var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 1024,
                                                       mDataByteSize: UInt32(payload.count))
        var sample: CMSampleBuffer?
        let created = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block,
            formatDescription: format, sampleCount: 1024,
            presentationTimeStamp: CMTime(value: Int64(header.captureTimeMicros), timescale: 1_000_000),
            packetDescriptions: &description, sampleBufferOut: &sample)
        guard created == noErr, let sample else { throw AssemblyError.sampleBuffer(created) }
        return sample
    }
}
