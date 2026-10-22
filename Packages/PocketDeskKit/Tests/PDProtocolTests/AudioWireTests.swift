import Testing
@testable import PDProtocol

struct AudioWireTests {
    @Test func audioHeaderRoundTripsAndRejectsTruncation() throws {
        let header = AudioFrameHeader(captureTimeMicros: 123456789, sourceGeneration: 42, payloadLength: 512)
        var bytes: [UInt8] = []
        header.encode(into: &bytes)
        #expect(bytes.count == AudioFrameHeader.encodedSize)
        #expect(try AudioFrameHeader(decoding: bytes) == header)
        for length in 0..<bytes.count {
            #expect(throws: WireError.truncated) { try AudioFrameHeader(decoding: bytes.prefix(length)) }
        }
    }

    @Test(arguments: [UInt32(0), 8193, UInt32.max])
    func rejectsInvalidPacketLengths(_ length: UInt32) {
        var bytes: [UInt8] = []
        AudioFrameHeader(captureTimeMicros: 1, sourceGeneration: 1, payloadLength: length).encode(into: &bytes)
        #expect(throws: WireError.invalidValue) { try AudioFrameHeader(decoding: bytes) }
    }
}
