import Dispatch
import Foundation
import Network
import Synchronization

/// Sends datagrams (QUIC datagrams or UDP) in order without waiting for each one.
///
/// Network.framework's async `send` on a QUIC datagram flow can take about a round trip to
/// return, so awaiting each datagram before the next would allow only about one per round trip
/// on a relayed session. Here every send runs as its own task
/// on one serial queue: the tasks start in the order they were queued, each runs until its first
/// suspension (after the datagram is handed to the connection), and they finish in parallel.
/// Order matters because the relay reassembles a fragmented packet from consecutive pieces.
///
/// At most `window` sends are outstanding. Past that a datagram is dropped, as UDP would drop
/// it: the encrypted session inside retransmits and slows down.

public final class OrderedDatagramSender<Protocol: DatagramProtocol>: Sendable {
    private let channel: NetworkChannel<Protocol>
    private let queue = DispatchQueue(label: "pocketdesk.relay.datagrams")
    private let window: Int
    private let state = Mutex(State())

    private struct State {
        var inFlight = 0
        var failed = false
    }

    /// The default keeps the queue short: 64 full packets is about half a second at 1 Mbps.
    /// A longer queue only adds delay, which the session inside reads as congestion.
    public init(_ channel: NetworkChannel<Protocol>, window: Int = 64) {
        self.channel = channel
        self.window = window
    }

    /// Queues `data` for sending. Returns false once a send has failed, which means the
    /// connection is gone; the caller should stop.
    @discardableResult
    public func send(_ data: Data) -> Bool {
        let accepted: Bool? = state.withLock { state in
            if state.failed { return nil }
            guard state.inFlight < window else { return false }
            state.inFlight += 1
            return true
        }
        guard let accepted else { return false }
        guard accepted else { return true }
        Task(executorPreference: queue) { [self] in
            do {
                try await channel.send(data)
                state.withLock { $0.inFlight -= 1 }
            } catch {
                state.withLock { state in
                    state.inFlight -= 1
                    state.failed = true
                }
            }
        }
        return true
    }
}
