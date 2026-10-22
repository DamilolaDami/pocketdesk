#if os(macOS)
import Foundation
import OSLog
import PDProtocol
import PDSecurity
import PDTransport
import Synchronization

/// A phone waiting for the person at the Mac: to confirm its verification code (pairing),
/// or, with "Ask before each connection" on, to let it in (`code == nil`).
public struct PairingApproval: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var deviceName: String
    public var code: String?
    public var peer: Fingerprint?

    public init(id: UUID, deviceName: String, code: String?, peer: Fingerprint? = nil) {
        self.id = id
        self.deviceName = deviceName
        self.code = code
        self.peer = peer
    }

    public var isConnectionRequest: Bool { code == nil }
}

/// Everything the Mac UI needs to know, as events into `HostState.reduce`.
public enum HostEvent: Sendable, Equatable {
    case listening(port: UInt16?)
    case stopped(error: String?)
    case inviteChanged(PairingInvite?)
    case approvalRequested(PairingApproval)
    case approvalResolved(id: UUID)
    case pairedPeersChanged([PairedPeer])
    case sessionStarted(peer: Fingerprint, deviceName: String)
    case sessionStreaming(peer: Fingerprint, config: StreamConfig, window: WindowInfo?)
    case sessionEnded(peer: Fingerprint)
}

