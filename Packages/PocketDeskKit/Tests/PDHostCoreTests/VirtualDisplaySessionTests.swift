#if os(macOS)
import CoreGraphics
import AppKit
import Foundation
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDHostCore

@Suite(.timeLimit(.minutes(1)))
struct VirtualDisplaySessionTests {
    let peer = Fingerprint(bytes: Data(repeating: 9, count: 32))

    @Test func catalogAndDeniedConnectionsNeverBecomeDisplayOwners() async throws {
        for (mode, allowed) in [(Hello.Mode.catalog, true), (.stream, false)] {
            let backend = FakeDisplayBackend()
            let service = VirtualDisplayService(hostID: UUID(), enabled: true, backend: backend)
            await service.start()
            let (hostEnd, phone) = LoopbackSession.pair()
            let id = UUID()
            let session = HostSession(session: hostEnd, peer: peer, configuration: .init(hostName: "Test"),
                frameSource: SyntheticFrameSource(), input: RecordingInputSink(), pairing: DisplayTestPairing(allowed: allowed),
                virtualDisplays: service, viewingSessionID: id)
            let host = Task { try await session.run() }
            var control = PhoneControl(phone)
            try await phone.send(.hello(Hello(deviceName: "Phone", viewport: .init(width: 400, height: 800, scale: 1), mode: mode)))
            if allowed {
                guard case .helloAck? = try await control.next() else { Issue.record("expected catalog handshake"); return }
                try await phone.send(.ping(1))
                #expect(try await control.next() == .pong(1))
                try await phone.send(.bye(reason: "done"))
            } else {
                guard case .bye? = try await control.next() else { Issue.record("expected denied session"); return }
                await phone.close()
            }
            try await host.value
            #expect(await service.snapshot().viewers.isEmpty)
            await #expect(throws: VirtualDisplayError.notViewing) { try await service.create(for: id) }
            #expect(await backend.createdCount == 0)
            await phone.close()
            await service.shutdown()
        }
    }

    @Test func localEndReturnsCaptureToPhysicalBeforeReleasingTheDisplay() async throws {
        let backend = FakeDisplayBackend()
        let service = VirtualDisplayService(hostID: UUID(), enabled: true, backend: backend)
        await service.start()
        let (hostEnd, phone) = LoopbackSession.pair()
        let frames = SyntheticFrameSource()
        let id = UUID()
        let session = HostSession(session: hostEnd, peer: peer, configuration: .init(hostName: "Test"),
            frameSource: frames, input: RecordingInputSink(), pairing: TrustEveryone(), virtualDisplays: service, viewingSessionID: id)
        await service.setBeforeRemoval { display in await session.prepareToRemoveVirtualDisplay(display) }
        let host = Task { try await session.run() }
        do {
            var control = PhoneControl(phone)
            try await phone.send(.hello(Hello(deviceName: "Phone", viewport: .init(width: 400, height: 800, scale: 1))))
            guard case .helloAck? = try await control.next(), case .streamConfig? = try await control.next() else {
                throw TransportError.closed
            }
            try await waitForViewer(service, id: id)
            #expect(await backend.createdCount == 0) // Even an approved stream needs an explicit create.
            let lease = try await service.create(for: id)
            try await phone.send(.selectDisplay(lease.displayID))
            guard case .streamConfig(let virtual)? = try await control.next() else { throw TransportError.closed }
            #expect(virtual.displayID == 2)
            await service.end(lease.id)
            guard case .streamConfig(let physical)? = try await control.next(), case .actionFailed? = try await control.next() else {
                throw TransportError.closed
            }
            #expect(physical.displayID == 1)
            #expect(await backend.removedCount == 1)
            #expect(await frames.startedSources == [.display(1), .display(2), .display(1)])
            let second = try await service.create(for: id)
            try await phone.send(.bye(reason: "done"))
            try await host.value
            #expect(await service.snapshot().active == nil)
            #expect(await service.snapshot().viewers.isEmpty)
            #expect(await backend.removedCount == 2)
            await service.end(second.id) // A delayed cleanup cannot do anything twice.
            #expect(await backend.removedCount == 2)
            await phone.close()
        } catch {
            await phone.close()
            host.cancel()
            _ = await host.result
            await service.shutdown()
            throw error
        }
    }

