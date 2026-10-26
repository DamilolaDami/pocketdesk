#if os(macOS)
import CryptoKit
import Foundation
import PDSecurity

public struct VirtualDisplayMode: Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    public var scale: Int
    public var refreshRate: Int
    public init(width: Int, height: Int, scale: Int = 1, refreshRate: Int = 60) {
        self.width = width; self.height = height; self.scale = scale; self.refreshRate = refreshRate
    }
    public static let standard = Self(width: 1280, height: 800)
    public var isValid: Bool {
        self == .standard
    }
}

public struct VirtualDisplayResource: Sendable, Equatable {
    public let id: UUID
    public let displayID: UInt32
    public init(id: UUID = UUID(), displayID: UInt32) { self.id = id; self.displayID = displayID }
}

/// A backend must roll back partial creation before throwing, and retain ownership on a
/// failed removal so cleanup can be retried. No operation may remove an unowned display.
public protocol VirtualDisplayBackend: Sendable {
    func unavailableReason() async -> String?
    func create(logicalID: String, mode: VirtualDisplayMode) async throws -> VirtualDisplayResource
    func destroy(_ resource: VirtualDisplayResource) async throws
}

/// A failed creation whose rollback still needs attention must return its owned resource,
/// so it stays visible/retryable rather than becoming an untracked display.
public struct VirtualDisplayCreationFailure: Error, Sendable {
    public let resource: VirtualDisplayResource
    public init(resource: VirtualDisplayResource) { self.resource = resource }
}

public enum VirtualDisplayError: Error, Sendable, Equatable, CustomStringConvertible {
    case disabled, unavailable(String), notViewing, busy, invalidMode, cancelled, cleanupFailed
    public var description: String {
        switch self {
        case .disabled: "Allow Virtual Displays in PocketDesk's Mac menu first."
        case .unavailable(let reason): reason
        case .notViewing: "That viewing session has ended. Connect to this Mac again."
        case .busy: "This Mac already has a virtual display or is finishing another request."
        case .invalidMode: "Choose the tested 1280×800, 1× display at 60 Hz."
        case .cancelled: "The virtual display request was cancelled."
        case .cleanupFailed: "The virtual display couldn't be removed yet. End it again, or quit PocketDesk."
        }
    }
}

public struct VirtualDisplayState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case idle, creating, active, ending, cleanupFailed }
    public struct Viewer: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let peer: Fingerprint
        public let name: String
        public let connectedAt: Date
    }
    public struct Lease: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let owner: Viewer
        public let logicalID: String
        public let displayID: UInt32
        public let mode: VirtualDisplayMode
    }
    public var revision: UInt64 = 0
    public var enabled = false
    public var available = false
    public var unavailableReason: String? = "Checking compatibility…"
    public var phase: Phase = .idle
    public var viewers: [Viewer] = []
    public var active: Lease?
    public var error: String?
    public var suspended = false
    public init() {}
}