/// The host's long-running service: identity, listener (advertised over Bonjour), pinned
/// phones, pairing invites, and one `HostSession` per connected phone.
public actor HostService: PairingAuthority {
    public struct Configuration: Sendable {
        public var hostID: UUID
        public var hostName: String
        public var identityLabel: String
        public var trustStoreURL: URL
        public var inviteLifetime: Duration
        public var approvalTimeout: Duration
        /// `false` for tests that connect over 127.0.0.1.
        public var advertise: Bool
        /// Paired phones still need a yes from the person at the Mac for each session.
        public var askBeforeConnecting: Bool

        public init(hostID: UUID, hostName: String,
                    identityLabel: String = "com.pocketdesk.host.identity",
                    trustStoreURL: URL, inviteLifetime: Duration = .seconds(300),
                    approvalTimeout: Duration = .seconds(120), advertise: Bool = true,
                    askBeforeConnecting: Bool = false) {
            self.hostID = hostID
            self.hostName = hostName
            self.identityLabel = identityLabel
            self.trustStoreURL = trustStoreURL
            self.inviteLifetime = inviteLifetime
            self.approvalTimeout = approvalTimeout
            self.advertise = advertise
            self.askBeforeConnecting = askBeforeConnecting
        }
    }

    public nonisolated let identity: DeviceIdentity
    private var configuration: Configuration
    private let makeFrameSource: @Sendable () -> any FrameSource
    private let input: any InputSink
    private let onEvent: @Sendable (HostEvent) -> Void

    private var trustStore: TrustStore
    private var invite: (value: PairingInvite, expires: ContinuousClock.Instant)?
    private var approvals: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var listener: QUICHostListener?
    /// Live sessions by phone (a phone can have a stream and a quick app-list fetch at once).
    private var sessions: [Fingerprint: [UUID: HostSession]] = [:]

    public init(configuration: Configuration,
                makeFrameSource: @escaping @Sendable () -> any FrameSource = { ScreenCaptureSource() },
                input: any InputSink,
                onEvent: @escaping @Sendable (HostEvent) -> Void) throws {
        self.configuration = configuration
        self.identity = try DeviceIdentity.loadOrCreate(label: configuration.identityLabel)
        self.trustStore = try TrustStore.load(from: configuration.trustStoreURL)
        self.makeFrameSource = makeFrameSource
        self.input = input
        self.onEvent = onEvent
    }

    public var port: UInt16? { listener?.port }

    /// Listens until the task is cancelled.
    public func run() async throws {
        onEvent(.pairedPeersChanged(Array(trustStore.peers.values)))
        let advertisement = configuration.advertise
            ? QUICHostListener.Advertisement(name: configuration.hostName, hostID: configuration.hostID)
            : nil
        let listener = try QUICHostListener(identity: identity, advertise: advertisement) { [weak self] peer in
            await self?.mayConnect(peer) ?? false
        }
        self.listener = listener
        let reportPort = Task { [onEvent] in
            for _ in 0..<200 {
                if let port = listener.port { onEvent(.listening(port: port)); return }
                try await Task.sleep(for: .milliseconds(10))
            }
            onEvent(.listening(port: nil))
        }
        defer { reportPort.cancel() }

        do {
            try await listener.run { [weak self] session in
                try await self?.serve(session)
            }
            onEvent(.stopped(error: nil))
        } catch {
            onEvent(.stopped(error: String(describing: error)))
            throw error
        }
    }

    // MARK: Pairing

    /// Opens a one-time invite for the QR code. Replaces any open invite.
    public func openInvite() -> PairingInvite {
        let invite = PairingInvite.make(hostID: configuration.hostID, hostName: configuration.hostName,
                                        hostFingerprint: identity.fingerprint)
        self.invite = (invite, .now + configuration.inviteLifetime)
        onEvent(.inviteChanged(invite))
        return invite
    }

    public func closeInvite() {
        invite = nil
        onEvent(.inviteChanged(nil))
    }

    /// The person at the Mac confirmed (or rejected) the code shown for `id`.
    public func resolveApproval(_ id: UUID, accepted: Bool) {
        approvals.removeValue(forKey: id)?.resume(returning: accepted)
        onEvent(.approvalResolved(id: id))
    }

    /// Forgets the phone, and ends its sessions: an unpaired phone mustn't stay connected.
    public func revoke(_ peer: Fingerprint) async throws {
        trustStore.revoke(peer)
        try trustStore.save(to: configuration.trustStoreURL)
        onEvent(.pairedPeersChanged(Array(trustStore.peers.values)))
        await disconnect(peer, reason: "This iPhone was removed from the Mac's paired phones.")
    }

    /// Ends every session of `peer`; the phone is told why.
    public func disconnect(_ peer: Fingerprint, reason: String = "The Mac ended this session.") async {
        for session in Array(sessions[peer, default: [:]].values) {
            await session.end(reason: reason)
        }
    }

    public func setAskBeforeConnecting(_ ask: Bool) {
        configuration.askBeforeConnecting = ask
    }

    public func isTrusted(_ peer: Fingerprint) -> Bool {
        trustStore.trusts(peer)
    }

    public func allowSession(peer: Fingerprint, deviceName: String) async -> Bool {
        guard configuration.askBeforeConnecting else { return true }
        return await ask(PairingApproval(id: UUID(), deviceName: deviceName, code: nil, peer: peer))
    }

    public func approve(peer: Fingerprint, deviceName: String, token: [UInt8]) async -> Bool {
        guard let invite = openInviteIfValid(), invite.matches(token: Data(token)) else { return false }
        let accepted = await ask(PairingApproval(
            id: UUID(), deviceName: deviceName,
            code: Pairing.verificationCode(host: identity.fingerprint, client: peer, token: invite.token), peer: peer))
        guard accepted else { return false }

        trustStore.pin(PairedPeer(fingerprint: peer, name: deviceName))
        do {
            try trustStore.save(to: configuration.trustStoreURL)
        } catch {
            trustStore.revoke(peer)
            return false
        }
        // Invites are single use.
        closeInvite()
        onEvent(.pairedPeersChanged(Array(trustStore.peers.values)))
        return true
    }

    /// Shows `approval` and waits for the person at the Mac; silence is a no.
    private func ask(_ approval: PairingApproval) async -> Bool {
        let timeout = Task { [configuration] in
            try await Task.sleep(for: configuration.approvalTimeout)
            self.resolveApproval(approval.id, accepted: false)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            approvals[approval.id] = continuation
            onEvent(.approvalRequested(approval))
        }
    }

    // MARK: Sessions

    /// TLS-time gate: pinned phones always, anyone else only while an invite is open (they
    /// must then present its token before anything else happens).
    private func mayConnect(_ peer: Fingerprint) -> Bool {
        trustStore.trusts(peer) || openInviteIfValid() != nil
    }

    private func openInviteIfValid() -> PairingInvite? {
        guard let invite else { return nil }
        guard ContinuousClock.now < invite.expires else {
            closeInvite()
            return nil
        }
        return invite.value
    }

    private func serve(_ session: QUICPeerSession) async throws {
        let peer = session.peer
        // Catalog sessions never say "connected", so they mustn't say "ended" either: that
        // would hide the same phone's live stream from the menu.
        let started = StartedFlag()
        let hostSession = HostSession(
            session: ThrottledSession.fromEnvironment(session), peer: peer,
            configuration: .init(hostName: configuration.hostName),
            frameSource: makeFrameSource(), input: input, pairing: self
        ) { [onEvent, started] event in
            switch event {
            case .connected(let peer, let deviceName):
                started.set()
                onEvent(.sessionStarted(peer: peer, deviceName: deviceName))
            case .streaming(let peer, let config, let window):
                onEvent(.sessionStreaming(peer: peer, config: config, window: window))
            }
        }
        let id = UUID()
        sessions[peer, default: [:]][id] = hostSession
        defer {
            sessions[peer]?[id] = nil
            if sessions[peer]?.isEmpty == true { sessions[peer] = nil }
            if started.isSet { onEvent(.sessionEnded(peer: peer)) }
        }
        do {
            try await hostSession.run()
        } catch {
            Self.log.error("Session with \(peer.description, privacy: .public) ended: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    private static let log = Logger(subsystem: "com.pocketdesk.host", category: "session")
}

/// Set once from a session's event callback, read when it ends.
private final class StartedFlag: Sendable {
    private let storage = Mutex(false)
    var isSet: Bool { storage.withLock { $0 } }
    func set() { storage.withLock { $0 = true } }
}
#endif
