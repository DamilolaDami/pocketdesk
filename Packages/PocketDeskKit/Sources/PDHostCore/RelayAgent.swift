#if os(macOS)
    import Foundation
    import OSLog
    import PDProtocol
    import PDSecurity
    import PDTransport

    public enum HostRelayStatus: Sendable, Equatable {
        case disabled, connecting, ready, unavailable
        public var text: String {
            switch self {
            case .disabled: "Off"
            case .connecting: "Connecting to relay…"
            case .ready: "Ready for remote connections"
            case .unavailable: "Relay unavailable · retrying"
            }
        }
    }

    /// Registration belongs to the host service, not a view. Each run owns its shims and tears
    /// them down on disconnect, settings changes or cancellation. Re-registers after network loss.
    public actor RelayAgent {
        private let identity: DeviceIdentity
        private let hostID: UUID
        private let port: UInt16
        private let server: RelayServer
        private let serverPin: Fingerprint?
        private let onStatus: @Sendable (HostRelayStatus) -> Void
        private var peers: [String]
        private var updates: AsyncStream<[String]>.Continuation?
        private var shims: [UUID: (socket: RelayLoopbackSocket, task: Task<Void, Never>)] = [:]
        private var incoming: [UUID: String] = [:]
        /// The relay connection while there is one, for pushes.
        private var current: RelayConnection?
        /// Pushes waiting for the relay's `pushed`.
        private var pushReplies: [UUID: CheckedContinuation<Void, any Error>] = [:]

        public init(
            identity: DeviceIdentity, hostID: UUID, port: UInt16, server: RelayServer,
            peers: [Fingerprint], serverPin: Fingerprint? = nil, onStatus: @escaping @Sendable (HostRelayStatus) -> Void
        ) {
            self.serverPin = serverPin
            self.identity = identity
            self.hostID = hostID
            self.port = port
            self.server = server
            self.peers = peers.map(Self.hex)
            self.onStatus = onStatus
        }
        public func update(peers: [Fingerprint]) {
            self.peers = peers.map(Self.hex)
            // Cut off locally first; relay acknowledgement is not required for revocation.
            for (id, phone) in incoming where !self.peers.contains(phone) { close(id) }
            updates?.yield(self.peers)
        }
        public func run() async {
            defer { clear() }
            while !Task.isCancelled {
                onStatus(.connecting)
                do {
                    try await RelayConnection.withConnection(server: server, identity: identity, serverPin: serverPin) {
                        relay in
                        try await self.connected(relay)
                    }
                } catch {
                    Self.log.error("Relay connection ended: \(String(describing: error), privacy: .public)")
                }
                clear()
                guard !Task.isCancelled else { return }
                onStatus(.unavailable)
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        private static let log = Logger(subsystem: "com.pocketdesk.host", category: "push")

        private func connected(_ relay: RelayConnection) async throws {
            try await relay.send(.register(hostID: hostID))
            current = relay
            defer {
                current = nil
                for id in Array(pushReplies.keys) { finishPush(id, .failure(LiveActivityPushError.relayUnavailable)) }
            }
            // One serialized publisher prevents a stale allow list overtaking a newer one.
            let updates = AsyncStream<[String]>.makeStream(bufferingPolicy: .bufferingNewest(1))
            self.updates = updates.continuation
            updates.continuation.yield(peers)
            defer {
                self.updates = nil
                updates.continuation.finish()
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await peers in updates.stream { try await relay.send(.allow(fingerprints: peers)) }
                }
                group.addTask { try await self.control(relay) }
                group.addTask { try await self.forward(relay) }
                defer { group.cancelAll() }
                try await group.next()
            }
        }
        private func control(_ relay: RelayConnection) async throws {
            var acknowledgements = 0
            for try await message in relay.messages {
                switch message {
                case .pong:
                    acknowledgements += 1
                    if acknowledgements >= 2 { onStatus(.ready) }
                    if acknowledgements == 2 { Self.log.info("Relay ready") }
                case .incoming(let phone, let session):
                    guard peers.contains(phone), incoming.count < 2 else {
                        try await relay.send(.close(session: session))
                        continue
                    }
                    incoming[session] = phone
                case .forward(let session):
                    guard incoming[session].map(peers.contains) == true, shims[session] == nil else {
                        try await relay.send(.close(session: session))
                        continue
                    }
                    let socket = try RelayLoopbackSocket()
                    let listenerPort = port
                    let task = Task {
                        let sender = OrderedDatagramSender(relay.datagrams)
                        do {
                            sending: for try await packet in socket.packets where packet.port == listenerPort {
                                for fragment in RelayPacket.fragments(session: session, payload: packet.data) {
                                    guard sender.send(fragment) else { break sending }
                                }
                            }
                        } catch {}
                        try? await relay.send(.close(session: session))
                    }
                    shims[session] = (socket, task)
                case .close(let session): close(session)
                case .pushed(let id, let status, let reason):
                    finishPush(id, status == 200 ? .success(()) : .failure(LiveActivityPushError.refused(status: status, reason: reason)))
                case .error(let reason): throw RelayError.server(reason)
                default: throw RelayError.invalidResponse
                }
            }
            throw RelayError.closed
        }
        private func forward(_ relay: RelayConnection) async throws {
            var assembler = RelayPacketAssembler()
            for try await fragment in relay.datagrams.messages {
                guard let packet = assembler.receive(fragment.content), let shim = shims[packet.session] else {
                    continue
                }
                try shim.socket.send(packet.payload, to: port)
            }
            throw RelayError.closed
        }
        private func close(_ id: UUID) {
            shims[id]?.socket.close()
            shims[id]?.task.cancel()
            shims[id] = nil
            incoming[id] = nil
        }
        private func clear() { for id in Array(incoming.keys) { close(id) } }
        private func finishPush(_ id: UUID, _ result: Result<Void, any Error>) {
            pushReplies.removeValue(forKey: id)?.resume(with: result)
        }
        private static func hex(_ fp: Fingerprint) -> String { fp.bytes.map { String(format: "%02x", $0) }.joined() }
    }

    /// The relay sends Now Playing pushes to Apple for this Mac, since only it holds the key.
    extension RelayAgent: LiveActivityPushSender {
        public func send(_ push: LiveActivityPush) async throws {
            guard let relay = current else { throw LiveActivityPushError.relayUnavailable }
            let id = UUID()
            let message = RelayMessage.push(id: id, phone: Self.hex(push.phone), token: push.token,
                                            environment: push.environment.rawValue, topic: push.topic,
                                            payload: String(decoding: push.payload, as: UTF8.self))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Waiting before sending, so a quick answer can't arrive first.
                pushReplies[id] = continuation
                Task {
                    do { try await relay.send(message) } catch { finishPush(id, .failure(error)) }
                    try? await Task.sleep(for: .seconds(15))
                    finishPush(id, .failure(LiveActivityPushError.relayUnavailable))
                }
            }
        }
    }
#endif
