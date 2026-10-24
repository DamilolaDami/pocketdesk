import Foundation
import Network
import PDProtocol
import PDSecurity

/// Adapts the phone's ordinary QUIC client to a token-bound relay UDP allocation.
/// Both outer control connection and loopback sockets end when the session body ends.
public enum RelayPhonePath {
    public static func connect(
        server: RelayServer, identity: DeviceIdentity, host: Fingerprint,
        serverPin: Fingerprint? = nil,
        _ body: @escaping @Sendable (NWEndpoint) async throws -> Void
    ) async throws {
        try await RelayConnection.withConnection(server: server, identity: identity, serverPin: serverPin) { relay in
            let allocation = try await allocate(relay: relay, host: host)
            let (id, port, token) = (allocation.session, allocation.port, allocation.token)
            let socket = try RelayLoopbackSocket()
            defer { socket.close() }
            try await withNetworkConnection(
                to: .hostPort(host: relay.remoteHost, port: .init(rawValue: port)!), using: { UDP() }
            ) { udp in
                let peer = PhonePort()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await packet in socket.packets {
                            guard await peer.accept(packet.port) else { continue }
                            try await udp.send(token + packet.data)
                        }
                    }
                    group.addTask {
                        for try await packet in udp.messages {
                            let data = packet.content
                            guard data.count > 16, data.count <= RelayPacket.maximumPayload + 16,
                                data.prefix(16) == token, let port = await peer.port
                            else { continue }
                            try socket.send(Data(data.dropFirst(16)), to: port)
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
    }
    private struct Allocation: Sendable {
        let session: UUID
        let port: UInt16
        let token: Data
    }
    private static func allocate(relay: RelayConnection, host: Fingerprint) async throws -> Allocation {
        try await withThrowingTaskGroup(of: Allocation.self) { group in
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
                    case .forward(let id, let port, let text):
                        guard id == session, port != 0, let token = RelayPacket.token(text) else {
                            throw RelayError.invalidResponse
                        }
                        return Allocation(session: id, port: port, token: token)
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
