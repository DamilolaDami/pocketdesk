import Foundation
import Network
import PDProtocol
import PDSecurity
import PDTransport

/// What a connection reports to `SessionController`.
public enum ClientEvent: Sendable, Equatable {
    /// Pairing: show this code; the person at the Mac must accept the same one.
    case awaitingApproval(code: String)
    case paired(PairedPeer)
    case streamConfig(StreamConfig)
    case windows([WindowInfo])
    case ended(reason: String?)
}

public enum ClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case pairingDeclined
    case hostEnded(String)
    case unexpectedMessage

    public var description: String {
        switch self {
        case .pairingDeclined: "Pairing was declined on the Mac."
        case .hostEnded(let reason): reason
        case .unexpectedMessage: "The Mac sent something unexpected."
        }
    }
}

/// One connection to a Mac: optional pairing, hello, then video (straight to the display),
/// control messages and input until either side ends it.
public actor ClientConnection {
    public struct Request: Sendable {
        public var endpoint: NWEndpoint
        public var hostFingerprint: Fingerprint
        /// Set when pairing; the token and host fingerprint come from the scanned invite.
        public var invite: PairingInvite?
        public var deviceName: String
        public var viewport: Viewport

        public init(endpoint: NWEndpoint, hostFingerprint: Fingerprint, invite: PairingInvite?,
                    deviceName: String, viewport: Viewport) {
            self.endpoint = endpoint
            self.hostFingerprint = hostFingerprint
            self.invite = invite
            self.deviceName = deviceName
            self.viewport = viewport
        }
    }

    private let identity: DeviceIdentity
    private let request: Request
    private let display: VideoDisplay
    private let onEvent: @Sendable (ClientEvent) -> Void

    /// UI → Mac, in order. Streams (not ad-hoc Tasks) so a button-down never overtakes its
    /// button-up.
    private let inputs = AsyncStream<InputEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
    private let outbox = AsyncStream<ControlMessage>.makeStream()

    public init(identity: DeviceIdentity, request: Request, display: VideoDisplay,
                onEvent: @escaping @Sendable (ClientEvent) -> Void) {
        self.identity = identity
        self.request = request
        self.display = display
        self.onEvent = onEvent
    }

    public nonisolated func send(_ input: InputEvent) {
        inputs.continuation.yield(input)
    }

    public nonisolated func send(_ message: ControlMessage) {
        outbox.continuation.yield(message)
    }

    /// Runs until the connection ends; always finishes with `.ended`.
    public func run() async {
        do {
            try await QUICClient.connect(to: request.endpoint, identity: identity, host: request.hostFingerprint) { session in
                try await self.drive(session)
            }
            onEvent(.ended(reason: nil))
        } catch is CancellationError {
            onEvent(.ended(reason: nil))
        } catch {
            onEvent(.ended(reason: Self.describe(error)))
        }
        inputs.continuation.finish()
        outbox.continuation.finish()
    }

    private func drive(_ session: QUICPeerSession) async throws {
        if let invite = request.invite {
            try await pair(session, invite: invite)
        }
        try await session.send(.hello(Hello(deviceName: request.deviceName, viewport: request.viewport)))

        let display = display
        let inputs = inputs.stream
        let outbox = outbox.stream
        let onEvent = onEvent
        // Whichever channel ends first ends the session.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await message in session.controlMessages {
                    switch message {
                    case .streamConfig(let config): onEvent(.streamConfig(config))
                    case .windows(let windows): onEvent(.windows(windows))
                    case .bye(let reason): throw ClientError.hostEnded(reason)
                    case .ping(let value): try await session.send(.pong(value))
                    case .helloAck, .pong, .hello, .pairRequest, .pairResult, .listWindows, .selectSource,
                         .requestKeyframe, .insertText:
                        continue
                    }
                }
            }
            group.addTask {
                for try await (header, payload) in session.videoFrames {
                    if display.enqueue(header: header, payload: payload) {
                        try await session.send(.requestKeyframe)
                    }
                }
            }
            group.addTask {
                for await event in inputs { try await session.send(event) }
            }
            group.addTask {
                for await message in outbox { try await session.send(message) }
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Presents the invite token; the code shown here must match the one on the Mac.
    private func pair(_ session: QUICPeerSession, invite: PairingInvite) async throws {
        onEvent(.awaitingApproval(code: Pairing.verificationCode(
            host: invite.hostFingerprint, client: identity.fingerprint, token: invite.token)))
        try await session.send(.pairRequest(PairRequest(token: [UInt8](invite.token), deviceName: request.deviceName)))
        var control = session.controlMessages.makeAsyncIterator()
        switch try await control.next() {
        case .pairResult(accepted: true):
            onEvent(.paired(PairedPeer(fingerprint: invite.hostFingerprint, name: invite.hostName, hostID: invite.hostID)))
        case .pairResult(accepted: false):
            throw ClientError.pairingDeclined
        case .bye(let reason):
            throw ClientError.hostEnded(reason)
        default:
            throw ClientError.unexpectedMessage
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ClientError: error.description
        case TransportError.timedOut: "Couldn't reach the Mac. Is PocketDesk running on it?"
        case TransportError.connectionFailed(let error): "Connection failed: \(error.localizedDescription)"
        case TransportError.closed: "The Mac closed the connection."
        default: error.localizedDescription
        }
    }
}
