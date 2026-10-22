/// Raw AAC-LC access unit: 48 kHz, stereo, 1024 samples per packet.
/// All timestamps use the same host monotonic clock as video.
/// Layout (little endian): captureTimeMicros u64 | generation u32 | payloadLength u32.
public struct AudioFrameHeader: Sendable, Equatable {
    public static let encodedSize = 16
    public static let sampleRate = 48_000
    public static let channels = 2
    public static let samplesPerPacket = 1024
    public static let maxPayloadLength = 8192
    public var captureTimeMicros: UInt64
    public var sourceGeneration: UInt32
    public var payloadLength: UInt32

    public init(captureTimeMicros: UInt64, sourceGeneration: UInt32, payloadLength: UInt32) {
        self.captureTimeMicros = captureTimeMicros
        self.sourceGeneration = sourceGeneration
        self.payloadLength = payloadLength
    }

    public func encode(into bytes: inout [UInt8]) {
        bytes.appendLE(captureTimeMicros)
        bytes.appendLE(sourceGeneration)
        bytes.appendLE(payloadLength)
    }

    public init(decoding bytes: some Collection<UInt8>) throws(WireError) {
        var reader = ByteReader(bytes)
        captureTimeMicros = try reader.u64()
        sourceGeneration = try reader.u32()
        payloadLength = try reader.u32()
        guard payloadLength > 0, payloadLength <= Self.maxPayloadLength,
              captureTimeMicros <= UInt64(Int64.max) else { throw .invalidValue }
    }
}
