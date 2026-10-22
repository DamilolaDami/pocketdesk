#if os(macOS)
import AVFoundation
import Testing
import PDProtocol
@testable import PDClientCore
@testable import PDHostCore

struct AudioTests {
    @Test func capturedPCMEncodesAndDecodesWithSampleAccurateTimestamps() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let encoder = try AACEncoder()
        var encoded: [(UInt64, [UInt8])] = []
        // Realistic 10 ms ScreenCaptureKit callbacks, with a nonzero capture clock.
        for chunk in 0..<100 {
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            pcm.frameLength = 480
            for channel in 0..<2 {
                for i in 0..<480 {
                    pcm.floatChannelData![channel][i] = sin(Float(chunk * 480 + i) * 2 * .pi * 440 / 48_000) * 0.5
                }
            }
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: Int64(480_000 + chunk * 480), timescale: 48_000), decodeTimeStamp: .invalid)
            #expect(CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: format.formatDescription, sampleCount: 480,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                sampleSizeArray: nil, sampleBufferOut: &sample) == noErr)
            let captured = try #require(sample)
            #expect(CMSampleBufferSetDataBufferFromAudioBufferList(captured, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList) == noErr)
            encoded += try encoder.encode(captured)
        }
        #expect(encoded.count >= 44)
        let decoder = try #require(AVAudioConverter(from: AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2])!, to: format))
        var decodedFrames = 0
        var firstAudible: Int?
        for (index, packet) in encoded.enumerated() {
            let expected = 10_000_000 - UInt64(encoder.primingFrames) * 1_000_000 / 48_000 + UInt64(index * 1024 * 1_000_000 / 48_000)
            #expect(abs(Int64(packet.0) - Int64(expected)) <= 1)
            let header = AudioFrameHeader(captureTimeMicros: packet.0, sourceGeneration: 1, payloadLength: UInt32(packet.1.count))
            let sample = try AudioAssembler.assemble(header: header, payload: packet.1)
            #expect(sample.numSamples == 1024)
            #expect(abs(sample.presentationTimeStamp.seconds - Double(packet.0) / 1_000_000) < 0.000001)
            let input = AVAudioCompressedBuffer(format: decoder.inputFormat, packetCapacity: 1, maximumPacketSize: packet.1.count)
            packet.1.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.1.count) }
            input.packetCount = 1
            input.byteLength = UInt32(packet.1.count)
            input.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 1024,
                                                                        mDataByteSize: UInt32(packet.1.count))
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048)!
            let source = ConverterInput(input)
            var error: NSError?
            let status = decoder.convert(to: output, error: &error) { _, state in
                source.take(state)
            }
            #expect(error == nil)
            #expect(status != .error)
            for i in 0..<Int(output.frameLength) where firstAudible == nil {
                if abs(output.floatChannelData![0][i]) > 0.05 { firstAudible = decodedFrames + i }
            }
            decodedFrames += Int(output.frameLength)
        }
        // Check content alignment too: correct packet spacing alone hides AAC's delay.
        let audible = try #require(firstAudible)
        let firstTimestamp = try #require(encoded.first?.0)
        let audibleTime = Double(firstTimestamp) / 1_000_000 + Double(audible) / 48_000
        #expect(abs(audibleTime - 10) < 0.001)
        #expect(decodedFrames > 40_000)
    }

    @Test func oldConnectionCannotFlushOrFeedReplacementPlayback() throws {
        let display = VideoDisplay()
        let old = display.beginSession(audioEnabled: true)
        let current = display.beginSession(audioEnabled: true)
        display.endSession(old)
        let header = AudioFrameHeader(captureTimeMicros: 1, sourceGeneration: 1, payloadLength: 20)
        // Stale media is ignored before assembly. Current media still reaches validation.
        try display.enqueueAudio(header: header, payload: [1], sessionID: old)
        #expect(throws: WireError.invalidValue) {
            try display.enqueueAudio(header: header, payload: [1], sessionID: current)
        }
        display.endSession(current)
        try display.enqueueAudio(header: header, payload: [1], sessionID: current)
    }

    @Test func rejectsMalformedAudioPayload() {
        let header = AudioFrameHeader(captureTimeMicros: 1, sourceGeneration: 1, payloadLength: 20)
        #expect(throws: WireError.invalidValue) { try AudioAssembler.assemble(header: header, payload: [1]) }
    }
}
#endif
