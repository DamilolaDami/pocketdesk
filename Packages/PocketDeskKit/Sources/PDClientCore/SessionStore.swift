import Observation
import PDProtocol

/// The one observable the SwiftUI layer reads. Views call `send(_:)`; side effects
/// (discovery, transport, decode) live in actors that report back through `send` too.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var state: SessionState = .idle
    /// Latest round-trip and decode stats, updated off the hot path at most a few times a second.
    public private(set) var stats = StreamStats()

    public init() {}

    public func send(_ event: SessionEvent) {
        state = state.reduce(event)
    }

    public func update(stats: StreamStats) {
        self.stats = stats
    }
}

public struct StreamStats: Sendable, Equatable {
    public var roundTripMillis: Double = 0
    public var framesPerSecond: Double = 0
    public var bitrateKbps: Double = 0

    public init() {}
}
