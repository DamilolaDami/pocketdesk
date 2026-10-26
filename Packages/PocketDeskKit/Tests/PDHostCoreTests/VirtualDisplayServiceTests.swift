#if os(macOS)
import Foundation
import Synchronization
import Testing
import PDSecurity
import PDProtocol
@testable import PDHostCore

@Suite(.timeLimit(.minutes(1)))
struct VirtualDisplayServiceTests {
    let peer = Fingerprint(bytes: Data(repeating: 4, count: 32))
    let hostID = UUID()

    func setup(_ backend: FakeDisplayBackend, enabled: Bool = true) async -> (VirtualDisplayService, UUID) {
        let service = VirtualDisplayService(hostID: hostID, enabled: enabled, backend: backend)
        await service.start()
        let owner = UUID()
        await service.registerViewingSession(id: owner, peer: peer, name: "Phone")
        return (service, owner)
    }

    @Test func permissionViewingAndModeAreRequiredBeforeAnyAllocation() async throws {
        let backend = FakeDisplayBackend()
        let (service, owner) = await setup(backend, enabled: false)
        await #expect(throws: VirtualDisplayError.disabled) { try await service.create(for: owner) }
        await service.setEnabled(true)
        await #expect(throws: VirtualDisplayError.notViewing) { try await service.create(for: UUID()) }
        for mode in [VirtualDisplayMode(width: 1920, height: 1080), VirtualDisplayMode(width: 4096, height: 2160), .init(width: 1280, height: 800, scale: 2),
                     .init(width: 1280, height: 800, refreshRate: 120)] {
            await #expect(throws: VirtualDisplayError.invalidMode) { try await service.create(for: owner, mode: mode) }
        }
        #expect(await backend.createdCount == 0)
        // Registration/permission by themselves never create a workspace.
        #expect(await service.snapshot().active == nil)
    }

    @Test func revokedPeerCannotReregisterUntilExplicitlyPairedAgain() async throws {
        let backend = FakeDisplayBackend()
        let (service, owner) = await setup(backend)
        await service.revoke(peer)
        await service.registerViewingSession(id: owner, peer: peer, name: "Late connection")
        await #expect(throws: VirtualDisplayError.notViewing) { try await service.create(for: owner) }
        await service.allowPeer(peer)
        await service.registerViewingSession(id: owner, peer: peer, name: "Paired again")
        _ = try await service.create(for: owner)
        await service.shutdown()
        #expect(await backend.removedCount == 1)
    }

    @Test func oldLeasesAndOldConnectionsCannotRemoveANewerDisplay() async throws {
        let backend = FakeDisplayBackend()
        let (service, firstOwner) = await setup(backend)
        let first = try await service.create(for: firstOwner)
        await service.end(first.id)
        let nextOwner = UUID()
        await service.registerViewingSession(id: nextOwner, peer: peer, name: "Same phone, new connection")
        let next = try await service.create(for: nextOwner)
        #expect(first.logicalID == next.logicalID)
        #expect(first.id != next.id)
        #expect(first.displayID == next.displayID) // Deliberately simulate capture ID reuse.
        await service.end(first.id)
        await service.unregisterViewingSession(firstOwner)
        #expect(await service.snapshot().active?.id == next.id)
        #expect(await backend.removedCount == 1)
        await service.shutdown()
        #expect(await backend.removedCount == 2)
    }

    enum Interruption: CaseIterable, Sendable { case disable, disconnect, revoke, cancellation, shutdown }
    @Test(arguments: Interruption.allCases)
    func lateCreationIsRolledBackAfterInterruption(_ reason: Interruption) async throws {
        let backend = FakeDisplayBackend(blockCreate: true)
        let (service, owner) = await setup(backend)
        let request = Task { try await service.create(for: owner) }
        try await waitFor { await backend.waitingForCreate }
        var shutdown: Task<Void, Never>?
        switch reason {
        case .disable: await service.setEnabled(false)
        case .disconnect: await service.unregisterViewingSession(owner)
        case .revoke: await service.revoke(peer)
        case .cancellation: request.cancel()
        case .shutdown:
            shutdown = Task { await service.shutdown() }
            try await waitFor { await service.snapshot().viewers.isEmpty }
        }
        await backend.completeCreate()
        await #expect(throws: VirtualDisplayError.cancelled) { try await request.value }
        await shutdown?.value
        #expect(await backend.removedCount == 1)
        #expect(await service.snapshot().active == nil)
        #expect(await service.snapshot().phase == .idle)
    }

    @Test func overlappingCreationAndRemovalCannotOvertakeEachOther() async throws {
        let backend = FakeDisplayBackend(blockCreate: true)
        let (service, owner) = await setup(backend)
        let request = Task { try await service.create(for: owner) }
        try await waitFor { await backend.waitingForCreate }
        await #expect(throws: VirtualDisplayError.busy) { try await service.create(for: owner) }
        await backend.completeCreate()
        let lease = try await request.value
        await backend.setBlockDestroy(true)
        let ending = Task { await service.end(lease.id) }
        try await waitFor { await backend.waitingForDestroy }
        await #expect(throws: VirtualDisplayError.busy) { try await service.create(for: owner) }
        await backend.completeDestroy()
        await ending.value
        #expect(await backend.createdCount == 1)
        #expect(await backend.removedCount == 1)
    }

