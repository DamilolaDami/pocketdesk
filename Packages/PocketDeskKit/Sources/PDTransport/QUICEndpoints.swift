import Foundation
import Network
import PDProtocol
import PDSecurity
import Synchronization

enum QUICOptions {
    /// Shared QUIC settings. Datagrams are opt-in per connection, so both sides set the size.
    ///
    /// Both sides use `.required`: with `.none` the validator is skipped entirely, and a phone
    /// would accept any Mac's certificate.
    static func make(identity: DeviceIdentity, validate: @escaping @Sendable (Fingerprint) async -> Bool) -> QUIC {
        QUIC(alpn: [alpn])
            .idleTimeout(15_000)
            .maxDatagramFrameSize(1_200)
            .tls.localIdentity(identity.secIdentity)
            .tls.peerAuthentication(.required)
            .tls.certificateValidator { _, trust in
                guard let fingerprint = Fingerprint(trust: trust) else { return false }
                return await validate(fingerprint)
            }
    }
}

/// Host side: accepts QUIC sessions, optionally advertised over Bonjour.
public final class QUICHostListener: Sendable {
    public struct Advertisement: Sendable {
        public var name: String
        public var hostID: UUID

        public init(name: String, hostID: UUID) {
            self.name = name
            self.hostID = hostID
        }
    }

    private let listener: NetworkListener<QUIC>

    /// - Parameter authorize: called during each TLS handshake with the phone's certificate
    ///   fingerprint. Return `true` for pinned phones, and for anyone while a pairing invite
    ///   is open (the session must then present the invite token before anything else).
    public init(identity: DeviceIdentity, advertise advertisement: Advertisement?,
                authorize: @escaping @Sendable (Fingerprint) async -> Bool) throws {
        let quic = QUICOptions.make(identity: identity, validate: authorize)
        if let advertisement {
            let txt = NWTXTRecord(["id": advertisement.hostID.uuidString, "v": String(protocolVersion)])
            listener = try NetworkListener(for: .bonjour(name: advertisement.name, type: bonjourServiceType, txtRecord: txt)) { quic }
        } else {
            listener = try NetworkListener { quic }
        }
    }

    /// The bound UDP port, once listening.
    public var port: UInt16? {
        guard let port = listener.port, port.rawValue != 0 else { return nil }
        return port.rawValue
    }

    /// Runs until cancelled. Each session's connection stays open while `handler` runs.
    public func run(_ handler: @escaping @Sendable (QUICPeerSession) async throws -> Void) async throws {
        try await listener.run { connection in
            let session = try await QUICPeerSession.accept(connection)
            do {
                try await handler(session)
            } catch {
                await session.close()
                throw error
            }
            await session.close()
        }
    }
}

/// Client side.
public enum QUICClient {
    /// Connects to a host whose certificate fingerprint we know (from pairing or the QR
    /// invite) and runs `body` with the session. The connection closes when `body` returns
    /// or its task is cancelled.
    ///
    /// Throws if the connection fails or isn't ready within `timeout`. Network.framework
    /// otherwise keeps a rejected handshake (e.g. an impostor host) in `.waiting` forever.
    public static func connect(to endpoint: NWEndpoint, identity: DeviceIdentity, host: Fingerprint,
                               timeout: Duration = .seconds(10),
                               _ body: @escaping @Sendable (QUICPeerSession) async throws -> Void) async throws {
        let quic = QUICOptions.make(identity: identity) { $0 == host }
        try await withNetworkConnection(to: endpoint, using: { quic }) { connection in
            let states = AsyncStream<NetworkChannel<QUIC>.State>.makeStream()
            connection.onStateUpdate { _, state in states.continuation.yield(state) }
            let ready = ReadyFlag()

            // Child results: `true` when `body` finished; watchers never return normally
            // before that, they only throw.
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await state in states.stream {
                        switch state {
                        case .ready: ready.set()
                        case .failed(let error): throw TransportError.connectionFailed(error)
                        case .cancelled: throw TransportError.closed
                        default: break
                        }
                    }
                    return false
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    if !ready.isSet { throw TransportError.timedOut }
                    return false
                }
                group.addTask {
                    let session = try await QUICPeerSession.open(connection, host: host)
                    ready.set()
                    do {
                        try await body(session)
                    } catch {
                        await session.close()
                        throw error
                    }
                    await session.close()
                    return true
                }
                while let bodyFinished = try await group.next(), !bodyFinished {}
                group.cancelAll()
            }
        }
    }
}

private final class ReadyFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .acquiring) }
    func set() { value.store(true, ordering: .releasing) }
}
