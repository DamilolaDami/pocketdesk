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
    /// Follows Low Power Mode, which switches the stream to Battery Saver.
    private var powerStateTask: Task<Void, Never>?
    /// Screens showing live status (the Macs tab, the Shortcuts tab): it stops when none are.
    private var statusWatchers: Set<String> = []

    public init(identityLabel: String = "com.pocketdesk.phone.identity",
                trustStoreURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/paired-macs.json"),
                shortcutsURL: URL = ShortcutLibrary.sharedURL,
                cacheDirectory: URL = URL.cachesDirectory.appending(path: "PocketDesk"),
                displayPreferencesURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/displays.json"),
                wakeBookURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/wake.json"),
                macKindsURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/mac-kinds.json"),
                macNamesURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/mac-names.json"),
                lastUsedURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/last-used.json")) {
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
        powerStateTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSProcessInfoPowerStateDidChange) {
                self?.qualityChanged()
            }
        }
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
                           isPaired: host.hostID.flatMap(trustStore.peer(hostID:)) != nil, kind: host.kind,
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
        return DiscoveredHost.ordered(online + offline)
    }

    // MARK: Connecting

    /// Paired Macs connect straight away; unpaired ones show the pairing screen.
    public func select(_ host: DiscoveredHost) {
        guard host.isOnline else { return }
        if let side = host.needsUpdate {
            store.post(notice: side == .mac ? "Update PocketDesk on \(host.name) to use it from this iPhone."
                                            : "Update PocketDesk on this iPhone to use \(host.name).")
            return
        }
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
                           preferredDisplayID: displayPreferences.displayID(for: connectionHostID),
                           clipboardEnabled: clipboardEnabled, quality: quality),
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
            if let hostID = connectionHostID {
                lastUsed[hostID] = .now
                try? lastUsed.save(to: lastUsedURL)
            }
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
        case .clipboard(let item):
            guard clipboardEnabled else { return }
            pasteboard.write(item)
            store.post(notice: item.text != nil ? "Copied from your Mac" : "Image copied from your Mac", kind: .done)
        case .windows(let windows):
            store.update(windows: windows)
        case .menuBar(let bar):
            store.update(menus: bar.map(MenusState.ready) ?? .unavailable)
        case .macStatus(let status):
            store.update(macStatus: status)
        case .notice(let text):
            store.post(notice: text)
        case .ended(let reason):
            stopKeyRepeat()
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
    public func sendClipboard(_ item: ClipboardItem) {
        guard item.fitsLimits else {
            store.post(notice: "That's too large to send to the Mac.")
            return
        }
        guard !item.isEmpty else { return }
        connection?.send(.clipboard(item))
        store.post(notice: item.text != nil ? "Pasted to your Mac's clipboard" : "Image sent to your Mac's clipboard",
                   kind: .done)
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

    /// Paired Macs that are online now, which shortcuts can run on.
    public var reachableMacs: [DiscoveredHost] {
        discoveredHosts().filter { $0.isPaired && $0.isOnline }
    }

    /// Runs a shortcut on the Mac being streamed, or connects first (to `preferredHostID`, else
    /// the last Mac used, else any paired Mac that's online) and runs it once the picture is up.
    /// Returns `false`, with a notice posted, when there's no Mac to run it on.
    @discardableResult
    public func run(_ shortcut: Shortcut, preferredHostID: UUID? = nil, text: String? = nil) -> Bool {
        if shortcut.action.asksForText, text == nil {
            store.ask(forTextFor: shortcut, preferredHostID: preferredHostID)
            return true
        }
        let action = text.map(shortcut.action.filling) ?? shortcut.action
        if case .streaming = store.state, let connection {
            connection.send(.run(action))
            return true
        }
        guard let host = shortcutTarget(preferredHostID: preferredHostID) else {
            store.post(notice: "Open PocketDesk on a paired Mac to run “\(shortcut.name)”.")
            return false
        }
        if !shortcut.opensStream {
            // Nothing to look at (Play / Pause, volume, or set so): run it without the stream.
            Task {
                do throws(BackgroundRunError) {
                    let mac = try await runInBackground(shortcut.id, preferredHostID: host.hostID, text: text)
                    store.post(notice: "\(shortcut.name): done on \(mac)", kind: .done)
                } catch {
                    store.post(notice: error.description)
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
        if case .streaming = store.state, let connection {
            connection.send(.watchStatus)
            return
        }
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let host = shortcutTarget(preferredHostID: preferredHostID), let hostID = host.hostID,
                   let browsedHost = browsed[host.id], let peer = trustStore.peer(hostID: hostID),
                   let identity = try? DeviceIdentity.loadOrCreate(label: identityLabel) {
                    let updates = ClientConnection.watchStatus(endpoint: browsedHost.endpoint, hostFingerprint: peer.fingerprint,
                                                               identity: identity, deviceName: deviceName)
                    do {
                        for try await status in updates { store.update(macStatus: status) }
                    } catch {}
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
        store.update(macStatus: nil)
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
        case failed(String)

        public var description: String {
            switch self {
            case .noSuchShortcut: "That shortcut isn't in PocketDesk any more."
            case .noMac: "None of your Macs is reachable. Open PocketDesk on your Mac, or check it's awake."
            case .needsText: "That shortcut needs something to look for."
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
        if shortcut.action.asksForText, text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            throw .needsText
        }
        let action = text.map(shortcut.action.filling) ?? shortcut.action
        if case .streaming(let host, _, _) = store.state, let connection {
            connection.send(.run(action))
            return host.name
        }

        startDiscovery()
        var host = await waitForTarget(preferredHostID: preferredHostID, for: .seconds(4))
        if host == nil, let sleeper = wakeCandidate(preferredHostID: preferredHostID),
           let info = wakeBook[sleeper] {
            for _ in 0..<3 { await Task.detached { WakeSender.wake(info) }.value }
            host = await waitForTarget(preferredHostID: sleeper, for: .seconds(25))
        }
        guard let host, let hostID = host.hostID, let browsedHost = browsed[host.id],
              let peer = trustStore.peer(hostID: hostID) else { throw .noMac }
        do {
            let identity = try DeviceIdentity.loadOrCreate(label: identityLabel)
            try await ClientConnection.perform(action, endpoint: browsedHost.endpoint,
                                               hostFingerprint: peer.fingerprint, identity: identity,
                                               deviceName: deviceName)
        } catch {
            throw .failed(ClientConnection.describe(error))
        }
        return host.name
    }

    private func waitForTarget(preferredHostID: UUID?, for timeout: Duration) async -> DiscoveredHost? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let host = shortcutTarget(preferredHostID: preferredHostID) { return host }
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
        stopKeyRepeat()
        activeConnectionID = nil
        connectionHostID = nil
        connectionTask?.cancel()
        connectionTask = nil
        connection = nil
    }
}
