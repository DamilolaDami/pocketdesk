import Foundation
import Network
import PDProtocol
import PDSecurity
import Synchronization

public enum RelayError: Error, Sendable, LocalizedError {
    case notFound, closed, invalidResponse
    case server(String)
    public var errorDescription: String? {
        switch self {
        case .notFound:
            "The Mac isn't available through this relay. Check that it's awake, relay access is on, and this iPhone is paired."
        case .closed: "The relay connection ended."
        case .invalidResponse: "The relay sent an invalid response."
        case .server(let reason): "The relay couldn't open a connection (\(reason))."
        }
    }
}

/// Owns the outer connection for exactly the lifetime of `body`. The default TLS validator
/// checks the relay's system trust and hostname; devices still pin each other inside the shim.
public final class RelayConnection: Sendable {
    public let messages: AsyncThrowingStream<RelayMessage, any Error>
    public let datagrams: QUIC.Datagrams<QUICDatagram>
    public let remoteHost: NWEndpoint.Host
    private let writer: Writer
    private init(
        remoteHost: NWEndpoint.Host, stream: QUIC.Stream<QUICStream>, datagrams: QUIC.Datagrams<QUICDatagram>,
        messages: AsyncThrowingStream<RelayMessage, any Error>
    ) {
        self.remoteHost = remoteHost
        writer = Writer(stream: stream)
        self.datagrams = datagrams
        self.messages = messages
    }
    deinit {
        // Same Network.framework client-stream lifetime workaround as QUICPeerSession.
        Retired.keep(writer)
        Retired.keep(datagrams)
    }
    public func send(_ message: RelayMessage) async throws { try await writer.send(message) }

    public static func withConnection(
        server: RelayServer, identity: DeviceIdentity,
        // Explicit pin for local integration tests/self-hosted callers, never an accept-all validator.
        serverPin: Fingerprint? = nil,
        _ body: @escaping @Sendable (RelayConnection) async throws -> Void
    ) async throws {
        let ready = RelayReady()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                var quic = QUIC(alpn: [RelayMessage.alpn]).idleTimeout(60_000).maxUDPPayloadSize(1200).maxDatagramFrameSize(1200)
                    .tls.localIdentity(identity.secIdentity).tls.peerAuthentication(.required)
                if let serverPin {
                    quic = quic.tls.certificateValidator { _, trust in Fingerprint(trust: trust) == serverPin }
                }
                try await withNetworkConnection(
                    to: .hostPort(host: .init(server.host), port: .init(rawValue: server.port)!), using: { quic }
                ) { connection in
                    let stream = try await connection.openStream()
                    let datagrams = try await connection.datagrams
                    ready.value.withLock { $0 = true }
                    let messages = AsyncThrowingStream<RelayMessage, any Error>.makeStream(
                        bufferingPolicy: .bufferingOldest(32))
                    guard case .hostPort(let remoteHost, _) = connection.remoteEndpoint else {
                        throw RelayError.invalidResponse
                    }
                    let relay = RelayConnection(
                        remoteHost: remoteHost, stream: stream, datagrams: datagrams, messages: messages.stream)
                    defer { messages.continuation.finish() }
                    try await withThrowingTaskGroup(of: Void.self) { tasks in
                        tasks.addTask {
                            while !Task.isCancelled {
                                let header = try await stream.receive(exactly: 4).content
                                let size = header.reduce(0) { $0 << 8 | Int($1) }
                                guard size > 0, size <= RelayMessage.maximumSize else {
                                    throw RelayError.invalidResponse
                                }
                                let body = try await stream.receive(exactly: size).content
                                let message = try JSONDecoder().decode(RelayMessage.self, from: body)
                                ready.lastMessage.withLock { $0 = .now }
                                if case .dropped = messages.continuation.yield(message) {
                                    throw RelayError.invalidResponse
                                }
                            }
                        }
                        tasks.addTask {
                            while !Task.isCancelled {
                                try await Task.sleep(for: .seconds(25))
                                guard ready.lastMessage.withLock({ ContinuousClock.now - $0 < .seconds(60) }) else {
                                    throw TransportError.timedOut
                                }
                                try await relay.send(.ping)
                            }
                        }
                        tasks.addTask { try await body(relay) }
                        defer { tasks.cancelAll() }
                        try await tasks.next()
                    }
                }
                return true
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                if !ready.value.withLock({ $0 }) { throw TransportError.timedOut }
                return false
            }
            defer { group.cancelAll() }
            while let finished = try await group.next(), !finished {}
        }
    }
    /// Verify this device can reach the relay's control service, without touching host registrations.
    public static func check(server: RelayServer, identity: DeviceIdentity,
                             serverPin: Fingerprint? = nil, timeout: Duration = .seconds(8)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withConnection(server: server, identity: identity, serverPin: serverPin) { relay in
                    try await relay.send(.ping)
                    for try await message in relay.messages {
                        guard message == .pong else { throw RelayError.invalidResponse }
                        return
                    }
                    throw RelayError.closed
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TransportError.timedOut
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private actor Writer {
        let stream: QUIC.Stream<QUICStream>
        init(stream: QUIC.Stream<QUICStream>) { self.stream = stream }
        func send(_ message: RelayMessage) async throws { try await stream.send(message.framed()) }
    }
}

private final class RelayReady: Sendable {
    let value = Mutex(false)
    let lastMessage = Mutex(ContinuousClock.now)
}