/// One ephemeral workspace. An operation reservation stays occupied across backend awaits;
/// revocation/cancellation can invalidate it, but no second creation can overtake its cleanup.
public actor VirtualDisplayService {
    public static let enabledKey = "PocketDesk.allowVirtualDisplays"
    private let hostID: UUID
    private let backend: any VirtualDisplayBackend
    private let onChange: @Sendable (VirtualDisplayState) -> Void
    private var beforeRemoval: @Sendable (UInt32) async -> Void = { _ in }
    private var state = VirtualDisplayState()
    private var operation: UUID?
    private var pendingOwner: UUID?
    private var pendingCancelled = false
    private var owned: (lease: VirtualDisplayState.Lease, resource: VirtualDisplayResource)?
    private var started = false
    private var stopped = false
    private var revokedPeers: Set<Fingerprint> = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    public init(hostID: UUID, enabled: Bool = false, backend: any VirtualDisplayBackend = RuntimeVirtualDisplayBackend(),
                onChange: @escaping @Sendable (VirtualDisplayState) -> Void = { _ in }) {
        self.hostID = hostID; self.backend = backend; self.onChange = onChange
        state.enabled = enabled
    }

    public func start() async {
        guard !started, !stopped else { return }
        started = true
        let reason = await backend.unavailableReason()
        state.available = reason == nil
        state.unavailableReason = reason
        publish()
    }

    func setBeforeRemoval(_ callback: @escaping @Sendable (UInt32) async -> Void) { beforeRemoval = callback }

    /// Only HostSession's authenticated, approved, successfully streaming path registers.
    func registerViewingSession(id: UUID, peer: Fingerprint, name: String) {
        guard !stopped, !revokedPeers.contains(peer) else { return }
        state.viewers.removeAll { $0.id == id }
        state.viewers.append(.init(id: id, peer: peer, name: name, connectedAt: Date()))
        publish()
    }

    func unregisterViewingSession(_ id: UUID) async {
        state.viewers.removeAll { $0.id == id }
        if pendingOwner == id { pendingCancelled = true }
        publish()
        if owned?.lease.owner.id == id { await endNow() }
    }

    func revoke(_ peer: Fingerprint) async {
        revokedPeers.insert(peer)
        let ids = state.viewers.filter { $0.peer == peer }.map(\.id)
        for id in ids { await unregisterViewingSession(id) }
    }

    func allowPeer(_ peer: Fingerprint) { revokedPeers.remove(peer) }

    public func setEnabled(_ enabled: Bool) async {
        state.enabled = enabled
        state.error = nil
        publish()
        if !enabled { await endNow() }
    }

    public func create(for ownerID: UUID, mode: VirtualDisplayMode = .standard) async throws -> VirtualDisplayState.Lease {
        guard !stopped, !state.suspended, state.enabled else { throw VirtualDisplayError.disabled }
        guard state.available else { throw VirtualDisplayError.unavailable(state.unavailableReason ?? "Virtual displays are unavailable.") }
        guard let owner = state.viewers.first(where: { $0.id == ownerID }) else { throw VirtualDisplayError.notViewing }
        guard mode.isValid else { throw VirtualDisplayError.invalidMode }
        guard operation == nil, owned == nil else { throw VirtualDisplayError.busy }
        try Task.checkCancellation()
        let request = UUID()
        operation = request; pendingOwner = ownerID; pendingCancelled = false
        state.phase = .creating; state.error = nil
        publish()
        do {
            let logicalID = Self.logicalID(hostID: hostID, peer: owner.peer)
            let resource = try await backend.create(logicalID: logicalID, mode: mode)
            let lease = VirtualDisplayState.Lease(id: UUID(), owner: owner, logicalID: logicalID,
                                                 displayID: resource.displayID, mode: mode)
            owned = (lease, resource)
            if Task.isCancelled || pendingCancelled || stopped || state.suspended || !state.enabled
                || !state.viewers.contains(where: { $0.id == ownerID && $0.peer == owner.peer }) {
                await releaseOwned(operation: request)
                throw VirtualDisplayError.cancelled
            }
            operation = nil; pendingOwner = nil
            state.active = lease; state.phase = .active
            publish()
            return lease
        } catch {
            if let partial = error as? VirtualDisplayCreationFailure, owned == nil {
                let lease = VirtualDisplayState.Lease(id: UUID(), owner: owner,
                    logicalID: Self.logicalID(hostID: hostID, peer: owner.peer), displayID: partial.resource.displayID, mode: mode)
                owned = (lease, partial.resource)
                operation = nil; pendingOwner = nil
                state.active = lease; state.phase = .cleanupFailed
                state.error = VirtualDisplayError.cleanupFailed.description
                publish()
            }
            if owned == nil {
                operation = nil; pendingOwner = nil
                state.phase = .idle
                state.error = (error is CancellationError || (error as? VirtualDisplayError) == .cancelled) ? nil : String(describing: error)
                publish()
            }
            throw error
        }
    }

    /// A lease token, never a capture ID, authorizes release. A delayed old cleanup is a no-op.
    public func end(_ leaseID: UUID) async {
        guard owned?.lease.id == leaseID else { return }
        await endNow()
    }

    public func endNow() async {
        if operation != nil { pendingCancelled = true; return }
        guard owned != nil else { return }
        let request = UUID()
        operation = request
        await releaseOwned(operation: request)
    }

    private func releaseOwned(operation request: UUID) async {
        guard let owned else { return }
        state.phase = .ending; state.active = owned.lease
        publish()
        await beforeRemoval(owned.resource.displayID)
        do {
            try await backend.destroy(owned.resource)
            self.owned = nil
            state.active = nil; state.phase = .idle; state.error = nil
        } catch {
            // Keep the resource and block creation until a later explicit cleanup succeeds.
            state.phase = .cleanupFailed; state.error = VirtualDisplayError.cleanupFailed.description
        }
        if operation == request { operation = nil; pendingOwner = nil }
        publish()
    }

    func canView(displayID: UInt32, sessionID: UUID) -> Bool {
        guard let owned, owned.resource.displayID == displayID else { return true }
        return state.phase == .active && owned.lease.owner.id == sessionID
    }

    func suspend(_ suspended: Bool) async {
        state.suspended = suspended
        publish()
        if suspended { await endNow() }
    }

    public func shutdown() async {
        stopped = true
        state.viewers = []
        await endNow()
        if operation != nil {
            await withCheckedContinuation { finishWaiters.append($0) }
        }
        publish()
    }

    public func snapshot() -> VirtualDisplayState { state }

    func reportRequestError(_ message: String) {
        guard state.enabled, state.phase == .idle || state.phase == .active else { return }
        state.error = message
        publish()
    }

    static func logicalID(hostID: UUID, peer: Fingerprint) -> String {
        let digest = SHA256.hash(data: Data("\(hostID.uuidString):\(peer.description)".utf8))
        return "pocketdesk-virtual-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func publish() {
        state.revision &+= 1
        onChange(state)
        if operation == nil {
            let waiters = finishWaiters
            finishWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }
}
#endif
