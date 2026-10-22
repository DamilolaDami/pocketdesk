/// Header prefixed to every encoded video access unit on the video stream.
///
/// Layout (little-endian, 21 bytes):
/// `frameID u32 | captureTimeMicros u64 | flags u8 | payloadLength u32 | sourceGeneration u32`
public struct VideoFrameHeader: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let keyframe = Flags(rawValue: 1 << 0)
        /// Payload carries parameter sets (VPS/SPS/PPS) before the slice data.
        public static let parameterSets = Flags(rawValue: 1 << 1)
    }

    public static let encodedSize = 4 + 8 + 1 + 4 + 4

    public var frameID: UInt32
    /// Host monotonic clock, used for latency stats on the client.
    public var captureTimeMicros: UInt64
    public var flags: Flags
    public var payloadLength: UInt32
    /// Increments when the source or stream config changes, so the client can drop stale frames.
    public var sourceGeneration: UInt32

    public init(frameID: UInt32, captureTimeMicros: UInt64, flags: Flags, payloadLength: UInt32, sourceGeneration: UInt32) {
        self.frameID = frameID
        self.captureTimeMicros = captureTimeMicros
        self.flags = flags
        self.payloadLength = payloadLength
        self.sourceGeneration = sourceGeneration
    }

    public func encode(into bytes: inout [UInt8]) {
        bytes.appendLE(frameID)
        bytes.appendLE(captureTimeMicros)
        bytes.append(flags.rawValue)
        bytes.appendLE(payloadLength)
        bytes.appendLE(sourceGeneration)
    }

    public init(decoding bytes: some Collection<UInt8>) throws(WireError) {
        var reader = ByteReader(bytes)
        frameID = try reader.u32()
        captureTimeMicros = try reader.u64()
        flags = Flags(rawValue: try reader.u8())
        payloadLength = try reader.u32()
        sourceGeneration = try reader.u32()
    }
}