    @Test func anotherSessionCannotSelectTheLeasedDisplayAndPhysicalStreamingStillWorks() async throws {
        let backend = FakeDisplayBackend()
        let service = VirtualDisplayService(hostID: UUID(), enabled: true, backend: backend)
        await service.start()
        let owner = UUID()
        await service.registerViewingSession(id: owner, peer: peer, name: "First phone")
        _ = try await service.create(for: owner)
        let (hostEnd, phone) = LoopbackSession.pair()
        let session = HostSession(session: hostEnd, peer: peer, configuration: .init(hostName: "Test"),
            frameSource: SyntheticFrameSource(), input: RecordingInputSink(), pairing: TrustEveryone(),
            virtualDisplays: service, viewingSessionID: UUID())
        let host = Task { try await session.run() }
        do {
            var control = PhoneControl(phone)
            try await phone.send(.hello(Hello(deviceName: "Other connection", viewport: .init(width: 400, height: 800, scale: 1))))
            guard case .helloAck(let ack)? = try await control.next(), case .streamConfig? = try await control.next() else { throw TransportError.closed }
            #expect(ack.displays.map(\.id) == [1])
            try await phone.send(.selectDisplay(2))
            guard case .displays(let visible)? = try await control.next(), case .actionFailed? = try await control.next() else { throw TransportError.closed }
            #expect(visible.map(\.id) == [1])
            try await phone.send(.ping(5))
            #expect(try await control.next() == .pong(5))
            try await phone.send(.bye(reason: "done"))
            try await host.value
            await service.shutdown()
            await phone.close()
        } catch {
            await phone.close(); host.cancel(); _ = await host.result
            await service.shutdown()
            throw error
        }
    }

    private func waitForViewer(_ service: VirtualDisplayService, id: UUID) async throws {
        for _ in 0..<200 {
            if await service.snapshot().viewers.contains(where: { $0.id == id }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TransportError.timedOut
    }
}

private struct DisplayTestPairing: PairingAuthority {
    let allowed: Bool
    func isTrusted(_ peer: Fingerprint) -> Bool { true }
    func approve(peer: Fingerprint, deviceName: String, token: [UInt8]) -> Bool { false }
    func allowSession(peer: Fingerprint, deviceName: String) -> Bool { allowed }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct VirtualDisplayNativeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETDESK_VIRTUAL_DISPLAY_NATIVE"] == "1"))
    func realServiceCreatesAndRemovesOwnedDisplaysWithStableIdentity() async throws {
        await MainActor.run {
            _ = NSApplication.shared
            _ = NSScreen.screens
        }
        let backend = RuntimeVirtualDisplayBackend()
        let service = VirtualDisplayService(hostID: UUID(), enabled: true, backend: backend)
        await service.start()
        let owner = UUID(), peer = Fingerprint(bytes: Data(repeating: 7, count: 32))
        await service.registerViewingSession(id: owner, peer: peer, name: "Phase 1 native test")
        let baseline = try inventory()
        var logicalID: String?
        var previousLease: UUID?
        do {
            for mode in [VirtualDisplayMode.standard, .standard, .standard] {
                let lease = try await service.create(for: owner, mode: mode)
                if let previousLease { await service.end(previousLease) }
                #expect(CGDisplayIsActive(lease.displayID) != 0)
                #expect(CGDisplayIsMain(lease.displayID) == 0)
                #expect(CGDisplayMirrorsDisplay(lease.displayID) == 0)
                if let logicalID { #expect(lease.logicalID == logicalID) }
                logicalID = lease.logicalID
                let pixelMode = CGDisplayCopyDisplayMode(lease.displayID)
                #expect((pixelMode?.pixelWidth ?? CGDisplayPixelsWide(lease.displayID)) == mode.width)
                #expect((pixelMode?.pixelHeight ?? CGDisplayPixelsHigh(lease.displayID)) == mode.height)
                if let rate = pixelMode?.refreshRate, rate > 0 { #expect(rate == Double(mode.refreshRate)) }
                print("Phase 1 native: \(mode.width)×\(mode.height), requested \(mode.refreshRate) Hz, mode object available=\(pixelMode != nil); stale cleanup preserved active lease")
                await service.end(lease.id)
                #expect(await service.snapshot().active == nil)
                #expect(try inventory() == baseline)
                previousLease = lease.id
            }
            await service.shutdown()
        } catch { await service.shutdown(); throw error }
    }

    private func inventory() throws -> [UInt32: [Double]] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { throw TransportError.closed }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { throw TransportError.closed }
        return Dictionary(uniqueKeysWithValues: ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id), mode = CGDisplayCopyDisplayMode(id)
            return (id, [bounds.minX, bounds.minY, bounds.width, bounds.height, Double(mode?.pixelWidth ?? 0),
                         Double(mode?.pixelHeight ?? 0), Double(CGDisplayIsMain(id)), Double(CGDisplayMirrorsDisplay(id))])
        })
    }
}
#endif
