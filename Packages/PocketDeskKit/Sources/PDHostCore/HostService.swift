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
    case relayStatus(HostRelayStatus)
    case listening(port: UInt16?)
    case stopped(error: String?)
    case inviteChanged(PairingInvite?)
    case approvalRequested(PairingApproval)
    case approvalResolved(id: UUID)
    case pairedPeersChanged([PairedPeer])
    case sessionStarted(peer: Fingerprint, deviceName: String)
    case sessionStreaming(peer: Fingerprint, config: StreamConfig, window: WindowInfo?)
    case sessionEnded(peer: Fingerprint)
    /// A phone sent a file; it's in Downloads at `url`.
    case fileReceived(deviceName: String, url: URL)
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
        /// Nil keeps remote registration and forwarding off.
        public var relayServer: RelayServer?
        /// Paired phones still need a yes from the person at the Mac for each session.
        public var askBeforeConnecting: Bool
        /// Where phones' Now Playing push tokens are kept; `nil` keeps them in memory (tests).
        public var nowPlayingPushesURL: URL?
        /// Delivers Now Playing pushes. `nil` (until the relay can) means none are sent, and
        /// nothing watches what's playing while phones aren't connected.
        public var pushSender: (any LiveActivityPushSender)?
        /// How often what's playing is checked for pushes.
        public var pushInterval: Duration = .seconds(3)

        public init(hostID: UUID, hostName: String,
                    identityLabel: String = "com.pocketdesk.host.identity",
                    trustStoreURL: URL, inviteLifetime: Duration = .seconds(300),
                    approvalTimeout: Duration = .seconds(120), advertise: Bool = true,
                    askBeforeConnecting: Bool = false, relayServer: RelayServer? = nil,
                    nowPlayingPushesURL: URL? = nil, pushSender: (any LiveActivityPushSender)? = nil) {
            self.nowPlayingPushesURL = nowPlayingPushesURL
            self.pushSender = pushSender
            self.relayServer = relayServer
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
    private let clipboard: any ClipboardSink
    private let input: any InputSink
    private let onEvent: @Sendable (HostEvent) -> Void

    private var trustStore: TrustStore
    private var invite: (value: PairingInvite, expires: ContinuousClock.Instant)?
    private var approvals: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var listener: QUICHostListener?
    private var relayAgent: RelayAgent?
    private var relayTask: Task<Void, Never>?
    private var relayGeneration = UUID()
    /// Live sessions by phone (a phone can have a stream and a quick app-list fetch at once).
    private var sessions: [Fingerprint: [UUID: HostSession]] = [:]
    private let nowPlayingPushes: NowPlayingPushes
    private var pushWatch: Task<Void, Never>?
    private var pushWatchID = UUID()
    private var sleeping = false
    /// What the push watcher last saw, to log only changes.
    private var lastPushStatus: NowPlaying?

    public init(configuration: Configuration,
                makeFrameSource: @escaping @Sendable () -> any FrameSource = { ScreenCaptureSource() },
                clipboard: any ClipboardSink = MacPasteboard(),
                input: any InputSink,
                onEvent: @escaping @Sendable (HostEvent) -> Void) throws {
        self.configuration = configuration
        self.identity = try DeviceIdentity.loadOrCreate(label: configuration.identityLabel)
        self.trustStore = try TrustStore.load(from: configuration.trustStoreURL)
        self.nowPlayingPushes = NowPlayingPushes(url: configuration.nowPlayingPushesURL)
        self.makeFrameSource = makeFrameSource
        self.clipboard = clipboard
        self.input = input
        self.onEvent = onEvent
    }

    public var port: UInt16? { listener?.port }

    /// A phone's Now Playing push registration arrived.
    func register(_ push: NowPlayingPush, from peer: Fingerprint) async {
        await nowPlayingPushes.register(push, from: peer, hostID: configuration.hostID)
        await watchForPushesIfNeeded()
    }

    /// What happened to each push (never tokens or titles): `log stream --predicate 'category == "push"'`.
    private static let pushLog = Logger(subsystem: "com.pocketdesk.host", category: "push")

    /// Who delivers pushes: the configured sender (tests), else the relay while Remote Access is on.
    private var pushSender: (any LiveActivityPushSender)? { configuration.pushSender ?? relayAgent }

    /// Follows what's playing while any phone wants pushes and there's a way to send them.
    private func watchForPushesIfNeeded() async {
        guard await !nowPlayingPushes.isEmpty, !sleeping, pushWatch == nil,
              configuration.pushSender != nil || configuration.relayServer != nil else { return }
        let catalog = InstalledApps()
        let watchID = UUID()
        pushWatchID = watchID
        pushWatch = Task {
            while !Task.isCancelled, await !nowPlayingPushes.isEmpty,
                  configuration.pushSender != nil || configuration.relayServer != nil {
                // Nothing reads what's playing while there's no relay to tell.
                if let sender = pushSender {
                    var status = await catalog.status()
                    status.nowPlaying = status.nowPlaying?.coalescingTimeline(with: lastPushStatus)
                    var connected: Set<Fingerprint> = []
                    for (peer, live) in sessions {
                        for session in live.values where await session.phoneIsPresent() { connected.insert(peer) }
                    }
                    guard !sleeping, !Task.isCancelled else { break }
                    let pushes = await nowPlayingPushes.pushes(for: status.nowPlaying, hostID: configuration.hostID,
                                                               macName: configuration.hostName, connected: connected)
                    if status.nowPlaying != lastPushStatus {
                        Self.pushLog.info("Now Playing changed: \(pushes.count, privacy: .public) push(es), \(connected.count, privacy: .public) phone(s) connected")
                    }
                    lastPushStatus = status.nowPlaying
                    for push in pushes {
                        guard !sleeping, !Task.isCancelled else { break }
                        do {
                            try await sender.send(push)
                            Self.pushLog.info("Now Playing \(push.event.rawValue, privacy: .public) push delivered")
                        } catch let error as LiveActivityPushError where error.tokenIsDead {
                            guard pushWatchID == watchID else { break }
                            Self.pushLog.error("Now Playing \(push.event.rawValue, privacy: .public) push: dead token, \(String(describing: error), privacy: .public)")
                            await nowPlayingPushes.tokenRejected(push)
                        } catch {
                            guard pushWatchID == watchID else { break }
                            Self.pushLog.error("Now Playing \(push.event.rawValue, privacy: .public) push failed: \(String(describing: error), privacy: .public)")
                            await nowPlayingPushes.pushFailed(push)
                        }
                    }
                }
                try? await Task.sleep(for: configuration.pushInterval)
            }
            if pushWatchID == watchID { pushWatch = nil }
        }
    }

    /// Send end pushes now, before macOS takes the network away.
    public func prepareForSleep() async {
        sleeping = true
        pushWatch?.cancel()
        pushWatch = nil
        pushWatchID = UUID()
        guard let sender = pushSender else { return }
        let pushes = await nowPlayingPushes.endAll(hostID: configuration.hostID, macName: configuration.hostName)
        await withTaskGroup(of: Void.self) { group in
            for push in pushes {
                group.addTask {
                    do { try await sender.send(push) }
                    catch { Self.pushLog.error("Sleep end push failed: \(String(describing: error), privacy: .public)") }
                }
            }
        }
    }

    public func resumeAfterSleep() async {
        sleeping = false
        await watchForPushesIfNeeded()
    }

    /// Listens until the task is cancelled.
    public func run() async throws {
        onEvent(.pairedPeersChanged(Array(trustStore.peers.values)))
        // Phones that asked for pushes before the Mac last quit.
        Task { await watchForPushesIfNeeded() }
        let advertisement = configuration.advertise
            ? QUICHostListener.Advertisement(name: configuration.hostName, hostID: configuration.hostID,
                                             kind: MacModel.current())
            : nil
        let listener = try QUICHostListener(identity: identity, advertise: advertisement) { [weak self] peer in
            await self?.mayConnect(peer) ?? false
        }
        self.listener = listener
        let reportPort = Task { [onEvent] in
            for _ in 0..<200 {
                if let port = listener.port {
                    onEvent(.listening(port: port))
                    self.refreshRelay()
                    return
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            onEvent(.listening(port: nil))
        }
        defer {
            reportPort.cancel()
            relayGeneration = UUID()
            relayTask?.cancel()
            relayTask = nil
            relayAgent = nil
            self.listener = nil
            onEvent(.relayStatus(.disabled))
        }

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

    public func setRelayServer(_ server: RelayServer?) {
        configuration.relayServer = server
        refreshRelay()
        Task { await watchForPushesIfNeeded() }
    }

    private func refreshRelay() {
        relayGeneration = UUID()
        relayTask?.cancel()
        relayTask = nil
        relayAgent = nil
        guard let server = configuration.relayServer else { onEvent(.relayStatus(.disabled)); return }
        guard listener?.port != nil else { onEvent(.relayStatus(.connecting)); return }
        let generation = relayGeneration
        relayTask = Task { await runRelay(server: server, generation: generation) }
    }

    private func runRelay(server: RelayServer, generation: UUID) async {
        while !Task.isCancelled, relayGeneration == generation {
            do {
                // An unadvertised listener bounds nested packets without changing LAN transport
                // settings. Its TLS gate only accepts pinned phones, even while an invite is open.
                let endpoint = try QUICHostListener(identity: identity, advertise: nil, maxUDPPayloadSize: 1200, loopbackOnly: true) { [weak self] peer in
                    await self?.isTrusted(peer) ?? false
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await endpoint.run { [weak self] session in try await self?.serve(session) }
                    }
                    group.addTask {
                        for _ in 0..<200 {
                            try Task.checkCancellation()
                            if let port = endpoint.port {
                                await self.runRelayAgent(server: server, port: port, generation: generation)
                                return
                            }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        throw TransportError.timedOut
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
            } catch { }
            guard !Task.isCancelled, relayGeneration == generation else { return }
            onEvent(.relayStatus(.unavailable))
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
        }
    }

    private func runRelayAgent(server: RelayServer, port: UInt16, generation: UUID) async {
        guard relayGeneration == generation, !Task.isCancelled else { return }
        let agent = RelayAgent(identity: identity, hostID: configuration.hostID, port: port,
                               server: server, peers: Array(trustStore.peers.keys)) { [onEvent] status in
            onEvent(.relayStatus(status))
        }
        relayAgent = agent
        await agent.run()
        if relayGeneration == generation { relayAgent = nil }
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
        await nowPlayingPushes.forget(peer)
        trustStore.revoke(peer)
        await relayAgent?.update(peers: Array(trustStore.peers.keys))
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
        await relayAgent?.update(peers: Array(trustStore.peers.keys))
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
            configuration: .init(hostName: configuration.hostName, wake: WakeAddresses.current(),
                                 wallpaper: await DesktopWallpaper.current()),
            frameSource: makeFrameSource(), input: input, pairing: self, clipboard: clipboard
        ) { [onEvent, started] event in
            switch event {
            case .connected(let peer, let deviceName):
                started.set()
                onEvent(.sessionStarted(peer: peer, deviceName: deviceName))
            case .streaming(let peer, let config, let window):
                onEvent(.sessionStreaming(peer: peer, config: config, window: window))
            case .fileReceived(_, let deviceName, let url):
                onEvent(.fileReceived(deviceName: deviceName, url: url))
            case .nowPlayingPush(let peer, let push):
                Task { await self.register(push, from: peer) }
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
