#if os(macOS)
import Observation
import PDProtocol
import PDSecurity

/// What the Mac's menu bar UI shows. Pure: `reduce` is the only way it changes.
public struct HostState: Sendable, Equatable {
    public enum Listening: Sendable, Equatable {
        case starting
        case listening(port: UInt16?)
        case stopped(error: String?)
    }

    public struct ConnectedPhone: Sendable, Equatable, Identifiable {
        public var id: Fingerprint
        public var deviceName: String
        public var stream: StreamConfig?
        public var window: WindowInfo?
    }

    public var relayStatus: HostRelayStatus = .disabled
    public var keepAwake = KeepAwakeState()
    public var listening: Listening = .starting
    public var invite: PairingInvite?
    /// Oldest first; the UI shows the first.
    public var pendingApprovals: [PairingApproval] = []
    public var pairedPeers: [PairedPeer] = []
    public var connected: [ConnectedPhone] = []

    public init() {}

    public func reduce(_ event: HostEvent) -> HostState {
        var next = self
        switch event {
        case .keepAwakeChanged(let state): next.keepAwake = state
        case .relayStatus(let status): next.relayStatus = status
        case .listening(let port):
            next.listening = .listening(port: port)
        case .stopped(let error):
            next.listening = .stopped(error: error)
            next.connected = []
            next.pendingApprovals = []
        case .inviteChanged(let invite):
            next.invite = invite
        case .approvalRequested(let approval):
            next.pendingApprovals.append(approval)
        case .approvalResolved(let id):
            next.pendingApprovals.removeAll { $0.id == id }
        case .pairedPeersChanged(let peers):
            next.pairedPeers = peers.sorted { $0.pairedAt < $1.pairedAt }
        case .sessionStarted(let peer, let deviceName):
            next.connected.removeAll { $0.id == peer }
            next.connected.append(ConnectedPhone(id: peer, deviceName: deviceName))
        case .sessionStreaming(let peer, let config, let window):
            if let index = next.connected.firstIndex(where: { $0.id == peer }) {
                next.connected[index].stream = config
                next.connected[index].window = window
            }
        case .sessionEnded(let peer):
            next.connected.removeAll { $0.id == peer }
        case .fileReceived:
            // A notification says so; the menu has nothing to show for it.
            break
        }
        return next
    }
}

/// The Mac app's single observable. `HostService` events come in through `send`.
@MainActor
@Observable
public final class HostStore {
    public private(set) var state = HostState()

    public init() {}

    public func send(_ event: HostEvent) {
        state = state.reduce(event)
    }
}
#endif
