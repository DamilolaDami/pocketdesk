/// Video payload format: a sequence of HEVC NAL units, each prefixed with its length as a
/// 4-byte big-endian integer (the HVCC layout VideoToolbox produces). Keyframes carry the
/// VPS, SPS and PPS first and set `VideoFrameHeader.Flags.parameterSets`.
public enum NALUnits {
    public static let lengthPrefixSize = 4

    /// HEVC NAL unit types we care about (ITU-T H.265 table 7-1).
    public enum HEVCType: UInt8, Sendable {
        case vps = 32, sps = 33, pps = 34
    }

    public static func append(_ nal: some Collection<UInt8>, to bytes: inout [UInt8]) {
        let length = UInt32(nal.count)
        bytes.append(UInt8(truncatingIfNeeded: length >> 24))
        bytes.append(UInt8(truncatingIfNeeded: length >> 16))
        bytes.append(UInt8(truncatingIfNeeded: length >> 8))
        bytes.append(UInt8(truncatingIfNeeded: length))
        bytes.append(contentsOf: nal)
    }

    /// Splits a payload into its NAL units (without length prefixes).
    public static func split(_ bytes: [UInt8]) throws(WireError) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var index = 0
        while index < bytes.count {
            guard bytes.count - index >= lengthPrefixSize else { throw .truncated }
            let length = Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            index += lengthPrefixSize
            guard length > 0, bytes.count - index >= length else { throw .truncated }
            units.append(bytes[index..<index + length])
            index += length
        }
        return units
    }

    /// The `nal_unit_type` from an HEVC NAL header.
    public static func hevcType(of nal: some Collection<UInt8>) -> UInt8? {
        nal.first.map { ($0 >> 1) & 0x3F }
    }
}
