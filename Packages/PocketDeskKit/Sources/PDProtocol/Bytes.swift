public enum WireError: Error, Sendable, Equatable {
    case truncated
    case unknownTag
    case invalidValue
}

extension [UInt8] {
    @inline(__always)
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

struct ByteReader<C: Collection<UInt8>> {
    private let bytes: C
    private var index: C.Index

    init(_ bytes: C) {
        self.bytes = bytes
        self.index = bytes.startIndex
    }

    mutating func u8() throws(WireError) -> UInt8 {
        guard index != bytes.endIndex else { throw .truncated }
        defer { index = bytes.index(after: index) }
        return bytes[index]
    }

    mutating func u16() throws(WireError) -> UInt16 { try integer() }
    mutating func u32() throws(WireError) -> UInt32 { try integer() }
    mutating func u64() throws(WireError) -> UInt64 { try integer() }

    private mutating func integer<T: FixedWidthInteger>() throws(WireError) -> T {
        var value: T = 0
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            value |= T(try u8()) << shift
        }
        return value
    }
}
