import Foundation
import PDProtocol
import PDSecurity
import Network
import PDTransport

/// Wires discovery, pairing, the trust store and `ClientConnection` to `SessionStore` for the
/// phone app. Views call these methods; state changes go through the store's reducer.
@MainActor
public final class SessionController {
    public let store = SessionStore()
    /// Loaded synchronously, including Macs that are currently offline. Used for first-run UI.
    public var hasPairedMacs: Bool { !trustStore.peers.isEmpty }
    public let display = VideoDisplay()
    /// The stream view's: where the Mac's caret moved, to keep it in a zoomed-in view. Not
    /// through the store, which redraws for every change.
    public var onCaret: (Caret) -> Void = { _ in }
    /// Set by the app before connecting (screen size in points + scale, device name).
    public var viewport = Viewport(width: 402, height: 874, scale: 3)
    public var deviceName = "iPhone"
    private var hostUpdateWatchID = UUID()
    private var performanceTrace: Task<Void, Never>?
    private var sizingTask: Task<Void, Never>?
    private var desiredWorkspaceMode: VirtualDisplayMode?
    private var modeRequestID: UUID?
    private var lastScenePortrait: Bool?
    private var lastSentViewport: Viewport?


    public var audioEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "streamAudio") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "streamAudio")
            display.setAudioEnabled(newValue)
            connection?.send(.setAudioEnabled(newValue))
        }
    }

    /// Share copied text and images with the Mac while streaming.
    /// The quality chosen in Settings. In Low Power Mode the stream uses Battery Saver anyway.
    public var preferredQuality: StreamQuality {
        get { UserDefaults.standard.string(forKey: "streamQuality").flatMap(StreamQuality.init(rawValue:)) ?? .best }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "streamQuality")
            qualityChanged()
        }
    }

    /// What the stream uses now.
    public var quality: StreamQuality {
        StreamQuality.effective(preferred: preferredQuality, lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// Tells the Mac when the effective quality changes (a new choice, or Low Power Mode).
    public func qualityChanged() {
        let now = quality
        if store.quality != now { store.update(quality: now) }
        connection?.send(.setQuality(now))
    }

    public var clipboardEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "shareClipboard") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "shareClipboard")
            connection?.send(.setClipboardEnabled(newValue))
        }
    }
    public var pasteboard: any PhonePasteboard = SystemPasteboard()

    private let displayPreferencesURL: URL
    private var displayPreferences: DisplayPreferences
    private let wakeBookURL: URL
    private let locksURL: URL
    private var locks: MacLocks
    /// Asks for Face ID (or the passcode) with this reason; the app supplies it. Without one,
    /// a locked Mac can't be unlocked.
    public var authenticate: @MainActor (_ reason: String) async -> Bool = { _ in false }
    private var wakeBook: PerMac<WakeInfo>
    private let macKindsURL: URL
    private var macKinds: PerMac<MacKind>
    private let macNamesURL: URL
    /// Names given on this phone, shown instead of the Mac's own.
    private var macNames: PerMac<String>
    private let lastUsedURL: URL
    private var lastUsed: PerMac<Date>
    /// Auto-connect happens once per launch, not again after leaving a Mac.
    private var autoConnected = false
    /// Open the most recently used Mac as soon as it shows up.
    public var autoConnect: Bool {
        get { UserDefaults.standard.bool(forKey: "autoConnect") }
        set { UserDefaults.standard.set(newValue, forKey: "autoConnect") }
    }
    private var wakeAttempts = WakeAttempts()
    private var wakeTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionHostID: UUID?
    private var activeConnectionID: UUID?
    public var reconnectPolicy = ReconnectPolicy()
    /// Waiting out the delay before the next reconnect attempt.
    private var reconnectTask: Task<Void, Never>?
    /// What the dropped stream showed, to put back once it's up again.
    private var restoring: (window: WindowInfo?, displayID: String?, hadWorkspace: Bool)?
    /// Asked for the windows to find the one being restored; `.windows` finishes the restore.
    private var restoringWindow: WindowInfo?

    private let identityLabel: String
    private let trustStoreURL: URL
    private var trustStore: TrustStore
    private var browsed: [String: BrowsedHost] = [:]
    /// A pasted/scanned invite whose Mac hasn't shown up in discovery yet.
    private var pendingInvite: PairingInvite?
    private var discoveryTask: Task<Void, Never>?
    private var connection: ClientConnection?
    private var connectionTask: Task<Void, Never>?
    /// The Mac last tapped, for "Try Again".
    public private(set) var lastHost: DiscoveredHost?
    private let shortcutsURL: URL
    private var library: ShortcutLibrary
    /// After the saved shortcuts change: the app refreshes widgets and Siri's phrases.
    public var onShortcutsChanged: (() -> Void)?
    /// A shortcut tapped while not connected: sent once the stream starts.
    private var pendingAction: MacAction?
    private let cacheDirectory: URL
    private var catalogTask: Task<Void, Never>?
    private var catalogFetchedAt: [UUID: ContinuousClock.Instant] = [:]
    private var heldKey: (code: UInt16, task: Task<Void, Never>)?
    private var statusTask: Task<Void, Never>?
    /// File transfers over the stream, while there is one.
    private var streamFiles: MacFiles?
    /// Follows Low Power Mode, which switches the stream to Battery Saver.
    private var powerStateTask: Task<Void, Never>?
    /// Screens showing live status (the Macs tab, the Shortcuts tab): it stops when none are.
    private var statusWatchers: Set<String> = []
    /// Puts the watched Mac's now playing on the Lock Screen and in the Dynamic Island. The
    /// app sets it (iOS only); setting it picks up an activity left from an earlier launch.
    public var nowPlayingPresenter: (any NowPlayingPresenter)? {
        didSet { adoptNowPlayingActivity() }
    }
    private var nowPlaying = NowPlayingActivityModel(preferences: NowPlayingActivityPreferences(defaults: .standard))
    /// Steps reach the presenter in order.
    private var nowPlayingQueue: Task<Void, Never>?
    var controlDiagnostics = NowPlayingControlDiagnostics.shared
    /// The last cover, decoded once: its file name, bytes and color.
    private var nowPlayingArtwork: (base64: String, id: String, jpeg: Data, tint: CardColor?)?
    /// Site icons for browser playback, by host, once saved: `nil` while fetching, or once a
    /// site turned out to have none.
    private var siteIcons: [String: (id: String, tint: CardColor?)?] = [:]
    /// What Apple gave for pushing to the activity, for the Mac to use while the app is closed.
    private var nowPlayingPushTokens = NowPlayingPushTokens()
    /// `.sandbox` for builds from Xcode; the app says (its push entitlement decides).
    public var pushEnvironment = NowPlayingPush.Environment.production
    /// Settings › Now Playing › Start When Music Plays.
    public var startsNowPlayingByPush: Bool {
        UserDefaults.standard.object(forKey: NowPlayingActivityPreferences.Key.startsByPush) as? Bool ?? true
    }
    /// What the Mac last said, to redraw with when a site icon arrives.
    private var lastNowPlaying: (playing: NowPlaying?, host: DiscoveredHost)?
    /// The Mac the status watch is for, to reconnect to it.
    private var statusPreferredHostID: UUID?
    /// Status checks in a row that found no Mac to watch; the activity ends after a couple.
    private var checksWithoutMac = 0

    public init(identityLabel: String = "com.pocketdesk.phone.identity",
                trustStoreURL: URL = SharedStorage.url("paired-macs.json"),
                shortcutsURL: URL = ShortcutLibrary.sharedURL,
                cacheDirectory: URL = URL.cachesDirectory.appending(path: "PocketDesk"),
                displayPreferencesURL: URL = SharedStorage.url("displays.json"),
                wakeBookURL: URL = SharedStorage.url("wake.json"),
                macKindsURL: URL = SharedStorage.url("mac-kinds.json"),
                macNamesURL: URL = SharedStorage.url("mac-names.json"),
                lastUsedURL: URL = SharedStorage.url("last-used.json"),
                locksURL: URL = SharedStorage.url("locked-macs.json")) {
        self.locksURL = locksURL
        self.locks = (try? MacLocks.load(from: locksURL)) ?? MacLocks()
        self.macNamesURL = macNamesURL
        self.macNames = (try? PerMac.load(from: macNamesURL)) ?? PerMac()
        self.lastUsedURL = lastUsedURL
        self.lastUsed = (try? PerMac.load(from: lastUsedURL)) ?? PerMac()
        self.wakeBookURL = wakeBookURL
        self.wakeBook = (try? PerMac.load(from: wakeBookURL)) ?? PerMac()
        self.macKindsURL = macKindsURL
        self.macKinds = (try? PerMac.load(from: macKindsURL)) ?? PerMac()
        self.displayPreferencesURL = displayPreferencesURL
        self.displayPreferences = (try? DisplayPreferences.load(from: displayPreferencesURL)) ?? DisplayPreferences()
        self.cacheDirectory = cacheDirectory
        self.identityLabel = identityLabel
        self.trustStoreURL = trustStoreURL
        self.trustStore = (try? TrustStore.load(from: trustStoreURL)) ?? TrustStore()
        self.shortcutsURL = shortcutsURL
        self.library = (try? ShortcutLibrary.load(from: shortcutsURL)) ?? ShortcutLibrary()
        store.update(shortcuts: library.shortcuts)
        store.update(quality: quality)
        loadWallpapers()
        powerStateTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                self?.qualityChanged()
            }
        }
    }

    public var relayServer: RelayServer? {
        guard UserDefaults.standard.bool(forKey: RelayServer.enabledKey) else { return nil }
        return RelayServer(address: RelayServer.savedAddress())
    }
    public func relaySettingsChanged() {
        store.send(.hostsChanged(discoveredHosts()))
        store.update(relayHealth: RelayHealthState())
    }

    /// Runs only while the Remote Access settings view is active. UI cancellation stops checks.
    public func watchRelayStatus() async {
        while !Task.isCancelled {
            await checkRelayStatus()
            do { try await Task.sleep(for: .seconds(30)) } catch { break }
        }
    }

    public func checkRelayStatus() async {
        guard let server = relayServer else {
            store.update(relayHealth: RelayHealthState())
            return
        }
        var health = store.relayHealth
        let checkID = health.begin(server: server)
        store.update(relayHealth: health)
        let reachable: Bool
        do {
            let identity = try DeviceIdentity.loadOrCreate(label: identityLabel)
            try await RelayConnection.check(server: server, identity: identity)
            reachable = true
        } catch { reachable = false }
        guard !Task.isCancelled, relayServer == server else { return }
        health = store.relayHealth
        health.finish(checkID: checkID, reachable: reachable)
        store.update(relayHealth: health)
    }

    // MARK: Discovery

    public func startDiscovery() {
        store.send(.startDiscovery)
        // Paired Macs (offline, or reachable through the relay) show straight away. Away from
        // home a fresh Bonjour browser may never report anything, and waiting for it left the
        // list empty after a relayed session ended.
        store.send(.hostsChanged(discoveredHosts()))
        guard discoveryTask == nil else { return }
        discoveryTask = Task { [weak self] in
            do {
                for try await hosts in HostBrowser.hosts() {
                    self?.update(hosts)
                }
            } catch {
                self?.discoveryTask = nil
            }
        }
    }

    private func update(_ hosts: [BrowsedHost]) {
        browsed = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Remember what each paired Mac looks like, to draw it while it's offline too.
        var kindsChanged = false
        for host in hosts {
            guard let kind = host.kind, let hostID = host.hostID, trustStore.peer(hostID: hostID) != nil,
                  macKinds[hostID] != kind else { continue }
            macKinds[hostID] = kind
            kindsChanged = true
        }
        if kindsChanged { try? macKinds.save(to: macKindsURL) }
        let woke = wakeAttempts.woke(Set(hosts.compactMap(\.hostID)))
        for host in woke { wakeTasks.removeValue(forKey: host)?.cancel() }
        store.send(.hostsChanged(discoveredHosts()))
        // A Mac we were waking is up: connect, unless something else has started meanwhile.
        if let hostID = woke.first, case .discovering = store.state,
           let host = discoveredHosts().first(where: { $0.hostID == hostID && $0.isOnline }) {
            select(host)
        }
        if let invite = pendingInvite, let host = hosts.first(where: { $0.hostID == invite.hostID }) {
            pendingInvite = nil
            beginPairing(invite, with: host)
        }
        if autoConnect, !autoConnected, case .discovering = store.state,
           let host = discoveredHosts().filter({ $0.isPaired && $0.isOnline && $0.needsUpdate == nil && $0.lastUsed != nil })
               .max(by: { $0.lastUsed! < $1.lastUsed! }) {
            autoConnected = true
            select(host)
        }
    }

    /// Online Macs from Bonjour, plus paired Macs that aren't advertising right now.
    private func discoveredHosts() -> [DiscoveredHost] {
        let online = browsed.values.map { host in
            DiscoveredHost(id: host.id, name: macNames[host.hostID] ?? host.name, hostID: host.hostID,
                           isPaired: host.hostID.flatMap(trustStore.peer(hostID:)) != nil,
                           canWake: wakeBook[host.hostID] != nil, kind: host.kind,
                           needsUpdate: DiscoveredHost.Side(macVersion: host.protocolVersion),
                           lastUsed: lastUsed[host.hostID])
        }
        let onlineIDs = Set(online.compactMap(\.hostID))
        let offline = trustStore.peers.values
            .filter { peer in peer.hostID.map { !onlineIDs.contains($0) } ?? false }
            .map { peer in
                DiscoveredHost(id: "paired-\(peer.fingerprint.description)", name: macNames[peer.hostID] ?? peer.name,
                               hostID: peer.hostID, isPaired: true, isOnline: false,
                               canWake: wakeBook[peer.hostID] != nil,
                               isWaking: peer.hostID.map(wakeAttempts.waking.contains) ?? false,
                               kind: macKinds[peer.hostID], lastUsed: lastUsed[peer.hostID])
            }
        return DiscoveredHost.ordered((online + offline).map { host in
            var host = host
            host.isLocked = locks.isLocked(host.hostID)
            host.needsUnlock = locks.needsUnlock(host.hostID)
            host.canRelay = host.isPaired && relayServer != nil
            return host
        })
    }

    // MARK: Connecting

    /// Paired Macs connect straight away; unpaired ones show the pairing screen.
    public func select(_ host: DiscoveredHost) {
        guard host.isOnline || host.canRelay else { return }
        if let side = host.needsUpdate {
            if side == .mac, host.isPaired { showHostUpdate(host); return }
            store.post(notice: side == .mac ? "Update PocketDesk on \(host.name) to use it from this iPhone."
                                            : "Update PocketDesk on this iPhone to use \(host.name).")
            return
        }
        if host.isPaired, locks.needsUnlock(host.hostID) {
            Task { if await unlock(host) { select(host) } }
            return
        }
        lastHost = host
        store.send(.select(host))
        guard host.isPaired, let peer = host.hostID.flatMap(trustStore.peer(hostID:)) else { return }
        connect(endpoint: browsed[host.id]?.endpoint, hostID: host.hostID, hostFingerprint: peer.fingerprint, invite: nil)
    }

    /// Sends magic packets to a sleeping Mac, then connects as soon as it shows up.
    public func wake(_ host: DiscoveredHost) {
        guard let hostID = host.hostID, !host.isOnline else { return }
        if locks.needsUnlock(hostID) {
            Task { if await unlock(host) { wake(host) } }
            return
        }
        guard let info = wakeBook[hostID] else {
            store.post(notice: "Connect to \(host.name) once while it's awake, so this iPhone learns how to wake it.")
            return
        }
        if info.wakeForNetworkAccess == false {
            store.post(notice: "\(host.name) has “Wake for network access” turned off; it may not wake.")
        }
        lastHost = host
        wakeAttempts.start(hostID, at: .now)
        startDiscovery()
        // Packets can be lost and a Mac can miss the first while dozing off: send a few.
        wakeTasks[hostID]?.cancel()
        wakeTasks[hostID] = Task { [weak self] in
            var elapsed = Duration.zero
            for at in [0, 3, 8, 15].map(Duration.seconds) {
                try? await Task.sleep(for: at - elapsed)
                elapsed = at
                guard !Task.isCancelled else { return }
                await Task.detached { WakeSender.wake(info) }.value
            }
            try? await Task.sleep(for: WakeAttempts.timeout - elapsed)
            guard !Task.isCancelled else { return }
            self?.wakeTimedOut()
        }
    }

    private func wakeTimedOut() {
        for hostID in wakeAttempts.expire(at: .now) {
            wakeTasks[hostID] = nil
            let name = trustStore.peer(hostID: hostID)?.name ?? "The Mac"
            store.post(notice: "Couldn't wake \(name). On the Mac, turn on “Wake for network access” in System Settings › Battery › Options (Energy on desktops).")
        }
        store.send(.hostsChanged(discoveredHosts()))
    }

    /// From a scanned QR code, a pasted link, or a `pocketdesk://pair` URL opened on the phone.
    public func pair(using url: URL) throws(PairingError) {
        let invite = try PairingInvite(url: url)
        if let host = browsed.values.first(where: { $0.hostID == invite.hostID }) {
            beginPairing(invite, with: host)
        } else {
            // Not discovered yet: pair as soon as it appears.
            pendingInvite = invite
            startDiscovery()
        }
    }

    private func beginPairing(_ invite: PairingInvite, with host: BrowsedHost) {
        let discovered = DiscoveredHost(id: host.id, name: host.name, hostID: host.hostID, isPaired: false)
        switch store.state {
        case .pairing(let current, _) where current.id == host.id:
            break
        default:
            disconnectConnection()
            store.send(.cancel)
            store.send(.startDiscovery)
            store.send(.hostsChanged(discoveredHosts()))
            store.send(.select(discovered))
        }
        if let failure = PairingCompatibility.failure(macVersion: host.protocolVersion, macName: host.name) {
            disconnectConnection()
            store.send(.disconnected(reason: failure))
            return
        }
        connect(to: host, hostFingerprint: invite.hostFingerprint, invite: invite)
    }

    private func connect(to host: BrowsedHost, hostFingerprint: Fingerprint, invite: PairingInvite?) {
        connect(endpoint: host.endpoint, hostID: host.hostID, hostFingerprint: hostFingerprint, invite: invite)
    }

    private func connect(endpoint: NWEndpoint?, hostID: UUID?, hostFingerprint: Fingerprint, invite: PairingInvite?) {
        disconnectConnection()
        let identity: DeviceIdentity
        do {
            identity = try DeviceIdentity.loadOrCreate(label: identityLabel)
        } catch {
            store.send(.disconnected(reason: "Couldn't create this phone's identity: \(error)"))
            return
        }
        let connectionID = UUID()
        activeConnectionID = connectionID
        connectionHostID = hostID ?? invite?.hostID
        let connection = ClientConnection(
            identity: identity,
            request: .init(endpoint: endpoint, hostFingerprint: hostFingerprint, invite: invite,
                           deviceName: deviceName, viewport: viewport, audioEnabled: audioEnabled,
                           preferredDisplayID: displayPreferences.displayID(for: connectionHostID),
                           clipboardEnabled: clipboardEnabled, quality: quality, relay: invite == nil ? relayServer : nil,
                           findLocal: { [weak self] in await self?.findNearby(hostID: hostID) },
                           // Not while pairing: the Mac doesn't trust this phone yet.
                           nowPlayingPush: invite == nil ? nowPlayingPush(for: connectionHostID) : nil),
            display: display
        ) { [weak self] event in
            Task { @MainActor in
                guard let self, self.activeConnectionID == connectionID else { return }
                self.handle(event)
            }
        }
        self.connection = connection
        connectionTask = Task { await connection.run() }
    }

    private func findNearby(hostID: UUID?) async -> NWEndpoint? {
        guard let hostID else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            if let host = browsed.values.first(where: { $0.hostID == hostID }) { return host.endpoint }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
        }
        return nil
    }

    private func handle(_ event: ClientEvent) {
        switch event {
        case .path(let path): store.update(path: path)
        case .awaitingApproval(let code):
            store.send(.pairingCode(code))
        case .paired(let peer):
            trustStore.pin(peer)
            try? trustStore.save(to: trustStoreURL)
            store.send(.pairingConfirmed)
        case .virtualDisplay(let report):
            store.update(virtualDisplay: .received(report))
            if let modeRequestID, report.requestID == modeRequestID {
                self.modeRequestID = nil
                if report.problem != nil { desiredWorkspaceMode = nil }
                else if report.workspace?.acceptedMode == desiredWorkspaceMode { desiredWorkspaceMode = nil }
            }
            if let workspace = report.workspace, workspace.isOwner {
                if desiredWorkspaceMode == nil, !store.virtualDisplay.isBusy {
                    var sizing = store.workspaceSizing
                    sizing.accept(workspace.acceptedMode)
                    store.update(workspaceSizing: sizing)
                }
                if !store.virtualDisplay.isBusy, desiredWorkspaceMode != nil || lastSentViewport != viewport { scheduleWorkspaceUpdate() }
            } else if report.phase == .idle {
                desiredWorkspaceMode = nil
            }
        case .displays(let displays):
            store.update(displays: displays)
        case .wallpaper(let jpeg):
            if let hostID = connectionHostID { save(wallpaper: jpeg, for: hostID) }
        case .wake(let info):
            // A session over a VPN or with Wi-Fi off reports nothing useful; keep the last good one.
            if let hostID = connectionHostID, !info.interfaces.isEmpty, wakeBook[hostID] != info {
                wakeBook[hostID] = info
                try? wakeBook.save(to: wakeBookURL)
            }
        case .streamConfig(let config):
            let reconnected: Bool
            if case .reconnecting = store.state { reconnected = true } else { reconnected = false }
            if config.displayID != nil { store.send(.sourceChanged(nil)) }
            store.send(.connected(config))
            if reconnected { restoreSession(config) }
#if DEBUG && os(iOS)
            if performanceTrace == nil { performanceTrace = WorkspacePerformanceTrace.start(self) }
#endif
            if let hostID = connectionHostID {
                lastUsed[hostID] = .now
                try? lastUsed.save(to: lastUsedURL)
            }
            if let displayID = config.displayID, let hostID = connectionHostID,
               let selected = store.displaySelection.displays.first(where: { $0.id == displayID }),
               displayID != store.virtualDisplay.report?.workspace?.displayID {
                displayPreferences.remember(selected.persistentID, for: hostID)
                try? displayPreferences.save(to: displayPreferencesURL)
            }
            if config.displayID == store.virtualDisplay.report?.workspace?.displayID,
               store.virtualDisplay.report?.workspace?.isOwner == true, let lastScenePortrait {
                var sizing = store.workspaceSizing
                if sizing.observeOrientation(portrait: lastScenePortrait) {
                    store.update(workspaceSizing: sizing)
                    desiredWorkspaceMode = sizing.mode
                    scheduleWorkspaceUpdate()
                }
            }
            if let action = pendingAction {
                pendingAction = nil
                connection?.send(.run(action))
            }
        case .linkQuality(let quality):
            store.update(link: quality)
        case .clipboard(let item):
            guard clipboardEnabled else { return }
            pasteboard.write(item)
            store.post(notice: item.text != nil ? "Copied from your Mac" : "Image copied from your Mac", kind: .done)
        case .windows(let windows):
            store.update(windows: windows)
            if let wanted = restoringWindow {
                restoringWindow = nil
                if let window = windows.first(where: { $0.id == wanted.id }) {
                    selectSource(window)
                    if let host = lastHost { store.post(notice: "Reconnected to \(host.name)", kind: .done) }
                } else {
                    store.post(notice: "“\(wanted.title.isEmpty ? wanted.appName : wanted.title)” isn't open any more. Showing the whole display.")
                }
            }
        case .menuBar(let bar):
            store.update(menus: bar.map(MenusState.ready) ?? .unavailable)
        case .caret(let caret):
            onCaret(caret)
        case .macStatus(let status):
            store.update(macStatus: status)
            if case .streaming(let host, _, _) = store.state { showNowPlaying(status.nowPlaying, from: host) }
        case .notice(let text):
            store.post(notice: text)
        case .files(let files):
            streamFiles = files
        case .ended(let reason):
            connectionEnded()
            restoring = nil
            store.send(.disconnected(reason: reason))
        case .interrupted(let reason):
            interrupted(reason)
        }
    }

    /// Forgets the connection that just ended. Nothing it was asked to do is sent again.
    private func connectionEnded() {
        performanceTrace?.cancel(); performanceTrace = nil
        sizingTask?.cancel(); sizingTask = nil
        desiredWorkspaceMode = nil; modeRequestID = nil; lastSentViewport = nil; lastScenePortrait = nil
        stopKeyRepeat()
        activeConnectionID = nil
        connectionHostID = nil
        pendingAction = nil
        restoringWindow = nil
        connection = nil
        connectionTask = nil
    }

    // MARK: Reconnecting

    /// A stream dropped (or an attempt to bring it back failed): try again after a while,
    /// until the policy runs out.
    private func interrupted(_ reason: String) {
        if case .streaming(_, _, let source) = store.state {
            // The Mac ends a workspace with the session that owns it.
            let ownedWorkspace = store.virtualDisplay.report?.workspace?.isOwner == true
            restoring = (source, displayPreferences.displayID(for: connectionHostID), ownedWorkspace)
        }
        // The stream screen stays up, so its orientation won't be reported again.
        let portrait = lastScenePortrait
        connectionEnded()
        lastScenePortrait = portrait
        store.send(.interrupted(reason: reason))
        guard case .reconnecting(let host, _, _, let attempt) = store.state else { return }
        guard let delay = reconnectPolicy.delay(beforeAttempt: attempt) else {
            restoring = nil
            store.send(.disconnected(reason: ReconnectPolicy.gaveUp(on: host.name, reason: reason)))
            return
        }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.reconnect()
        }
    }

    /// Back in front while waiting to reconnect: try now rather than at the end of the wait.
    public func reconnectNow() {
        guard case .reconnecting = store.state, connection == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.reconnect() }
    }

    private func reconnect() async {
        reconnectTask = nil
        guard case .reconnecting(let host, _, _, _) = store.state, connection == nil,
              let peer = host.hostID.flatMap(trustStore.peer(hostID:)) else { return }
        // Away long enough for the lock to come back: Face ID first, as for a new session.
        guard await unlock(host) else { return disconnect() }
        guard case .reconnecting = store.state, connection == nil else { return }
        connect(endpoint: browsed[host.id]?.endpoint, hostID: host.hostID, hostFingerprint: peer.fingerprint, invite: nil)
    }

    /// The first config after reconnecting: the window or display it was showing, or why not.
    private func restoreSession(_ config: StreamConfig) {
        guard let restoring else { return }
        self.restoring = nil
        if restoring.hadWorkspace {
            store.post(notice: "The virtual workspace ended when the connection dropped.")
        } else if let wanted = restoring.displayID, let shown = config.displayID,
                  let display = store.displaySelection.displays.first(where: { $0.id == shown }),
                  display.persistentID != wanted {
            store.post(notice: "The display you were using isn't available. Showing \(display.name).")
        }
        if let window = restoring.window {
            restoringWindow = window
            refreshWindows()
        } else if let host = lastHost {
            store.post(notice: "Reconnected to \(host.name)", kind: .done)
        }
    }

    // MARK: While streaming

    public func send(_ input: InputEvent) {
        if case let .key(code, isDown, modifiers) = input {
            connection?.send(.key(KeyPress(code: code, isDown: isDown, modifiers: modifiers)))
        } else {
            connection?.send(input)
        }
    }

    /// A key on the bar or typed with a sticky modifier: down and straight back up.
    public func tapKey(_ code: UInt16, modifiers: MacModifiers = []) {
        connection?.send(.key(KeyPress(code: code, isDown: true, modifiers: modifiers.rawValue)))
        connection?.send(.key(KeyPress(code: code, isDown: false, modifiers: modifiers.rawValue)))
    }

    /// A hardware keyboard key going down or up. Keys the Mac gets from software don't
    /// auto-repeat, so a held key (an arrow, Delete) repeats from here.
    public func sendKey(_ code: UInt16, isDown: Bool, modifiers: MacModifiers) {
        connection?.send(.key(KeyPress(code: code, isDown: isDown, modifiers: modifiers.rawValue)))
        if isDown, KeyMap.modifier(forMacKey: code) == nil {
            heldKey?.task.cancel()
            let task = Task { [weak self] in
                try? await Task.sleep(for: Self.keyRepeatDelay)
                while !Task.isCancelled {
                    self?.connection?.send(.key(KeyPress(code: code, isDown: true, modifiers: modifiers.rawValue)))
                    try? await Task.sleep(for: Self.keyRepeatInterval)
                }
            }
            heldKey = (code, task)
        } else if !isDown, heldKey?.code == code {
            stopKeyRepeat()
        }
    }

    public static let keyRepeatDelay: Duration = .milliseconds(450)
    public static let keyRepeatInterval: Duration = .milliseconds(40)

    private func stopKeyRepeat() {
        heldKey?.task.cancel()
        heldKey = nil
    }

    /// From the stream's Paste button: the phone's clipboard, for the Mac's.
    /// Puts `item` on a Mac's clipboard: the one being streamed, or `hostID` (else the usual
    /// Mac) over a quick connection of its own.
    public func sendClipboard(_ item: ClipboardItem, to hostID: UUID? = nil) {
        guard item.fitsLimits else {
            store.post(notice: "That's too large to send to the Mac.")
            return
        }
        guard !item.isEmpty else { return }
        let done = item.text != nil ? "Pasted to the clipboard on" : "Image pasted to the clipboard on"
        if case .streaming(let host, _, _) = store.state, let connection, hostID == nil || hostID == host.hostID {
            connection.send(.clipboard(item))
            store.post(notice: "\(done) \(host.name)", kind: .done)
            return
        }
        Task {
            do throws(FilesError) {
                let target = try await quietTarget(hostID)
                do {
                    try await ClientConnection.paste(item, endpoint: target.endpoint, hostFingerprint: target.fingerprint,
                                                     identity: target.identity, deviceName: deviceName, relay: relayServer)
                } catch {
                    throw .failed(ClientConnection.describe(error))
                }
                store.post(notice: "\(done) \(target.name)", kind: .done)
            } catch {
                store.post(notice: String(describing: error))
            }
        }
    }

    /// Copies what's copied on a Mac (`hostID`, else the usual one) onto this iPhone.
    public func copyFromMac(_ hostID: UUID?) {
        Task {
            do throws(FilesError) {
                let target = try await quietTarget(hostID)
                let item: ClipboardItem
                do {
                    item = try await ClientConnection.copy(endpoint: target.endpoint, hostFingerprint: target.fingerprint,
                                                           identity: target.identity, deviceName: deviceName, relay: relayServer)
                } catch {
                    throw .failed(ClientConnection.describe(error))
                }
                pasteboard.write(item)
                store.post(notice: ClipboardItem.copiedNotice(item, from: target.name), kind: .done)
            } catch {
                store.post(notice: String(describing: error))
            }
        }
    }

    /// A Mac to reach without streaming, and how (unlocked first if it's locked).
    private func quietTarget(_ hostID: UUID?) async throws(FilesError)
        -> (name: String, endpoint: NWEndpoint?, fingerprint: Fingerprint, identity: DeviceIdentity) {
        guard let host = shortcutTarget(preferredHostID: hostID), let macID = host.hostID,
              let peer = trustStore.peer(hostID: macID) else { throw .noMac }
        guard await unlock(host) else { throw .locked(host.name) }
        do {
            return (host.name, browsed[host.id]?.endpoint, peer.fingerprint, try DeviceIdentity.loadOrCreate(label: identityLabel))
        } catch {
            throw .failed("Couldn't load this phone's identity: \(error)")
        }
    }

    public func insertText(_ text: String) {
        connection?.send(.insertText(text))
    }

    public func showHostUpdate(_ host: DiscoveredHost) {
        guard host.isPaired else { return }
        Task { if await unlock(host) { store.showHostUpdate(host) } }
    }
    public func dismissHostUpdate() { hostUpdateWatchID = UUID(); store.showHostUpdate(nil) }
    public func watchHostUpdate(_ host: DiscoveredHost, install: Bool) async {
        let watchID = UUID(); hostUpdateWatchID = watchID
        guard let id = host.hostID, let peer = trustStore.peer(hostID: id), await unlock(host) else { return }
        do {
            let identity = try DeviceIdentity.loadOrCreate(label: identityLabel)
            await HostUpdateClient.watch(local: browsed[host.id]?.endpoint, relay: relayServer, identity: identity,
                host: peer.fingerprint, deviceName: deviceName, install: install) { [weak self] status in
                    Task { @MainActor in
                        guard self?.hostUpdateWatchID == watchID, self?.store.hostUpdateTarget?.hostID == id else { return }
                        self?.store.update(hostUpdate: status)
                    }
                }
        } catch { store.update(hostUpdate: .init(phase: .failed, message: error.localizedDescription)) }
    }

    public func refreshDisplays() {
        connection?.send(.listDisplays)
        connection?.send(.watchVirtualDisplay)
    }

