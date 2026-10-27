/// Wrapping source-generation ordering. A connection never has 2^31 outstanding changes.
public enum SourceGeneration {
    public static func isNewer(_ candidate: UInt32, than current: UInt32) -> Bool {
        Int32(bitPattern: candidate &- current) > 0
    }
}

/// Input becomes eligible only after this configuration's first decoded keyframe.
public struct SourceInputEpoch: Sendable {
    public private(set) var generation: UInt32?
    public private(set) var ready = false
    public init() {}
    @discardableResult public mutating func configure(_ value: UInt32) -> Bool {
        if let generation {
            guard SourceGeneration.isNewer(value, than: generation) else { return false }
        }
        generation = value; ready = false
        return true
    }
    public mutating func decodedKeyframe(_ value: UInt32) -> Bool {
        guard generation == value, !ready else { return false }
        ready = true
        return true
    }
    public func accepts(_ value: UInt32) -> Bool { ready && generation == value }
}
