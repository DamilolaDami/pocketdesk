import Foundation
import PDProtocol

/// The client's connection lifecycle as a pure state machine. `SessionStore` owns one and
/// feeds it events from the UI and the transport; this type has no side effects so every
/// transition is unit tested.
public enum SessionState: Sendable, Equatable {
    case idle
    case discovering(hosts: [DiscoveredHost])
    /// `code == nil`: waiting for the QR scan or pasted link.
    /// `code != nil`: connected, waiting for the person at the Mac to accept that code.
    case pairing(host: DiscoveredHost, code: String?)
    case connecting(host: DiscoveredHost)
    case streaming(host: DiscoveredHost, config: StreamConfig, source: WindowInfo?)
    /// The stream dropped and attempt `attempt` (from 1) to get it back is waiting or under
    /// way. Keeps the last config and source so the stream screen stays up and the source
    /// can be restored.
    case reconnecting(host: DiscoveredHost, config: StreamConfig, source: WindowInfo?, attempt: Int)
    case failed(message: String)
}

public struct DiscoveredHost: Sendable, Equatable, Identifiable, Hashable {
    /// Bonjour service identity.
    public var id: String
    public var name: String
    /// From the TXT record; matches pairing invites and pinned hosts.
    public var hostID: UUID?
    public var isPaired: Bool
    /// `false` for a paired Mac that isn't advertising right now (asleep, app closed, away).
    public var isOnline: Bool
    /// Relay is configured on this phone; availability is checked when connecting.
    public var canRelay = false
    /// This phone knows how to wake it (it's connected before); what matters once it's offline.
    public var canWake: Bool
    /// Magic packets sent; it connects as soon as it shows up.
    public var isWaking: Bool
    /// For drawing the right Mac; `nil` for Macs that don't say.
    public var kind: MacKind?
    /// Which side needs updating before they can connect; `nil` when they speak the same
    /// protocol (or the Mac doesn't say).
    public var needsUpdate: Side?
    /// When this phone last streamed from it.
    public var lastUsed: Date?
    /// Locked behind Face ID on this iPhone.
    public var isLocked = false
    /// Locked, and not unlocked since PocketDesk came to the front: using it asks first.
    public var needsUnlock = false

    public enum Side: Sendable, Hashable {
        case mac, phone

        /// Compares the protocol a Mac advertises with this app's.
        public init?(macVersion: UInt16?, phoneVersion: UInt16 = protocolVersion) {
            guard let macVersion, macVersion != phoneVersion else { return nil }
            self = macVersion < phoneVersion ? .mac : .phone
        }
    }

    public init(id: String, name: String, hostID: UUID? = nil, isPaired: Bool, isOnline: Bool = true,
                canWake: Bool = false, isWaking: Bool = false, kind: MacKind? = nil, needsUpdate: Side? = nil,
                lastUsed: Date? = nil) {
        self.needsUpdate = needsUpdate
        self.lastUsed = lastUsed
        self.id = id
        self.name = name
        self.hostID = hostID
        self.isPaired = isPaired
        self.isOnline = isOnline
        self.canWake = canWake
        self.isWaking = isWaking
        self.kind = kind
    }
}

extension DiscoveredHost {
    /// The Macs tab's order: paired first, online first, most recently used first, then by name.
    public static func ordered(_ hosts: [DiscoveredHost]) -> [DiscoveredHost] {
        hosts.sorted { a, b in
            let keyA = (a.isPaired ? 0 : 1, a.isOnline ? 0 : 1), keyB = (b.isPaired ? 0 : 1, b.isOnline ? 0 : 1)
            if keyA != keyB { return keyA < keyB }
            if a.lastUsed != b.lastUsed { return (a.lastUsed ?? .distantPast) > (b.lastUsed ?? .distantPast) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

public enum SessionEvent: Sendable, Equatable {
    case startDiscovery
    case hostsChanged([DiscoveredHost])
    case select(DiscoveredHost)
    case pairingCode(String)
    case pairingConfirmed
    /// The host sent a stream config: the first one starts streaming, later ones update it.
    case connected(StreamConfig)
    case sourceChanged(WindowInfo?)
    case disconnected(reason: String?)
    /// The connection dropped for a reason that may pass (the network, the Mac asleep).
    case interrupted(reason: String)
    case cancel
}

extension SessionState {
    public func reduce(_ event: SessionEvent) -> SessionState {
        switch (self, event) {
        case (_, .cancel):
            return .idle

        case (.idle, .startDiscovery), (.failed, .startDiscovery):
            return .discovering(hosts: [])

        case (.discovering, .hostsChanged(let hosts)):
            return .discovering(hosts: hosts)

        case (.discovering, .select(let host)):
            return host.isPaired ? .connecting(host: host) : .pairing(host: host, code: nil)

        case (.pairing(let host, _), .pairingCode(let code)):
            return .pairing(host: host, code: code)

        case (.pairing(let host, .some), .pairingConfirmed):
            var paired = host
            paired.isPaired = true
            return .connecting(host: paired)

        case (.connecting(let host), .connected(let config)):
            return .streaming(host: host, config: config, source: nil)

        case (.streaming(let host, _, let source), .connected(let config)):
            return .streaming(host: host, config: config, source: source)

        case (.streaming(let host, let config, _), .sourceChanged(let source)):
            return .streaming(host: host, config: config, source: source)

        case (.connecting, .disconnected(let reason)), (.streaming, .disconnected(let reason)),
             (.pairing, .disconnected(let reason)), (.reconnecting, .disconnected(let reason)):
            return .failed(message: reason ?? "Disconnected")

        case (.streaming(let host, let config, let source), .interrupted):
            return .reconnecting(host: host, config: config, source: source, attempt: 1)

        case (.reconnecting(let host, let config, let source, let attempt), .interrupted):
            return .reconnecting(host: host, config: config, source: source, attempt: attempt + 1)

        // Only a session that was streaming comes back by itself; a first connection says why.
        case (.connecting, .interrupted(let reason)), (.pairing, .interrupted(let reason)):
            return .failed(message: reason)

        // The Mac starts on a display; the controller asks for the window again.
        case (.reconnecting(let host, _, _, _), .connected(let config)):
            return .streaming(host: host, config: config, source: nil)

        default:
            return self
        }
    }
}

/// How often, and for how long, a dropped stream tries to come back before giving up.
public struct ReconnectPolicy: Sendable, Equatable {
    /// Waits before each attempt; one entry per attempt.
    public var delays: [Duration]

    public init(delays: [Duration] = [0.5, 1, 2, 4, 8, 8].map(Duration.seconds)) {
        self.delays = delays
    }

    /// The wait before attempt `attempt` (from 1), or `nil` once the attempts are used up.
    public func delay(beforeAttempt attempt: Int) -> Duration? {
        delays.indices.contains(attempt - 1) ? delays[attempt - 1] : nil
    }

    /// What the failure screen says after the last attempt.
    public static func gaveUp(on hostName: String, reason: String) -> String {
        "Couldn't reconnect to \(hostName). \(reason)"
    }
}
