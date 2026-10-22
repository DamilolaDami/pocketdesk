#if os(macOS)
import AVFoundation
import CoreMedia
import PDProtocol

/// Confined to ScreenCaptureKit's serial sample queue. The converter retains partial PCM
/// between callbacks; packet timestamps advance by sample count rather than callback time.
final class AACEncoder {
    private let converter: AVAudioConverter
    private var nextTime: CMTime?
    private var needsPrimingCorrection = true
    var primingFrames: UInt32 { converter.primeInfo.leadingFrames }
    private var expectedInputTime: CMTime?

    init() throws {
        let input = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                             AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                                             AVEncoderBitRateKey: 128_000])!
        guard let converter = AVAudioConverter(from: input, to: output) else { throw CaptureError.audioEncoding }
        converter.primeMethod = .none
        self.converter = converter
    }

    func encode(_ sample: CMSampleBuffer) throws -> [(UInt64, [UInt8])] {
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0 else { return [] }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.isNumeric, time.seconds >= 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(count))
        else { throw CaptureError.audioEncoding }
        pcm.frameLength = AVAudioFrameCount(count)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: pcm.mutableAudioBufferList)
        guard status == noErr else { throw CaptureError.audioEncoding }
        if let expectedInputTime, abs(CMTimeSubtract(time, expectedInputTime).seconds) > 0.02 {
            converter.reset()
            nextTime = nil
            needsPrimingCorrection = true
        }
        expectedInputTime = CMTimeAdd(time, CMTime(value: Int64(count), timescale: 48_000))
        if nextTime == nil { nextTime = time }
        let input = ConverterInput(pcm)
        var packets: [(UInt64, [UInt8])] = []
        while true {
            let output = AVAudioCompressedBuffer(format: converter.outputFormat, packetCapacity: 8,
                                                 maximumPacketSize: converter.maximumOutputPacketSize)
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, state in
                input.take(state)
            }
            if let error { throw error }
            guard result != .error else { throw CaptureError.audioEncoding }
            if let descriptions = output.packetDescriptions {
                for index in 0..<Int(output.packetCount) {
                    let packet = descriptions[index]
                    let bytes = output.data.advanced(by: Int(packet.mStartOffset)).assumingMemoryBound(to: UInt8.self)
                    if needsPrimingCorrection {
                        // AAC-LC inserts leading decoded silence (2112 frames with Apple's
                        // encoder). Date that silence before the captured PCM, so actual
                        // sound aligns with video rather than arriving ~44 ms late.
                        nextTime = CMTimeMaximum(.zero, CMTimeSubtract(nextTime!,
                            CMTime(value: Int64(converter.primeInfo.leadingFrames), timescale: 48_000)))
                        needsPrimingCorrection = false
                    }
                    let timestamp = nextTime!
                    packets.append((UInt64(CMTimeConvertScale(timestamp, timescale: 1_000_000, method: .default).value),
                                    Array(UnsafeBufferPointer(start: bytes, count: Int(packet.mDataByteSize)))))
                    nextTime = CMTimeAdd(timestamp, CMTime(value: 1024, timescale: 48_000))
                }
            }
            if result == .inputRanDry || result == .endOfStream { break }
        }
        return packets
    }
}
/// AVAudioConverter annotates its synchronous input callback as @Sendable. This holder
/// serializes the single handoff, and neither caller writes the buffer after construction.
final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioBuffer?
    init(_ buffer: AVAudioBuffer) { self.buffer = buffer }
    func take(_ state: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.withLock {
            defer { buffer = nil }
            state.pointee = buffer == nil ? .noDataNow : .haveData
            return buffer
        }
    }
}
#endif