#if DEBUG && os(iOS)
    func sampleTraceStatistics() -> StreamStats { connection?.sampleTraceStatistics() ?? StreamStats() }
#endif

    public func createVirtualDisplay() {
        guard case .streaming = store.state, store.virtualDisplay.report?.canCreate == true,
              !store.virtualDisplay.isBusy, let connection else { return }
        var sizing = store.workspaceSizing
        if sizing.followsRotation, let lastScenePortrait { sizing.portrait = lastScenePortrait }
        store.update(workspaceSizing: sizing)
        let request = VirtualDisplayRequest(mode: sizing.mode)
        store.update(virtualDisplay: .requested(request.id))
        connection.send(.createVirtualDisplay(request))
        expireVirtualDisplayRequest(request.id)
    }

    public func setWorkspaceSizing(_ sizing: WorkspaceSizing) {
        var next = sizing
        if next.portrait { next.scale = 2 }
        guard next.mode.isValid else { return }
        if next.followsRotation, let lastScenePortrait { next.portrait = lastScenePortrait }
        store.update(workspaceSizing: next)
        if store.virtualDisplay.report?.workspace?.isOwner == true {
            desiredWorkspaceMode = next.mode
            scheduleWorkspaceUpdate()
        }
    }

    public func sceneViewportChanged(portrait: Bool, viewport: Viewport) {
        guard viewport.isValid else { return }
        let viewportChanged = self.viewport != viewport
        let orientationChanged = lastScenePortrait != portrait
        self.viewport = viewport
        lastScenePortrait = portrait
        guard viewportChanged || orientationChanged else { return }
        var sizing = store.workspaceSizing
        if store.virtualDisplay.report?.workspace?.isOwner == true,
           store.displaySelection.selectedID == store.virtualDisplay.report?.workspace?.displayID,
           sizing.observeOrientation(portrait: portrait) {
            store.update(workspaceSizing: sizing)
            desiredWorkspaceMode = sizing.mode
        }
        scheduleWorkspaceUpdate()
    }

    private func scheduleWorkspaceUpdate() {
        sizingTask?.cancel()
        sizingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self, !Task.isCancelled, case .streaming = self.store.state, let connection = self.connection else { return }
            guard !self.store.virtualDisplay.isBusy else { return } // Latest intent stays queued until acknowledgment.
            if let mode = self.desiredWorkspaceMode, let workspace = self.store.virtualDisplay.report?.workspace, workspace.isOwner,
               mode != workspace.acceptedMode {
                let request = VirtualDisplayConfiguration(leaseID: workspace.leaseID, mode: mode, viewport: self.viewport)
                self.modeRequestID = request.id
                self.store.update(virtualDisplay: .requested(request.id))
                connection.send(.configureVirtualDisplay(request))
                self.lastSentViewport = self.viewport
                self.expireVirtualDisplayRequest(request.id)
            } else {
                self.desiredWorkspaceMode = nil
                if self.lastSentViewport != self.viewport {
                    self.lastSentViewport = self.viewport
                    connection.send(.setViewport(self.viewport))
                }
            }
        }
    }

    public func endVirtualDisplay() {
        guard case .streaming = store.state, !store.virtualDisplay.isBusy,
              let workspace = store.virtualDisplay.report?.workspace, workspace.isOwner, let connection else { return }
        let request = VirtualDisplayEnd(leaseID: workspace.leaseID)
        store.update(virtualDisplay: .requested(request.id))
        connection.send(.endVirtualDisplay(request))
        expireVirtualDisplayRequest(request.id)
    }

    private func expireVirtualDisplayRequest(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.store.virtualDisplay.pendingID == id else { return }
            self.store.update(virtualDisplay: .timedOut(id))
            if self.modeRequestID == id { self.modeRequestID = nil; self.desiredWorkspaceMode = nil }
            self.refreshDisplays()
        }
    }

    public func selectDisplay(_ display: DisplayInfo) {
        guard store.displaySelection.displays.contains(where: { $0.id == display.id }) else { return }
        connection?.send(.selectDisplay(display.id))
    }

    public func refreshWindows() {
        connection?.send(.listWindows)
    }

    /// Keeps the store's `menus` showing the frontmost Mac app's menus, until `stopWatchingMenus`.
    public func watchMenus() {
        guard let connection else { return }
        store.update(menus: .loading)
        connection.send(.watchMenus(true))
    }

    public func stopWatchingMenus() {
        connection?.send(.watchMenus(false))
        store.update(menus: .idle)
    }

    public func press(_ item: MenuItem) {
        guard item.children == nil, !item.isSeparator, item.isEnabled else { return }
        connection?.send(.pressMenuItem(MenuPress(path: item.path, title: item.title)))
    }

    /// `nil` streams the whole display.
    public func selectSource(_ window: WindowInfo?) {
        connection?.send(.selectSource(windowID: window?.id))
        store.send(.sourceChanged(window))
    }

    /// Reconnects to the last Mac after a failure, if it's still around and paired.
    public func retry() {
        disconnectConnection()
        store.send(.cancel)
        startDiscovery()
        guard let hostID = lastHost?.hostID,
              let host = discoveredHosts().first(where: { $0.hostID == hostID && ($0.isOnline || $0.canRelay) && $0.isPaired })
        else { return }
        select(host)
    }

    /// Leaves the current Mac (or pairing attempt) and goes back to the list.
    public func disconnect() {
        pendingAction = nil
        disconnectConnection()
        store.send(.cancel)
        startDiscovery()
    }

    /// What this iPhone knows about a paired Mac's pairing, for its settings page.
    public func pairing(of host: DiscoveredHost) -> MacPairing? {
        guard let peer = host.hostID.flatMap(trustStore.peer(hostID:)) else { return nil }
        return MacPairing(key: peer.fingerprint.description, pairedAt: peer.pairedAt, macName: peer.name)
    }

    /// Shows a paired Mac under another name on this phone; an empty name goes back to the Mac's own.
    public func rename(_ host: DiscoveredHost, to name: String) {
        guard let hostID = host.hostID else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        macNames[hostID] = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
        try? macNames.save(to: macNamesURL)
        store.send(.hostsChanged(discoveredHosts()))
    }

    /// Forgets a Mac; it will need pairing again.
    public func forget(_ host: DiscoveredHost) {
        guard let peer = host.hostID.flatMap(trustStore.peer(hostID:)) else { return }
        if let hostID = peer.hostID ?? host.hostID {
            displayPreferences.forget(hostID)
            wakeBook[hostID] = nil
            macKinds[hostID] = nil
            macNames[hostID] = nil
            lastUsed[hostID] = nil
            wakeAttempts.cancel(hostID)
            try? FileManager.default.removeItem(at: wallpaperURL(hostID))
            locks.forget(hostID)
            try? locks.save(to: locksURL)
            store.update(wallpaper: nil, for: hostID)
        }
        try? displayPreferences.save(to: displayPreferencesURL)
        try? wakeBook.save(to: wakeBookURL)
        try? macKinds.save(to: macKindsURL)
        try? macNames.save(to: macNamesURL)
        try? lastUsed.save(to: lastUsedURL)
        trustStore.revoke(peer.fingerprint)
        try? trustStore.save(to: trustStoreURL)
        store.send(.hostsChanged(discoveredHosts()))
    }

    // MARK: Shortcuts

    /// Every paired Mac, asleep or not: what a shortcut can be set to run on.
    public var pairedMacs: [DiscoveredHost] {
        discoveredHosts().filter { $0.isPaired && $0.hostID != nil }
    }

    /// Paired Macs that are online now, which shortcuts can run on.
    public var reachableMacs: [DiscoveredHost] {
        discoveredHosts().filter { $0.isPaired && ($0.isOnline || $0.canRelay) }
    }

    /// Runs a shortcut on the Mac being streamed, or connects first (to `preferredHostID`, else
    /// the last Mac used, else any paired Mac that's online) and runs it once the picture is up.
    /// Returns `false`, with a notice posted, when there's no Mac to run it on.
    /// A shortcut that asks first asks unless `confirmed` (typing its words counts as saying yes).
    @discardableResult
    public func run(_ shortcut: Shortcut, preferredHostID: UUID? = nil, text: String? = nil, confirmed: Bool = false) -> Bool {
        let preferredHostID = shortcut.macID ?? preferredHostID
        if shortcut.action.asksForText, text == nil {
            store.ask(forTextFor: shortcut, preferredHostID: preferredHostID)
            return true
        }
        if shortcut.confirms, !confirmed, text == nil {
            store.ask(toConfirm: shortcut, preferredHostID: preferredHostID)
            return true
        }
        let action = (text.map(shortcut.action.filling) ?? shortcut.action).fillingClock()
        // One set to run on another Mac goes there, not to the Mac on screen.
        if case .streaming = store.state, let connection, shortcut.macID == nil || shortcut.macID == connectionHostID {
            connection.send(.run(action))
            return true
        }
        // Not queued for after: by then it may not be what the person wants.
        if case .reconnecting(let host, _, _, _) = store.state, shortcut.macID == nil || shortcut.macID == host.hostID {
            store.post(notice: "Reconnecting to \(host.name). Try “\(shortcut.name)” again once it's back.")
            return false
        }
        guard let host = shortcutTarget(preferredHostID: preferredHostID) else {
            store.post(notice: "Open PocketDesk on a paired Mac to run “\(shortcut.name)”.")
            return false
        }
        if locks.needsUnlock(host.hostID) {
            Task { if await unlock(host) { run(shortcut, preferredHostID: host.hostID, text: text, confirmed: true) } }
            return true
        }
        if !shortcut.opensStream {
            // Nothing to look at (Play / Pause, volume, or set so): run it without the stream.
            Task {
                do throws(BackgroundRunError) {
                    // Not by ID: the Mac cards' Play / Pause and volume aren't saved shortcuts.
                    let mac = try await runInBackground(shortcut, preferredHostID: host.hostID, text: text)
                    store.post(notice: "\(shortcut.name): done on \(mac)", kind: .done)
                } catch {
                    store.post(notice: String(describing: error))
                }
            }
            return true
        }
        disconnectConnection()
        store.send(.cancel)
        store.send(.startDiscovery)
        store.send(.hostsChanged(discoveredHosts()))
        select(host)
        pendingAction = action
        return true
    }

    /// Where shortcuts run when not streaming: `preferredHostID`, else the last Mac used, else
    /// any paired Mac that's online.
    public func shortcutTarget(preferredHostID: UUID?) -> DiscoveredHost? {
        let macs = reachableMacs
        return macs.first { $0.hostID != nil && $0.hostID == preferredHostID }
            ?? macs.first { $0.hostID != nil && $0.hostID == lastHost?.hostID }
            ?? macs.first
    }

    // MARK: Live tiles

    /// Keeps the store's `macStatus` current while tiles are on screen: through the stream if
    /// one is up, else over a quiet connection of its own. Retries while it's wanted.
    public func watchStatus(preferredHostID: UUID?, watcher: String = "shortcuts") {
        statusWatchers.insert(watcher)
        statusPreferredHostID = preferredHostID
        if case .streaming = store.state, let connection {
            connection.send(.watchStatus)
            return
        }
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let target = shortcutTarget(preferredHostID: preferredHostID)
                checksWithoutMac = target == nil ? checksWithoutMac + 1 : 0
                // Gone for a couple of checks, not just slow to show up after launch.
                if checksWithoutMac == 2 { present(nowPlaying.macWentAway()) }
                if let host = target, let hostID = host.hostID,
                   let browsedHost = browsed[host.id], let peer = trustStore.peer(hostID: hostID),
                   let identity = try? DeviceIdentity.loadOrCreate(label: identityLabel) {
                    let updates = ClientConnection.watchStatus(endpoint: browsedHost.endpoint, hostFingerprint: peer.fingerprint,
                                                               identity: identity, deviceName: deviceName,
                                                               nowPlayingPush: nowPlayingPush(for: hostID))
                    do {
                        for try await update in updates {
                            switch update {
                            case .status(let status):
                                store.update(macStatus: status)
                                showNowPlaying(status.nowPlaying, from: host)
                            case .latency(let latency): store.update(macLatency: latency)
                            case .wallpaper(let jpeg): save(wallpaper: jpeg, for: hostID)
                            }
                        }
                    } catch {}
                    // Gone: no stale "4 ms" while it reconnects.
                    store.update(macLatency: nil)
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    public func stopWatchingStatus(watcher: String = "shortcuts") {
        statusWatchers.remove(watcher)
        guard statusWatchers.isEmpty else { return }
        statusTask?.cancel()
        statusTask = nil
        checksWithoutMac = 0
        // The Live Activity stays: it's for when the app has left the screen.
        store.update(macStatus: nil)
        store.update(macLatency: nil)
    }

    // MARK: Now Playing Live Activity

    /// Settings › Now Playing changed: the activity starts, ends or redraws to match.
    public func nowPlayingPreferencesChanged() {
        present(nowPlaying.setPreferences(NowPlayingActivityPreferences(defaults: .standard)))
    }

    /// A Lock Screen or Dynamic Island button: play / pause or skip on the Mac the activity is
    /// for, then catch up with what it's playing now (the app may be running in the background
    /// only for this).
    @discardableResult
    public func pressNowPlaying(_ key: MediaKey) async -> Bool {
        let sent = await performNowPlayingControl(key) { (shortcut: Shortcut, hostID: UUID) async throws(BackgroundRunError) -> Void in
            _ = try await self.runInBackground(shortcut, preferredHostID: hostID, allowExistingStream: false)
        }
        if sent, statusTask == nil, let hostID = nowPlaying.hostID { await refreshNowPlaying(hostID) }
        return sent
    }

    /// Wait for cold-launch adoption, bind the action to that activity's Mac, and roll back
    /// exactly on failure. The closure is the same acknowledged one-shot path used by Siri.
    func performNowPlayingControl(_ key: MediaKey,
        run: @MainActor (Shortcut, UUID) async throws(BackgroundRunError) -> Void) async -> Bool {
        await nowPlayingQueue?.value
        let before = nowPlaying
        guard let hostID = before.hostID, let card = before.card else {
            await controlDiagnostics.record("noActivity", control: key)
            return false
        }
        let optimistic = nowPlaying.press(key)
        if optimistic == .end {
            // End-when-paused must wait for success: an ended activity can't be rolled back.
            nowPlaying = before
        } else { present(optimistic) }
        var shortcut = Shortcut(name: "Now Playing", symbol: "playpause.fill", color: .gray,
                                action: .media(key), showsMac: false)
        shortcut.macID = hostID
        await controlDiagnostics.record("sending", control: key)
        do throws(BackgroundRunError) {
            try await run(shortcut, hostID)
            await controlDiagnostics.record("sent", control: key)
            return true
        } catch {
            nowPlaying = before
            present(.update(card))
            await controlDiagnostics.record("failed", control: key, error: error.description)
            return false
        }
    }

    /// Listens to the Mac's status for a moment, long enough for the player to have moved on.
    private func refreshNowPlaying(_ hostID: UUID, for duration: Duration = .seconds(3)) async {
        guard let host = shortcutTarget(preferredHostID: hostID), host.hostID == hostID,
              let peer = trustStore.peer(hostID: hostID),
              let identity = try? DeviceIdentity.loadOrCreate(label: identityLabel) else { return }
        let updates = ClientConnection.watchStatus(endpoint: browsed[host.id]?.endpoint, hostFingerprint: peer.fingerprint,
                                                   identity: identity, deviceName: deviceName, relay: relayServer)
        let reader = Task {
            do {
                for try await case .status(let status) in updates { showNowPlaying(status.nowPlaying, from: host) }
            } catch {}
        }
        try? await Task.sleep(for: duration)
        reader.cancel()
    }

    private func showNowPlaying(_ playing: NowPlaying?, from host: DiscoveredHost) {
        guard nowPlayingPresenter != nil, let hostID = host.hostID else { return }
        lastNowPlaying = (playing, host)
        if let base64 = playing?.artwork, nowPlayingArtwork?.base64 != base64, let jpeg = Data(base64Encoded: base64) {
            nowPlayingArtwork = (base64, NowPlayingArtwork.id(for: jpeg), jpeg, NowPlayingArtwork.averageColor(of: jpeg))
        }
        let artwork = playing?.artwork != nil && nowPlayingArtwork?.base64 == playing?.artwork ? nowPlayingArtwork : nil
        let siteIcon = playing?.site.flatMap { siteIcons[$0] ?? nil }
        if let site = playing?.site, siteIcons.index(forKey: site) == nil {
            if let tint = NowPlayingArtwork.siteTints()[site] { siteIcons[site] = (NowPlayingCard.siteIconID(for: site), tint) }
            else { fetchSiteIcon(site) }
        }
        present(nowPlaying.receive(playing, from: hostID, macName: host.name, artworkID: artwork?.id, tint: artwork?.tint,
                                   siteIconID: siteIcon?.id, siteTint: siteIcon?.tint))
    }

    /// The site's own icon (the same loader website tiles use), then a redraw.
    private func fetchSiteIcon(_ site: String) {
        siteIcons[site] = .some(nil)
        Task {
            guard let data = await FaviconLoader.shared.icon(for: "https://\(site)"),
                  let png = NowPlayingArtwork.icon(from: data) else { return }
            let tint = NowPlayingArtwork.averageColor(of: png)
            guard (try? NowPlayingArtwork.saveSiteIcon(png, tint: tint, for: site)) != nil else { return }
            siteIcons[site] = (NowPlayingCard.siteIconID(for: site), tint)
            if let last = lastNowPlaying, last.playing?.site == site { showNowPlaying(last.playing, from: last.host) }
        }
    }

    private func present(_ step: NowPlayingActivityStep) {
        guard step != .none, let presenter = nowPlayingPresenter else { return }
        let card: NowPlayingCard? = switch step {
        case .start(_, let card), .update(let card), .replace(_, let card): card
        case .none, .end: nil
        }
        var images: [String: Data] = [:]
        if let id = card?.artworkID, id == nowPlayingArtwork?.id { images[id] = nowPlayingArtwork?.jpeg }
        let previous = nowPlayingQueue
        nowPlayingQueue = Task {
            await previous?.value
            await presenter.apply(step, images: images)
        }
    }

    private func adoptNowPlayingActivity() {
        guard let presenter = nowPlayingPresenter else { return }
        let previous = nowPlayingQueue
        nowPlayingQueue = Task {
            await previous?.value
            if let running = await presenter.adopt() { nowPlaying.adopt(hostID: running.hostID, card: running.card) }
            await presenter.watchPushTokens { [weak self] tokens in
                Task { @MainActor in self?.pushTokensChanged(tokens) }
            }
        }
    }

    /// The Mac learns new tokens from a connection's `Hello`: a status watch that's already up
    /// reconnects so it hears them now rather than next time.
    private func pushTokensChanged(_ tokens: NowPlayingPushTokens) {
        guard tokens != nowPlayingPushTokens else { return }
        nowPlayingPushTokens = tokens
        // A card a Mac started by push: follow it, so the app updates it rather than starting another.
        if nowPlaying.card == nil, let showing = tokens.showing { nowPlaying.adopt(hostID: showing.hostID, card: showing.card) }
        guard statusTask != nil else {
            // Woken in the background for a card a Mac started: tell that Mac how to update it.
            if tokens.activity != nil { sendNowPlayingPush(to: tokens.showing?.hostID) }
            return
        }
        statusTask?.cancel()
        statusTask = nil
        if let watcher = statusWatchers.first { watchStatus(preferredHostID: statusPreferredHostID, watcher: watcher) }
    }

    private var pushRegistration: Task<Void, Never>?

    /// A short connection that only says hello, carrying the push tokens, then hangs up.
    private func sendNowPlayingPush(to preferredHostID: UUID?) {
        pushRegistration?.cancel()
        pushRegistration = Task {
            startDiscovery()
            guard let host = await waitForTarget(preferredHostID: preferredHostID ?? lastHost?.hostID, for: .seconds(6)),
                  let hostID = host.hostID, let peer = trustStore.peer(hostID: hostID),
                  let identity = try? DeviceIdentity.loadOrCreate(label: identityLabel), !Task.isCancelled else { return }
            let updates = ClientConnection.watchStatus(endpoint: browsed[host.id]?.endpoint, hostFingerprint: peer.fingerprint,
                                                       identity: identity, deviceName: deviceName, relay: relayServer,
                                                       nowPlayingPush: nowPlayingPush(for: hostID))
            // The Mac has the hello once it answers.
            let reader = Task {
                do { for try await _ in updates { break } } catch {}
            }
            try? await Task.sleep(for: .seconds(4))
            reader.cancel()
        }
    }

    /// What a Mac needs to start and update the activity by push, for its `Hello`. `nil`
    /// (nothing to change) until Apple has issued a token; a withdrawal when it's switched off.
    func nowPlayingPush(for hostID: UUID?) -> NowPlayingPush? {
        guard nowPlayingPresenter != nil, let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let preferences = NowPlayingActivityPreferences(defaults: .standard)
        guard preferences.isEnabled, startsNowPlayingByPush else {
            return NowPlayingPush(startToken: nil, environment: pushEnvironment, bundleID: bundleID, preferences: preferences)
        }
        guard let start = nowPlayingPushTokens.start else { return nil }
        let mine = hostID != nil && nowPlaying.hostID == hostID
        return NowPlayingPush(startToken: start, activityToken: mine ? nowPlayingPushTokens.activity : nil,
                              showing: mine ? nowPlaying.card : nil, environment: pushEnvironment, bundleID: bundleID,
                              preferences: preferences,
                              siteTints: Dictionary(uniqueKeysWithValues: NowPlayingArtwork.siteTints()
                                  .sorted { $0.key < $1.key }.prefix(NowPlayingPush.maxSiteTints).map { ($0.key, $0.value) }))
    }

    // MARK: Locks

    /// Asks for Face ID if `host` is locked and hasn't been unlocked since the app came to
    /// the front. `true` when it may be used.
    public func unlock(_ host: DiscoveredHost) async -> Bool {
        guard let hostID = host.hostID, locks.needsUnlock(hostID) else { return true }
        guard await authenticate("Unlock “\(host.name)”") else { return false }
        locks.unlock(hostID)
        store.send(.hostsChanged(discoveredHosts()))
        return true
    }

    /// Locks or unlocks `host` behind Face ID. Either way asks first: locking proves Face ID
    /// works before it's needed, and unlocking mustn't be open to whoever holds the phone.
    public func setLocked(_ host: DiscoveredHost, _ isLocked: Bool) async {
        guard let hostID = host.hostID, locks.isLocked(hostID) != isLocked else { return }
        let reason = isLocked ? "Lock “\(host.name)”" : "Stop locking “\(host.name)”"
        guard await authenticate(reason) else { return }
        locks.set(hostID, locked: isLocked)
        try? locks.save(to: locksURL)
        store.send(.hostsChanged(discoveredHosts()))
        store.post(notice: isLocked ? "“\(host.name)” is locked. Using it will ask that it's you."
                                    : "“\(host.name)” is no longer locked.", kind: .done)
    }

    /// Locks or unlocks every paired Mac, with one Face ID.
    public func setAllLocked(_ isLocked: Bool) async {
        let macs = trustStore.peers.values.compactMap(\.hostID).filter { locks.isLocked($0) != isLocked }
        guard !macs.isEmpty else { return }
        guard await authenticate(isLocked ? "Lock your Macs" : "Stop locking your Macs") else { return }
        for mac in macs { locks.set(mac, locked: isLocked) }
        try? locks.save(to: locksURL)
        store.send(.hostsChanged(discoveredHosts()))
        store.post(notice: isLocked ? "Your Macs are locked. Using one will ask that it's you."
                                    : "Your Macs are no longer locked.", kind: .done)
    }

    /// How long PocketDesk may be off screen before locked Macs ask again (0: straight away).
    nonisolated public static let relockDelayKey = "relockAfter"
    private var relockDelay: TimeInterval { UserDefaults.standard.double(forKey: Self.relockDelayKey) }

    /// PocketDesk left the screen: locked Macs ask again, now or after the chosen delay.
    public func appLeftScreen() {
        locks.left(at: .now, delay: relockDelay)
        store.send(.hostsChanged(discoveredHosts()))
    }

    /// Back on screen still showing a locked Mac: Face ID again, or the stream ends.
    public func checkLockOnReturn() {
        locks.returned(at: .now, delay: relockDelay)
        store.send(.hostsChanged(discoveredHosts()))
        // The attempt asks for Face ID itself if it's needed.
        if case .reconnecting = store.state { return reconnectNow() }
        guard case .streaming(let host, _, _) = store.state, locks.needsUnlock(host.hostID) else { return }
        Task {
            if await !unlock(host) { disconnect() }
        }
    }

    // MARK: Wallpapers

    private var wallpapersDirectory: URL { cacheDirectory.appending(path: "Wallpapers") }

    private func wallpaperURL(_ hostID: UUID) -> URL {
        wallpapersDirectory.appending(path: "\(hostID.uuidString).jpg")
    }

    /// Kept so a Mac that's asleep or away still looks like itself.
    private func loadWallpapers() {
        let files = (try? FileManager.default.contentsOfDirectory(at: wallpapersDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            guard let hostID = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let jpeg = try? Data(contentsOf: file) else { continue }
            store.update(wallpaper: jpeg, for: hostID)
        }
    }

    private func save(wallpaper jpeg: Data, for hostID: UUID) {
        guard store.wallpapers[hostID] != jpeg else { return }
        store.update(wallpaper: jpeg, for: hostID)
        try? FileManager.default.createDirectory(at: wallpapersDirectory, withIntermediateDirectories: true)
        try? jpeg.write(to: wallpaperURL(hostID), options: .atomic)
    }

    // MARK: The Mac's apps

    /// Shows the target Mac's apps (cached ones straight away), then refreshes them and fetches
    /// missing icons over a short catalog connection, at most every few minutes unless `force`.
    public func loadApps(preferredHostID: UUID?, force: Bool = false) {
        loadCachedIcons(for: library.shortcuts.compactMap(\.appBundleID))
        guard let host = shortcutTarget(preferredHostID: preferredHostID), let hostID = host.hostID,
              let peer = trustStore.peer(hostID: hostID) else {
            store.update(catalogStatus: .unavailable)
            return
        }
        let cached = (try? JSONDecoder().decode([MacApp].self, from: Data(contentsOf: appsURL(hostID)))) ?? []
        store.update(macApps: cached)
        store.update(macShortcuts: (try? JSONDecoder().decode([MacShortcut].self,
                                                              from: Data(contentsOf: macShortcutsURL(hostID)))) ?? [])
        loadCachedIcons(for: cached.map(\.bundleID))

        if !force, let fetched = catalogFetchedAt[hostID], fetched.duration(to: .now) < .seconds(300) { return }
        guard catalogTask == nil else { return }
        let identity: DeviceIdentity
        do {
            identity = try DeviceIdentity.loadOrCreate(label: identityLabel)
        } catch {
            store.update(catalogStatus: .failed("Couldn't load this phone's identity."))
            return
        }
        if cached.isEmpty { store.update(catalogStatus: .loading) }
        let haveIcons = Set(store.appIcons.keys)
        // Shortcut tiles too, in case an app lives outside the usual folders.
        let shortcutApps = library.shortcuts.compactMap(\.appBundleID)
        let updates = ClientConnection.catalog(endpoint: browsed[host.id]?.endpoint, hostFingerprint: peer.fingerprint,
                                               identity: identity, deviceName: deviceName, relay: relayServer) { apps in
            var wanted: [String] = []
            for id in apps.map(\.bundleID) + shortcutApps where !haveIcons.contains(id) && !wanted.contains(id) {
                wanted.append(id)
            }
            return wanted
        }
        catalogTask = Task { [weak self] in
            do {
                for try await update in updates {
                    self?.receive(update, hostID: hostID)
                }
                self?.catalogFetchedAt[hostID] = .now
                self?.store.update(catalogStatus: .loaded)
            } catch {
                guard let self else { return }
                self.store.update(catalogStatus: self.store.macApps.isEmpty
                                  ? .failed(ClientConnection.describe(error)) : .loaded)
            }
            self?.catalogTask = nil
        }
    }

    private func receive(_ update: CatalogUpdate, hostID: UUID) {
        switch update {
        case .apps(let apps):
            store.update(macApps: apps)
            try? FileManager.default.createDirectory(at: appsURL(hostID).deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? JSONEncoder().encode(apps).write(to: appsURL(hostID), options: .atomic)
        case .icon(let bundleID, let png?):
            store.add(icon: png, for: bundleID)
            try? FileManager.default.createDirectory(at: iconURL(bundleID).deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? png.write(to: iconURL(bundleID), options: .atomic)
        case .icon(_, nil):
            break
        case .macShortcuts(let shortcuts):
            store.update(macShortcuts: shortcuts)
            try? JSONEncoder().encode(shortcuts).write(to: macShortcutsURL(hostID), options: .atomic)
        }
    }

    private func loadCachedIcons(for bundleIDs: [String]) {
        for bundleID in bundleIDs where store.appIcons[bundleID] == nil {
            if let png = try? Data(contentsOf: iconURL(bundleID)) { store.add(icon: png, for: bundleID) }
        }
    }

    private func macShortcutsURL(_ hostID: UUID) -> URL {
        cacheDirectory.appending(path: "apps/\(hostID.uuidString)-shortcuts.json")
    }

    private func appsURL(_ hostID: UUID) -> URL {
        cacheDirectory.appending(path: "apps/\(hostID.uuidString).json")
    }

    private func iconURL(_ bundleID: String) -> URL {
        // Bundle IDs are reverse-DNS; keep only filename-safe characters anyway.
        cacheDirectory.appending(path: "app-icons/\(bundleID.filter { $0.isLetter || $0.isNumber || ".-_".contains($0) }).png")
    }

    // MARK: Files

    /// File transfers with a Mac: the stream's when streaming from it (or `hostID` is `nil`),
    /// otherwise a connection of its own, which `close` hangs up.
    public struct FilesLink: Sendable {
        public let files: MacFiles
        public let macName: String
        public let close: @Sendable () -> Void
    }

    public enum FilesError: Error, CustomStringConvertible {
        case noMac
        case failed(String)
        case locked(String)

        public var description: String {
            switch self {
            case .noMac: "None of your Macs is reachable. Open PocketDesk on your Mac, or check it's awake."
            case .locked(let mac): "“\(mac)” stays locked."
            case .failed(let reason): reason
            }
        }
    }

    public func openFiles(on hostID: UUID?) async throws(FilesError) -> FilesLink {
        if case .streaming(let host, _, _) = store.state, let streamFiles, hostID == nil || hostID == host.hostID {
            return FilesLink(files: streamFiles, macName: host.name, close: {})
        }
        guard let host = shortcutTarget(preferredHostID: hostID), let macID = host.hostID,
              let peer = trustStore.peer(hostID: macID) else { throw .noMac }
        guard await unlock(host) else { throw .locked(host.name) }
        let identity: DeviceIdentity
        do { identity = try DeviceIdentity.loadOrCreate(label: identityLabel) } catch {
            throw .failed("Couldn't load this phone's identity: \(error)")
        }
        do {
            let connection = try await ClientConnection.openFiles(endpoint: browsed[host.id]?.endpoint, hostFingerprint: peer.fingerprint,
                                                                  identity: identity, deviceName: deviceName, relay: relayServer)
            return FilesLink(files: connection.files, macName: host.name, close: { connection.close() })
        } catch {
            throw .failed(ClientConnection.describe(error))
        }
    }

    /// Sends files to a Mac's Downloads folder one after another, showing progress in the
    /// store. Returns the names the Mac saved them under.
    @discardableResult
    public func send(_ items: [OutgoingFile], to hostID: UUID?) async throws(FilesError) -> [String] {
        guard !items.isEmpty else { return [] }
        let link = try await openFiles(on: hostID)
        defer { link.close() }
        var saved: [String] = []
        for (index, item) in items.enumerated() {
            let id = UUID()
            store.update(transfer: FileTransferStatus(id: id, name: item.name, macName: link.macName, isUpload: true,
                                                      position: index + 1, count: items.count))
            do {
                for try await progress in await link.files.upload(item.url, name: item.name) {
                    switch progress {
                    case .transferring(let done, let total):
                        store.update(transfer: FileTransferStatus(id: id, name: item.name, macName: link.macName, isUpload: true,
                                                                  position: index + 1, count: items.count, done: done, total: total))
                    case .saved(let name): saved.append(name)
                    case .downloaded: break
                    }
                }
                store.finishTransfer(id)
            } catch {
                store.finishTransfer(id)
                throw .failed("“\(item.name)” didn't reach \(link.macName): \(error)")
            }
        }
        return saved
    }

    /// `send(_:to:)` for buttons: says how it went in a notice.
    public func sendInBackground(_ items: [OutgoingFile], to hostID: UUID?) {
        Task {
            do {
                let saved = try await send(items, to: hostID)
                guard !saved.isEmpty else { return }
                store.post(notice: saved.count == 1 ? "Sent “\(saved[0])” to Downloads on your Mac"
                                                    : "Sent \(saved.count) items to Downloads on your Mac", kind: .done)
            } catch {
                store.post(notice: String(describing: error))
            }
            for item in items where item.isTemporary { try? FileManager.default.removeItem(at: item.url) }
        }
    }

    // MARK: Library

    public func save(_ shortcut: Shortcut) {
        updateLibrary { $0.save(shortcut) }
    }

    public func delete(_ shortcut: Shortcut) {
        updateLibrary { $0.delete(shortcut.id) }
    }

    public func duplicate(_ shortcut: Shortcut) {
        updateLibrary { $0.duplicate(shortcut.id) }
    }

    public func move(_ shortcut: Shortcut.ID, to target: Shortcut.ID) {
        updateLibrary { $0.move(shortcut, to: target) }
    }

    public func reorder(_ ids: [Shortcut.ID]) {
        updateLibrary { $0.reorder(ids) }
    }

    private func updateLibrary(_ change: (inout ShortcutLibrary) -> Void) {
        change(&library)
        try? library.save(to: shortcutsURL)
        store.update(shortcuts: library.shortcuts)
        onShortcutsChanged?()
    }

    // MARK: From outside the app

    public enum BackgroundRunError: Error, CustomStringConvertible {
        case noSuchShortcut
        case noMac
        /// It needs words (a search) and none were given.
        case needsText
        /// Locked behind Face ID, and it wasn't given.
        case locked(String)
        case failed(String)

        public var description: String {
            switch self {
            case .noSuchShortcut: "That shortcut isn't in PocketDesk any more."
            case .noMac: "None of your Macs is reachable. Open PocketDesk on your Mac, or check it's awake."
            case .needsText: "That shortcut needs something to look for."
            case .locked(let mac): "“\(mac)” is locked. Open PocketDesk to unlock it."
            case .failed(let reason): reason
            }
        }
    }

    /// Runs a saved shortcut for Siri, the Shortcuts app or a widget: through the stream if
    /// one is up, otherwise over a short connection with no picture. Waits a few seconds for
    /// the Mac to show up, waking it if this phone knows how. Returns the Mac's name.
    public func runInBackground(_ id: Shortcut.ID, preferredHostID: UUID?,
                                text: String? = nil) async throws(BackgroundRunError) -> String {
        guard let shortcut = library.shortcuts.first(where: { $0.id == id }) else { throw .noSuchShortcut }
        return try await runInBackground(shortcut, preferredHostID: preferredHostID, text: text)
    }

    /// `runInBackground(_:preferredHostID:text:)` for a shortcut that needn't be saved.
    public func runInBackground(_ shortcut: Shortcut, preferredHostID: UUID?,
                                text: String? = nil, allowExistingStream: Bool = true) async throws(BackgroundRunError) -> String {
        let preferredHostID = shortcut.macID ?? preferredHostID
        if shortcut.action.asksForText, text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            throw .needsText
        }
        let action = (text.map(shortcut.action.filling) ?? shortcut.action).fillingClock()
        if allowExistingStream, case .streaming(let host, _, _) = store.state, let connection,
           shortcut.macID == nil || shortcut.macID == host.hostID {
            connection.send(.run(action))
            return host.name
        }

        startDiscovery()
        var host = await waitForTarget(preferredHostID: preferredHostID, for: .seconds(4), exact: shortcut.macID != nil)
        if host == nil, let sleeper = wakeCandidate(preferredHostID: preferredHostID),
           shortcut.macID == nil || sleeper == shortcut.macID, let info = wakeBook[sleeper] {
            for _ in 0..<3 { await Task.detached { WakeSender.wake(info) }.value }
            host = await waitForTarget(preferredHostID: sleeper, for: .seconds(25), exact: shortcut.macID != nil)
        }
        guard let host, let hostID = host.hostID,
              shortcut.macID == nil || hostID == shortcut.macID,
              let peer = trustStore.peer(hostID: hostID) else { throw .noMac }
        guard await unlock(host) else { throw .locked(host.name) }
        do {
            let identity = try DeviceIdentity.loadOrCreate(label: identityLabel)
            try await ClientConnection.perform(action, endpoint: browsed[host.id]?.endpoint,
                                               hostFingerprint: peer.fingerprint, identity: identity,
                                               deviceName: deviceName, relay: relayServer)
        } catch {
            throw .failed(ClientConnection.describe(error))
        }
        return host.name
    }

    private func waitForTarget(preferredHostID: UUID?, for timeout: Duration, exact: Bool = false) async -> DiscoveredHost? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let host = shortcutTarget(preferredHostID: preferredHostID),
               !exact || host.hostID == preferredHostID { return host }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// The paired Mac to wake for a shortcut: the preferred one, else any this phone can wake.
    private func wakeCandidate(preferredHostID: UUID?) -> UUID? {
        if let preferredHostID, wakeBook[preferredHostID] != nil { return preferredHostID }
        return trustStore.peers.values.compactMap(\.hostID).first { wakeBook[$0] != nil }
    }

    private func disconnectConnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        restoring = nil
        restoringWindow = nil
        stopKeyRepeat()
        activeConnectionID = nil
        connectionHostID = nil
        connectionTask?.cancel()
        connectionTask = nil
        connection = nil
    }
}
