#if os(macOS)
import Foundation
import PDProtocol
import PDSecurity
import Synchronization
import Testing
@testable import PDHostCore

@Suite(.timeLimit(.minutes(1)))
struct VirtualDisplayConfigurationTests {
    let peer = Fingerprint(bytes: Data(repeating: 6, count: 32))
    let portrait = VirtualDisplayMode(width: 800, height: 1280, scale: 2, refreshRate: 30)
    func setup(_ backend: FakeDisplayBackend) async throws -> (VirtualDisplayService, UUID, VirtualDisplayState.Lease) {
        let service = VirtualDisplayService(hostID: UUID(), enabled: true, backend: backend)
        await service.start()
        let owner = UUID()
        await service.registerViewingSession(id: owner, peer: peer, name: "Owner")
        return (service, owner, try await service.create(for: owner))
    }
    @Test func sameLeaseAndResourceSurviveInPlaceChangesAndNoOpRequests() async throws {
        let backend = FakeDisplayBackend()
        let (service, owner, lease) = try await setup(backend)
        let calls = Mutex<[String]>([])
        await service.setConfigurationCallbacks(before: { _ in calls.withLock { $0.append("pause") } },
            after: { _ in calls.withLock { $0.append("resume") } })
        let updated = try await service.configure(lease.id, for: owner, mode: portrait)
        #expect(updated.id == lease.id && updated.displayID == lease.displayID && updated.logicalID == lease.logicalID)
        #expect(updated.mode == portrait)
        _ = try await service.configure(lease.id, for: owner, mode: portrait)
        #expect(await backend.createdCount == 1)
        #expect(await backend.configuredCount == 1)
        #expect(calls.withLock { $0 } == ["pause", "resume"])
        await #expect(throws: VirtualDisplayError.notViewing) { try await service.configure(lease.id, for: UUID(), mode: .standard) }
        await #expect(throws: VirtualDisplayError.invalidMode) { try await service.configure(lease.id, for: owner, mode: .init(width: Int.max, height: 800)) }
        await service.shutdown()
    }
    enum Interruption: CaseIterable, Sendable { case disconnect, disable, revoke, cancellation, shutdown }
    @Test(arguments: Interruption.allCases)
    func interruptedConfigurationCannotOutliveItsOwner(_ interruption: Interruption) async throws {
        let backend = FakeDisplayBackend()
        let (service, owner, lease) = try await setup(backend)
        await backend.setBlockConfigure(true)
        let request = Task { try await service.configure(lease.id, for: owner, mode: portrait) }
        for _ in 0..<200 where !(await backend.waitingForConfigure) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await backend.waitingForConfigure)
        await #expect(throws: VirtualDisplayError.busy) { try await service.configure(lease.id, for: owner, mode: portrait) }
        var shutdown: Task<Void, Never>?
        switch interruption {
        case .disconnect: await service.unregisterViewingSession(owner)
        case .disable: await service.setEnabled(false)
        case .revoke: await service.revoke(peer)
        case .cancellation: request.cancel()
        case .shutdown:
            shutdown = Task { await service.shutdown() }
            for _ in 0..<200 where !(await service.snapshot().viewers.isEmpty) { try await Task.sleep(for: .milliseconds(5)) }
        }
        await backend.completeConfigure()
        await #expect(throws: VirtualDisplayError.cancelled) { try await request.value }
        await shutdown?.value
        #expect(await service.snapshot().active == nil)
        #expect(await backend.removedCount == 1)
        await service.shutdown()
    }
    @Test(arguments: [false, true])
    func failedModeChangeRestoresOrEndsTheOwnedResource(_ destructive: Bool) async throws {
        let backend = FakeDisplayBackend()
        let (service, owner, lease) = try await setup(backend)
        await backend.setConfigureFailure(destructive: destructive)
        do { _ = try await service.configure(lease.id, for: owner, mode: portrait); Issue.record("Expected failure") }
        catch {}
        if destructive {
            #expect(await service.snapshot().active == nil)
            #expect(await backend.removedCount == 1)
        } else {
            #expect(await service.snapshot().active == lease)
            #expect(await backend.removedCount == 0)
        }
        await service.shutdown()
    }
}
#endif
