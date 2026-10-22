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

    public init(id: String, name: String, hostID: UUID? = nil, isPaired: Bool, isOnline: Bool = true) {
        self.id = id
        self.name = name
        self.hostID = hostID
        self.isPaired = isPaired
        self.isOnline = isOnline
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
             (.pairing, .disconnected(let reason)):
            return .failed(message: reason ?? "Disconnected")

        default:
            return self
        }
    }
}