    @Test func cleanupFailureRemainsVisibleAndBlocksAnotherAllocation() async throws {
        let backend = FakeDisplayBackend()
        let (service, owner) = await setup(backend)
        let lease = try await service.create(for: owner)
        await backend.setFailDestroy(true)
        await service.setEnabled(false)
        #expect(await service.snapshot().phase == .cleanupFailed)
        #expect(await service.snapshot().active?.id == lease.id)
        await service.setEnabled(true)
        await #expect(throws: VirtualDisplayError.busy) { try await service.create(for: owner) }
        await backend.setFailDestroy(false)
        await service.end(lease.id)
        #expect(await service.snapshot().active == nil)
        #expect(await backend.removedCount == 1)
    }

    @Test func failedPartialRollbackIsNotAnUntrackedOrphan() async throws {
        let backend = FakeDisplayBackend(partialFailure: true)
        let (service, owner) = await setup(backend)
        await #expect(throws: VirtualDisplayCreationFailure.self) { try await service.create(for: owner) }
        let snapshot = await service.snapshot()
        let lease = try #require(snapshot.active)
        #expect(snapshot.phase == .cleanupFailed)
        await #expect(throws: VirtualDisplayError.busy) { try await service.create(for: owner) }
        await service.end(lease.id)
        #expect(await backend.removedCount == 1)
        #expect(await service.snapshot().active == nil)
    }

    @Test func unsupportedBackendAndStartupNeverTouchOtherDisplays() async throws {
        let backend = FakeDisplayBackend(unavailable: "Unsupported runtime")
        let (service, owner) = await setup(backend)
        await #expect(throws: VirtualDisplayError.unavailable("Unsupported runtime")) { try await service.create(for: owner) }
        await service.shutdown()
        #expect(await backend.createdCount == 0)
        #expect(await backend.removedCount == 0)
    }

    @Test func removalWaitsForCaptureFallbackAndVisibilityIsOwnerScoped() async throws {
        let backend = FakeDisplayBackend()
        let (service, owner) = await setup(backend)
        let lease = try await service.create(for: owner)
        #expect(await service.canView(displayID: lease.displayID, sessionID: owner))
        #expect(await !service.canView(displayID: lease.displayID, sessionID: UUID()))
        let gate = DisplayTestGate()
        await service.setBeforeRemoval { _ in await gate.wait() }
        let end = Task { await service.end(lease.id) }
        try await waitFor { await gate.waiting }
        #expect(await backend.removedCount == 0)
        #expect(await !service.canView(displayID: lease.displayID, sessionID: owner))
        await gate.resume()
        await end.value
        #expect(await backend.removedCount == 1)
    }

    @Test func delayedSnapshotsCannotRestoreOldUIState() {
        var newer = VirtualDisplayState(); newer.revision = 2; newer.enabled = true
        var older = VirtualDisplayState(); older.revision = 1
        let result = HostState().reduce(.virtualDisplayChanged(newer)).reduce(.virtualDisplayChanged(older))
        #expect(result.virtualDisplay == newer)
    }

    func waitFor(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw VirtualDisplayError.unavailable("Test operation did not reach its gate")
    }
}

actor DisplayTestGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func resume() { continuation?.resume(); continuation = nil }
}

actor FakeDisplayBackend: VirtualDisplayBackend {
    private let unavailable: String?
    private let partialFailure: Bool
    private var blockCreate: Bool
    private var blockDestroy = false
    private var failDestroy = false
    private var createGate: CheckedContinuation<Void, Never>?
    private var destroyGate: CheckedContinuation<Void, Never>?
    private var created: [VirtualDisplayResource] = []
    private var removed: [VirtualDisplayResource] = []
    var createdCount: Int { created.count }
    var removedCount: Int { removed.count }
    var waitingForCreate: Bool { createGate != nil }
    var waitingForDestroy: Bool { destroyGate != nil }

    init(blockCreate: Bool = false, unavailable: String? = nil, partialFailure: Bool = false) {
        self.blockCreate = blockCreate; self.unavailable = unavailable; self.partialFailure = partialFailure
    }
    func unavailableReason() -> String? { unavailable }
    func create(logicalID: String, mode: VirtualDisplayMode) async throws -> VirtualDisplayResource {
        let resource = VirtualDisplayResource(displayID: 2)
        created.append(resource)
        if blockCreate { await withCheckedContinuation { createGate = $0 } }
        if partialFailure { throw VirtualDisplayCreationFailure(resource: resource) }
        return resource
    }
    func destroy(_ resource: VirtualDisplayResource) async throws {
        if blockDestroy { await withCheckedContinuation { destroyGate = $0 } }
        if failDestroy { throw VirtualDisplayError.cleanupFailed }
        removed.append(resource)
    }
    func completeCreate() { blockCreate = false; createGate?.resume(); createGate = nil }
    func setBlockDestroy(_ block: Bool) { blockDestroy = block }
    func completeDestroy() { blockDestroy = false; destroyGate?.resume(); destroyGate = nil }
    func setFailDestroy(_ fail: Bool) { failDestroy = fail }
}
#endif
