import Foundation
import Network
import PDProtocol
import PDSecurity
import PDTransport
import Synchronization

public enum ConnectionPath: String, Sendable, Equatable { case local, relay }

/// Try the discovered LAN endpoint first. Fall back only before a session starts; a failed
/// live session must not silently replay its hello, actions, or consumed input streams.
public enum PathFinder {
    public static func connect(
        local: NWEndpoint?, relay: RelayServer?, identity: DeviceIdentity,
        host: Fingerprint, serverPin: Fingerprint? = nil, onPath: @escaping @Sendable (ConnectionPath) -> Void,
        _ body: @escaping @Sendable (QUICPeerSession) async throws -> Void
    ) async throws {
        let started = PathStarted()
        if let local {
            do {
                try await QUICClient.connect(
                    to: local, identity: identity, host: host,
                    timeout: relay == nil ? .seconds(10) : .seconds(2)
                ) { session in
                    started.value.withLock { $0 = true }
                    onPath(.local)
                    try await body(session)
                }
                return
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard relay != nil, !started.value.withLock({ $0 }) else { throw error }
            }
        }
        try Task.checkCancellation()
        guard let relay else { throw TransportError.timedOut }
        try await RelayPhonePath.connect(server: relay, identity: identity, host: host, serverPin: serverPin) {
            endpoint in
            try await QUICClient.connect(to: endpoint, identity: identity, host: host, maxUDPPayloadSize: 1200) { session in
                onPath(.relay)
                try await body(session)
            }
        }
    }
}
private final class PathStarted: Sendable { let value = Mutex(false) }
