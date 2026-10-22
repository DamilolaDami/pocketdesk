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

    private let identityLabel: String
    private let trustStoreURL: URL
    private var trustStore: TrustStore
    private var browsed: [String: BrowsedHost] = [:]
    /// A pasted/scanned invite whose Mac hasn't shown up in discovery yet.
    private var pendingInvite: PairingInvite?
    private var discoveryTask: Task<Void, Never>?
    private var connection: ClientConnection?
    private var connectionTask: Task<Void, Never>?

    public init(identityLabel: String = "com.pocketdesk.phone.identity",
                trustStoreURL: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/paired-macs.json")) {
        self.identityLabel = identityLabel
        self.trustStoreURL = trustStoreURL
        self.trustStore = (try? TrustStore.load(from: trustStoreURL)) ?? TrustStore()
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
        store.send(.hostsChanged(discoveredHosts()))
        if let invite = pendingInvite, let host = hosts.first(where: { $0.hostID == invite.hostID }) {
            pendingInvite = nil
            beginPairing(invite, with: host)
        }
    }

    private func discoveredHosts() -> [DiscoveredHost] {
        browsed.values
            .map { host in
                DiscoveredHost(id: host.id, name: host.name, hostID: host.hostID,
                               isPaired: host.hostID.flatMap(trustStore.peer(hostID:)) != nil)
            }
            .sorted { ($0.isPaired ? 0 : 1, $0.name) < ($1.isPaired ? 0 : 1, $1.name) }
    }

    // MARK: Connecting

    /// Paired Macs connect straight away; unpaired ones show the pairing screen.
    public func select(_ host: DiscoveredHost) {
        store.send(.select(host))
        guard host.isPaired, let browsedHost = browsed[host.id],
              let peer = host.hostID.flatMap(trustStore.peer(hostID:)) else { return }
        connect(to: browsedHost, hostFingerprint: peer.fingerprint, invite: nil)
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
        let connection = ClientConnection(
            identity: identity,
            request: .init(endpoint: host.endpoint, hostFingerprint: hostFingerprint, invite: invite,
                           deviceName: deviceName, viewport: viewport),
            display: display
        ) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
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
        case .streamConfig(let config):
            store.send(.connected(config))
        case .windows(let windows):
            store.update(windows: windows)
        case .ended(let reason):
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

    public func refreshWindows() {
        connection?.send(.listWindows)
    }

    /// `nil` streams the whole display.
    public func selectSource(_ window: WindowInfo?) {
        connection?.send(.selectSource(windowID: window?.id))
        store.send(.sourceChanged(window))
    }

    /// Leaves the current Mac (or pairing attempt) and goes back to the list.
    public func disconnect() {
        disconnectConnection()
        store.send(.cancel)
        startDiscovery()
    }

    /// Forgets a Mac; it will need pairing again.
    public func forget(_ host: DiscoveredHost) {
        guard let peer = host.hostID.flatMap(trustStore.peer(hostID:)) else { return }
        trustStore.revoke(peer.fingerprint)
        try? trustStore.save(to: trustStoreURL)
        store.send(.hostsChanged(discoveredHosts()))
    }

    private func disconnectConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connection = nil
    }
}
