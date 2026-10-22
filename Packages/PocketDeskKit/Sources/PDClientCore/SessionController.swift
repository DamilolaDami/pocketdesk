import Foundation
import PDProtocol
import PDSecurity
import PDTransport

/// Wires discovery, pairing, the trust store and `ClientConnection` to `SessionStore` for the
/// phone app. Views call these methods; state changes go through the store's reducer.
@MainActor
public final class SessionController {
    public let store = SessionStore()
    public let display = VideoDisplay()
    /// Set by the app before connecting (screen size in points + scale, device name).
    public var viewport = Viewport(width: 402, height: 874, scale: 3)
    public var deviceName = "iPhone"

    public var audioEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "streamAudio") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "streamAudio")
            display.setAudioEnabled(newValue)
            connection?.send(.setAudioEnabled(newValue))
        }
    }

    private let displayPreferencesURL: URL
    private var displayPreferences: DisplayPreferences
    private let wakeBookURL: URL
    private var wakeBook: PerMac<WakeInfo>
    private let macKindsURL: URL
    private var macKinds: PerMac<MacKind>
    private var wakeAttempts = WakeAttempts()
    private var wakeTasks: [UUID: Task<Void, Never>] = [:]
    private var connectionHostID: UUID?
    private var activeConnectionID: UUID?

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
    /// A shortcut tapped while not connected: sent once the stream starts.
    private var pendingAction: MacAction?
    private let cacheDirectory: URL
    private var catalogTask: Task<Void, Never>?
    private var catalogFetchedAt: [UUID: ContinuousClock.Instant] = [:]

    public init(identityLabel: String = "com.pocketdesk.phone.identity",
                trustStoreURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/paired-macs.json"),
                shortcutsURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/shortcuts.json"),
                cacheDirectory: URL = URL.cachesDirectory.appending(path: "PocketDesk"),
                displayPreferencesURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/displays.json"),
                wakeBookURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/wake.json"),
                macKindsURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/mac-kinds.json")) {
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
    }

    // MARK: Discovery

    public func startDiscovery() {
        store.send(.startDiscovery)
        guard discoveryTask == nil else {
            store.send(.hostsChanged(discoveredHosts()))
            return
        }
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
    }

    /// Online Macs from Bonjour, plus paired Macs that aren't advertising right now.
    private func discoveredHosts() -> [DiscoveredHost] {
        let online = browsed.values.map { host in
            DiscoveredHost(id: host.id, name: host.name, hostID: host.hostID,
                           isPaired: host.hostID.flatMap(trustStore.peer(hostID:)) != nil, kind: host.kind)
        }
        let onlineIDs = Set(online.compactMap(\.hostID))
        let offline = trustStore.peers.values
            .filter { peer in peer.hostID.map { !onlineIDs.contains($0) } ?? false }
            .map { peer in
                DiscoveredHost(id: "paired-\(peer.fingerprint.description)", name: peer.name, hostID: peer.hostID,
                               isPaired: true, isOnline: false, canWake: wakeBook[peer.hostID] != nil,
                               isWaking: peer.hostID.map(wakeAttempts.waking.contains) ?? false,
                               kind: macKinds[peer.hostID])
            }
        return (online + offline).sorted {
            ($0.isPaired ? 0 : 1, $0.isOnline ? 0 : 1, $0.name) < ($1.isPaired ? 0 : 1, $1.isOnline ? 0 : 1, $1.name)
        }
    }

    // MARK: Connecting

    /// Paired Macs connect straight away; unpaired ones show the pairing screen.
    public func select(_ host: DiscoveredHost) {
        guard host.isOnline else { return }
        lastHost = host
        store.send(.select(host))
        guard host.isPaired, let browsedHost = browsed[host.id],
              let peer = host.hostID.flatMap(trustStore.peer(hostID:)) else { return }
        connect(to: browsedHost, hostFingerprint: peer.fingerprint, invite: nil)
    }

    /// Sends magic packets to a sleeping Mac, then connects as soon as it shows up.
    public func wake(_ host: DiscoveredHost) {
        guard let hostID = host.hostID, !host.isOnline else { return }
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
        connect(to: host, hostFingerprint: invite.hostFingerprint, invite: invite)
    }

    private func connect(to host: BrowsedHost, hostFingerprint: Fingerprint, invite: PairingInvite?) {
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
        connectionHostID = host.hostID ?? invite?.hostID
        let connection = ClientConnection(
            identity: identity,
            request: .init(endpoint: host.endpoint, hostFingerprint: hostFingerprint, invite: invite,
                           deviceName: deviceName, viewport: viewport, audioEnabled: audioEnabled,
                           preferredDisplayID: displayPreferences.displayID(for: connectionHostID)),
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

    private func handle(_ event: ClientEvent) {
        switch event {
        case .awaitingApproval(let code):
            store.send(.pairingCode(code))
        case .paired(let peer):
            trustStore.pin(peer)
            try? trustStore.save(to: trustStoreURL)
            store.send(.pairingConfirmed)
        case .displays(let displays):
            store.update(displays: displays)
        case .wake(let info):
            // A session over a VPN or with Wi-Fi off reports nothing useful; keep the last good one.
            if let hostID = connectionHostID, !info.interfaces.isEmpty, wakeBook[hostID] != info {
                wakeBook[hostID] = info
                try? wakeBook.save(to: wakeBookURL)
            }
        case .streamConfig(let config):
            if config.displayID != nil { store.send(.sourceChanged(nil)) }
            store.send(.connected(config))
            if let displayID = config.displayID, let hostID = connectionHostID,
               let selected = store.displaySelection.displays.first(where: { $0.id == displayID }) {
                displayPreferences.remember(selected.persistentID, for: hostID)
                try? displayPreferences.save(to: displayPreferencesURL)
            }
            if let action = pendingAction {
                pendingAction = nil
                connection?.send(.run(action))
            }
        case .linkQuality(let quality):
            store.update(link: quality)
        case .windows(let windows):
            store.update(windows: windows)
        case .notice(let text):
            store.post(notice: text)
        case .ended(let reason):
            activeConnectionID = nil
            connectionHostID = nil
            pendingAction = nil
            connection = nil
            connectionTask = nil
            store.send(.disconnected(reason: reason))
        }
    }

    // MARK: While streaming

    public func send(_ input: InputEvent) {
        connection?.send(input)
    }

    public func insertText(_ text: String) {
        connection?.send(.insertText(text))
    }

    public func refreshDisplays() { connection?.send(.listDisplays) }

    public func selectDisplay(_ display: DisplayInfo) {
        guard store.displaySelection.displays.contains(where: { $0.id == display.id }) else { return }
        connection?.send(.selectDisplay(display.id))
    }

    public func refreshWindows() {
        connection?.send(.listWindows)
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
              let host = discoveredHosts().first(where: { $0.hostID == hostID && $0.isOnline && $0.isPaired })
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

    /// Forgets a Mac; it will need pairing again.
    public func forget(_ host: DiscoveredHost) {
        guard let peer = host.hostID.flatMap(trustStore.peer(hostID:)) else { return }
        if let hostID = peer.hostID ?? host.hostID {
            displayPreferences.forget(hostID)
            wakeBook[hostID] = nil
            macKinds[hostID] = nil
            wakeAttempts.cancel(hostID)
        }
        try? displayPreferences.save(to: displayPreferencesURL)
        try? wakeBook.save(to: wakeBookURL)
        try? macKinds.save(to: macKindsURL)
        trustStore.revoke(peer.fingerprint)
        try? trustStore.save(to: trustStoreURL)
        store.send(.hostsChanged(discoveredHosts()))
    }

    // MARK: Shortcuts

    /// Paired Macs that are online now, which shortcuts can run on.
    public var reachableMacs: [DiscoveredHost] {
        discoveredHosts().filter { $0.isPaired && $0.isOnline }
    }

    /// Runs a shortcut on the Mac being streamed, or connects first (to `preferredHostID`, else
    /// the last Mac used, else any paired Mac that's online) and runs it once the picture is up.
    /// Returns `false`, with a notice posted, when there's no Mac to run it on.
    @discardableResult
    public func run(_ shortcut: Shortcut, preferredHostID: UUID? = nil) -> Bool {
        if case .streaming = store.state, let connection {
            connection.send(.run(shortcut.action))
            return true
        }
        guard let host = shortcutTarget(preferredHostID: preferredHostID) else {
            store.post(notice: "Open PocketDesk on a paired Mac to run “\(shortcut.name)”.")
            return false
        }
        disconnectConnection()
        store.send(.cancel)
        store.send(.startDiscovery)
        store.send(.hostsChanged(discoveredHosts()))
        select(host)
        pendingAction = shortcut.action
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

    // MARK: The Mac's apps

    /// Shows the target Mac's apps (cached ones straight away), then refreshes them and fetches
    /// missing icons over a short catalog connection, at most every few minutes unless `force`.
    public func loadApps(preferredHostID: UUID?, force: Bool = false) {
        loadCachedIcons(for: library.shortcuts.compactMap(\.appBundleID))
        guard let host = shortcutTarget(preferredHostID: preferredHostID), let hostID = host.hostID,
              let browsedHost = browsed[host.id], let peer = trustStore.peer(hostID: hostID) else {
            store.update(catalogStatus: .unavailable)
            return
        }
        let cached = (try? JSONDecoder().decode([MacApp].self, from: Data(contentsOf: appsURL(hostID)))) ?? []
        store.update(macApps: cached)
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
        let updates = ClientConnection.catalog(endpoint: browsedHost.endpoint, hostFingerprint: peer.fingerprint,
                                               identity: identity, deviceName: deviceName) { apps in
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
        }
    }

    private func loadCachedIcons(for bundleIDs: [String]) {
        for bundleID in bundleIDs where store.appIcons[bundleID] == nil {
            if let png = try? Data(contentsOf: iconURL(bundleID)) { store.add(icon: png, for: bundleID) }
        }
    }

    private func appsURL(_ hostID: UUID) -> URL {
        cacheDirectory.appending(path: "apps/\(hostID.uuidString).json")
    }

    private func iconURL(_ bundleID: String) -> URL {
        // Bundle IDs are reverse-DNS; keep only filename-safe characters anyway.
        cacheDirectory.appending(path: "app-icons/\(bundleID.filter { $0.isLetter || $0.isNumber || ".-_".contains($0) }).png")
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

    private func updateLibrary(_ change: (inout ShortcutLibrary) -> Void) {
        change(&library)
        try? library.save(to: shortcutsURL)
        store.update(shortcuts: library.shortcuts)
    }

    private func disconnectConnection() {
        activeConnectionID = nil
        connectionHostID = nil
        connectionTask?.cancel()
        connectionTask = nil
        connection = nil
    }
}
