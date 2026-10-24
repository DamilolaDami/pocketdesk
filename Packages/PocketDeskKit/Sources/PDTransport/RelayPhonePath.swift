import Foundation
import Network
import PDProtocol
import PDSecurity

/// Adapts the phone's ordinary QUIC client to a relayed session. The inner QUIC packets travel
/// as pieces in datagrams on the phone's relay connection, the same way the Mac's do, so every
/// UDP packet on the public path stays within 1,200 bytes. (Raw UDP with a token in front made
/// full-size packets 1,213 bytes, and about one in five of those was lost.)
/// Both the relay connection and the loopback socket end when the session body ends.
public enum RelayPhonePath {
    public static func connect(
        server: RelayServer, identity: DeviceIdentity, host: Fingerprint,
        serverPin: Fingerprint? = nil,
        _ body: @escaping @Sendable (NWEndpoint) async throws -> Void
    ) async throws {
        try await RelayConnection.withConnection(server: server, identity: identity, serverPin: serverPin) { relay in
            let id = try await allocate(relay: relay, host: host)
            let socket = try RelayLoopbackSocket()
            defer { socket.close() }
            let peer = PhonePort()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let sender = OrderedDatagramSender(relay.datagrams)
                    for try await packet in socket.packets {
                        guard await peer.accept(packet.port) else { continue }
                        for fragment in RelayPacket.fragments(session: id, payload: packet.data) {
                            guard sender.send(fragment) else { throw RelayError.closed }
                        }
                    }
                }
                group.addTask {
                    var assembler = RelayPacketAssembler()
                    for try await fragment in relay.datagrams.messages {
                        guard let packet = assembler.receive(fragment.content), packet.session == id,
                            let port = await peer.port
                        else { continue }
                        try socket.send(packet.payload, to: port)
                    }
                }
                group.addTask {
                    for try await message in relay.messages {
                        switch message {
                        case .close(let session) where session == id: throw RelayError.closed
                        case .error(let reason): throw RelayError.server(reason)
                        case .pong: continue
                        default: throw RelayError.invalidResponse
                        }
                    }
                    throw RelayError.closed
                }
                group.addTask { try await body(.hostPort(host: "127.0.0.1", port: .init(rawValue: socket.port)!)) }
                defer {
                    group.cancelAll()
                    socket.close()
                }
                try await group.next()
            }
        }
    }

    /// Asks the relay for the Mac, then for forwarding. Returns the session ID.
    private static func allocate(relay: RelayConnection, host: Fingerprint) async throws -> UUID {
        try await withThrowingTaskGroup(of: UUID.self) { group in
            group.addTask {
                try await relay.send(.connect(host: host.bytes.map { String(format: "%02x", $0) }.joined()))
                var messages = relay.messages.makeAsyncIterator()
                var session: UUID?
                while let message = try await messages.next() {
                    switch message {
                    case .ready(let id):
                        guard session == nil else { throw RelayError.invalidResponse }
                        session = id
                        try await relay.send(.allocate(session: id))
                    case .forward(let id):
                        guard id == session else { throw RelayError.invalidResponse }
                        return id
                    case .notFound: throw RelayError.notFound
                    case .error(let reason): throw RelayError.server(reason)
                    case .pong: continue
                    default: throw RelayError.invalidResponse
                    }
                }
                throw RelayError.closed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw TransportError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw RelayError.closed }
            return result
        }
    }
}

private actor PhonePort {
    var port: UInt16?
    func accept(_ candidate: UInt16) -> Bool {
        if port == nil { port = candidate }
        return port == candidate
    }
}
