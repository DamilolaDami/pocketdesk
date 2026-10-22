import AVFoundation
import Foundation
import Network
import PDProtocol
import PDSecurity
import PDTransport
import Synchronization

/// What a connection reports to `SessionController`.
public enum ClientEvent: Sendable, Equatable {
    /// Pairing: show this code; the person at the Mac must accept the same one.
    case awaitingApproval(code: String)
    case paired(PairedPeer)
    case displays([DisplayInfo])
    case streamConfig(StreamConfig)
    case linkQuality(LinkQuality)
    case windows([WindowInfo])
    /// Something to tell the person without ending the session (a shortcut that failed).
    case notice(String)
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
        public var preferredDisplayID: String?
        public var audioEnabled: Bool

        public init(endpoint: NWEndpoint, hostFingerprint: Fingerprint, invite: PairingInvite?,
                    deviceName: String, viewport: Viewport, audioEnabled: Bool = true, preferredDisplayID: String? = nil) {
            self.endpoint = endpoint
            self.hostFingerprint = hostFingerprint
            self.invite = invite
            self.deviceName = deviceName
            self.viewport = viewport
            self.preferredDisplayID = preferredDisplayID
            self.audioEnabled = audioEnabled
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
        let playbackID = display.beginSession(audioEnabled: request.audioEnabled)
        defer { display.endSession(playbackID) }
        do {
            try await QUICClient.connect(to: request.endpoint, identity: identity, host: request.hostFingerprint) { session in
                try await self.drive(session, playbackID: playbackID)
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

    private func drive(_ session: QUICPeerSession, playbackID: UUID) async throws {
        guard display.isCurrentSession(playbackID) else { throw CancellationError() }
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .moviePlayback)
        try audioSession.setActive(true)
        defer {
            if display.isCurrentSession(playbackID) {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        #endif
        if let invite = request.invite {
            try await pair(session, invite: invite)
        }
        try await session.send(.hello(Hello(deviceName: request.deviceName, viewport: request.viewport, audioEnabled: request.audioEnabled, preferredDisplayID: request.preferredDisplayID)))

        let display = display
        let inputs = inputs.stream
        let outbox = outbox.stream
        let onEvent = onEvent
        // The host says why before it hangs up, but its close also fails the video channel;
        // keep the stated reason so it wins over "connection reset".
        let hostReason = HostReason()
        do {
            try await stream(session, display: display, inputs: inputs, outbox: outbox, onEvent: onEvent, hostReason: hostReason, playbackID: playbackID)
        } catch {
            if let reason = hostReason.value { throw ClientError.hostEnded(reason) }
            throw error
        }
    }

    private nonisolated func stream(_ session: QUICPeerSession, display: VideoDisplay,
                                    inputs: AsyncStream<InputEvent>, outbox: AsyncStream<ControlMessage>,
                                    onEvent: @escaping @Sendable (ClientEvent) -> Void,
                                    hostReason: HostReason, playbackID: UUID) async throws {
        // Whichever channel ends first ends the session.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await message in session.controlMessages {
                    switch message {
                    case .helloAck(let ack): onEvent(.displays(ack.displays))
                    case .displays(let displays): onEvent(.displays(displays))
                    case .streamConfig(let config): onEvent(.streamConfig(config))
                    case .linkQuality(let quality): onEvent(.linkQuality(quality))
                    case .windows(let windows): onEvent(.windows(windows))
                    case .actionFailed(let reason): onEvent(.notice(reason))
                    case .bye(let reason):
                        hostReason.value = reason
                        throw ClientError.hostEnded(reason)
                    case .ping(let value): try await session.send(.pong(value))
                    case .listDisplays, .selectDisplay, .setAudioEnabled, .pong, .hello, .pairRequest, .pairResult, .listWindows, .selectSource,
                         .requestKeyframe, .insertText, .run, .listApps, .apps, .requestAppIcons, .appIcon:
                        continue
                    }
                }
            }
            group.addTask {
                for try await (header, payload) in session.videoFrames {
                    if display.enqueue(header: header, payload: payload, sessionID: playbackID) {
                        try await session.send(.requestKeyframe)
                    }
                }
            }
            group.addTask {
                for try await (header, payload) in session.audioFrames {
                    try display.enqueueAudio(header: header, payload: payload, sessionID: playbackID)
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

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ClientError: error.description
        case TransportError.timedOut: "Couldn't reach the Mac. Is PocketDesk running on it?"
        case TransportError.connectionFailed(let error): "Connection failed: \(error.localizedDescription)"
        case TransportError.closed: "The Mac closed the connection."
        default: error.localizedDescription
        }
    }
}

/// What a catalog connection reports, as it arrives.
public enum CatalogUpdate: Sendable, Equatable {
    case apps([MacApp])
    /// `png == nil`: the Mac has no icon for it (or no such app).
    case icon(bundleID: String, png: Data?)
}

extension ClientConnection {
    /// A short connection with no video: lists the Mac's apps, then fetches icons for the
    /// bundle IDs `iconsWanted` picks from that list. Doesn't need Screen Recording on the Mac.
    public static func catalog(endpoint: NWEndpoint, hostFingerprint: Fingerprint, identity: DeviceIdentity,
                               deviceName: String,
                               iconsWanted: @escaping @Sendable ([MacApp]) -> [String]) -> AsyncThrowingStream<CatalogUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await QUICClient.connect(to: endpoint, identity: identity, host: hostFingerprint) { session in
                        var control = session.controlMessages.makeAsyncIterator()
                        /// The next message that isn't housekeeping; a `bye` ends the fetch with its reason.
                        func next() async throws -> ControlMessage {
                            while let message = try await control.next() {
                                switch message {
                                case .bye(let reason): throw ClientError.hostEnded(reason)
                                case .ping(let value): try await session.send(.pong(value))
                                default: return message
                                }
                            }
                            throw TransportError.closed
                        }

                        try await session.send(.hello(Hello(deviceName: deviceName, viewport: Viewport(width: 0, height: 0, scale: 1),
                                                            mode: .catalog)))
                        guard case .helloAck = try await next() else { throw ClientError.unexpectedMessage }
                        try await session.send(.listApps)
                        guard case .apps(let apps) = try await next() else { throw ClientError.unexpectedMessage }
                        continuation.yield(.apps(apps))

                        let wanted = iconsWanted(apps)
                        if !wanted.isEmpty {
                            try await session.send(.requestAppIcons(wanted))
                            for _ in wanted {
                                guard case .appIcon(let icon) = try await next() else { throw ClientError.unexpectedMessage }
                                continuation.yield(.icon(bundleID: icon.bundleID, png: icon.png.flatMap { Data(base64Encoded: $0) }))
                            }
                        }
                        try await session.send(.bye(reason: "done"))
                        // Let the Mac hang up first; closing now could discard the bye unsent.
                        while (try? await control.next()) != nil {}
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The reason from the host's `bye`, shared between the session's channel tasks.
private final class HostReason: Sendable {
    private let storage = Mutex<String?>(nil)
    var value: String? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
