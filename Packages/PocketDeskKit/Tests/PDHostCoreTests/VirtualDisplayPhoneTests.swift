#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDHostCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct VirtualDisplayPhoneTests {
    @Test(arguments: [Viewport(width: 402, height: 874, scale: 3), Viewport(width: 1366, height: 1024, scale: 2)])
    func phoneAndPadCreateStreamInputAndEndWithoutReconnecting(_ viewport: Viewport) async throws {
        let harness = try await VirtualPhoneHarness.start(viewport: viewport)
        do {
            var control = PhoneControl(harness.phone)
            _ = try await control.workspaceReport()
            var video = harness.phone.videoFrames.makeAsyncIterator()
            let first = try #require(try await video.next())
            let request = VirtualDisplayRequest(mode: .preferred(for: viewport))
            try await harness.phone.send(.createVirtualDisplay(request))
            let active = try await control.workspaceReport(request.id)
            let workspace = try #require(active.workspace)
            #expect(workspace.isOwner && workspace.acceptedMode == .standard)
            #expect(active.requestedMode == request.mode && active.problem == nil)
            #expect(workspace.geometry?.x == -2560)
            #expect(workspace.geometry?.pixelWidth == 2560)
            #expect(harness.input.sourceFrames.last == CGRect(x: -2560, y: 0, width: 2560, height: 1440))
            var virtual = try #require(try await video.next())
            while virtual.0.sourceGeneration == first.0.sourceGeneration { virtual = try #require(try await video.next()) }
            #expect(virtual.0.flags.contains([.keyframe, .parameterSets]))
            try await harness.phone.send(.insertText("Workspace keyboard"))
            try await harness.phone.send(InputEvent.pointerMove(x: 0.25, y: 0.75))
            try await harness.phone.send(InputEvent.scroll(dx: 0, dy: 12))
            try await harness.phone.send(.clipboard(.init(text: "Workspace clipboard")))
            try await harness.phone.send(.setAudioEnabled(false))
            try await harness.phone.send(.ping(90))
            _ = try await control.matching { $0 == .pong(90) }
            #expect(harness.input.text.contains("Workspace keyboard"))
            #expect(await harness.clipboard.written.contains(.init(text: "Workspace clipboard")))
            #expect(await harness.frames.audioConfigurations.last?.0 == false)
            for _ in 0..<100 where harness.input.events.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(harness.input.events.contains(.pointerMove(x: 0.25, y: 0.75)))
            #expect(harness.input.events.contains(.scroll(dx: 0, dy: 12)))
            let end = VirtualDisplayEnd(leaseID: workspace.leaseID)
            try await harness.phone.send(.endVirtualDisplay(end))
            let ended = try await control.workspaceReport(end.id)
            #expect(ended.workspace == nil && ended.phase == .idle)
            #expect(harness.input.sourceFrames.last == CGRect(x: 0, y: 0, width: 1920, height: 1080))
            #expect(await harness.backend.removedCount == 1)
            try await harness.phone.send(.ping(91))
            _ = try await control.matching { $0 == .pong(91) }
            await harness.stop()
        } catch { await harness.stop(); throw error }
    }

    @Test func denialAndUnsupportedBackendKeepThePhysicalStreamAlive() async throws {
        for backend in [FakeDisplayBackend(), FakeDisplayBackend(unavailable: "Unavailable on this Mac")] {
            let harness = try await VirtualPhoneHarness.start(backend: backend, enabled: false)
            do {
                var control = PhoneControl(harness.phone)
                let status = try await control.workspaceReport()
                #expect(!status.canCreate)
                let request = VirtualDisplayRequest(mode: .standard)
                try await harness.phone.send(.createVirtualDisplay(request))
                let denial = try await control.workspaceReport(request.id)
                #expect(denial.problem == .disabled || denial.problem == .unsupported)
                #expect(denial.workspace == nil)
                #expect(await backend.createdCount == 0)
                try await harness.phone.send(.ping(2))
                _ = try await control.matching { $0 == .pong(2) }
                #expect(harness.input.sourceFrames.last?.minX == 0)
                await harness.stop()
            } catch { await harness.stop(); throw error }
        }
    }

    @Test func foreignLeaseAndInvalidModeCannotRemoveOrAllocateADisplay() async throws {
        let harness = try await VirtualPhoneHarness.start()
        do {
            var control = PhoneControl(harness.phone)
            _ = try await control.workspaceReport()
            let bad = VirtualDisplayRequest(mode: .init(width: Int.max, height: -1))
            try await harness.phone.send(.createVirtualDisplay(bad))
            #expect(try await control.workspaceReport(bad.id).problem == .invalidMode)
            let other = UUID()
            await harness.service.registerViewingSession(id: other, peer: .init(bytes: Data(repeating: 8, count: 32)), name: "Other phone")
            let lease = try await harness.service.create(for: other)
            let end = VirtualDisplayEnd(leaseID: lease.id)
            try await harness.phone.send(.endVirtualDisplay(end))
            #expect(try await control.workspaceReport(end.id).problem == .notOwner)
            #expect(await harness.service.snapshot().active?.id == lease.id)
            #expect(await harness.backend.removedCount == 0)
            await harness.stop()
        } catch { await harness.stop(); throw error }
    }

    @Test func stalePhoneEndCannotRemoveTheReplacementWorkspace() async throws {
        let harness = try await VirtualPhoneHarness.start()
        do {
            var control = PhoneControl(harness.phone)
            _ = try await control.workspaceReport()
            let first = VirtualDisplayRequest(mode: .standard)
            try await harness.phone.send(.createVirtualDisplay(first))
            let old = try #require(try await control.workspaceReport(first.id).workspace)
            let end = VirtualDisplayEnd(leaseID: old.leaseID)
            try await harness.phone.send(.endVirtualDisplay(end))
            _ = try await control.workspaceReport(end.id)
            let next = VirtualDisplayRequest(mode: .standard)
            try await harness.phone.send(.createVirtualDisplay(next))
            let replacement = try #require(try await control.workspaceReport(next.id).workspace)
            let stale = VirtualDisplayEnd(leaseID: old.leaseID)
            try await harness.phone.send(.endVirtualDisplay(stale))
            #expect(try await control.workspaceReport(stale.id).problem == .notOwner)
            #expect(await harness.service.snapshot().active?.id == replacement.leaseID)
            #expect(await harness.backend.removedCount == 1)
            await harness.stop()
        } catch { await harness.stop(); throw error }
    }

    @Test func macOwnerEndIsPushedToThePhone() async throws {
        let harness = try await VirtualPhoneHarness.start()
        do {
            var control = PhoneControl(harness.phone)
            _ = try await control.workspaceReport()
            let create = VirtualDisplayRequest(mode: .standard)
            try await harness.phone.send(.createVirtualDisplay(create))
            let active = try await control.workspaceReport(create.id)
            await harness.service.end(try #require(active.workspace).leaseID)
            let idle = try await control.matching {
                if case .virtualDisplay(let report) = $0 { return report.phase == .idle && report.revision > active.revision }
                return false
            }
            guard case .virtualDisplay(let report) = idle else { throw TransportError.closed }
            #expect(report.workspace == nil)
            await harness.stop()
        } catch { await harness.stop(); throw error }
    }
}

private struct VirtualPhoneHarness {
    let service: VirtualDisplayService
    let backend: FakeDisplayBackend
    let phone: LoopbackSession
    let host: Task<Void, any Error>
    let input: RecordingInputSink
    let frames: SyntheticFrameSource
    let clipboard: FakeClipboard
    static func start(backend: FakeDisplayBackend = FakeDisplayBackend(), enabled: Bool = true,
                      viewport: Viewport = .init(width: 402, height: 874, scale: 3)) async throws -> Self {
        let service = VirtualDisplayService(hostID: UUID(), enabled: enabled, backend: backend)
        await service.start()
        let pair = LoopbackSession.pair(), input = RecordingInputSink(), frames = SyntheticFrameSource(), clipboard = FakeClipboard()
        let session = HostSession(session: pair.host, peer: .init(bytes: Data(repeating: 9, count: 32)),
            configuration: .init(hostName: "Mac"), frameSource: frames, input: input, pairing: TrustEveryone(), clipboard: clipboard,
            virtualDisplays: service)
        await service.setBeforeRemoval { id in await session.prepareToRemoveVirtualDisplay(id) }
        let host = Task { try await session.run() }
        try await pair.client.send(.hello(.init(deviceName: "Device", viewport: viewport)))
        try await pair.client.send(.watchVirtualDisplay)
        return .init(service: service, backend: backend, phone: pair.client, host: host, input: input, frames: frames, clipboard: clipboard)
    }
    func stop() async {
        await phone.close(); host.cancel(); _ = await host.result
        await service.shutdown()
    }
}

private extension PhoneControl {
    mutating func matching(_ predicate: (ControlMessage) -> Bool) async throws -> ControlMessage {
        while let message = try await next() { if predicate(message) { return message } }
        throw TransportError.closed
    }
    mutating func workspaceReport(_ id: UUID? = nil) async throws -> VirtualDisplayReport {
        let message = try await matching {
            if case .virtualDisplay(let report) = $0 { return id == nil || report.requestID == id }
            return false
        }
        guard case .virtualDisplay(let report) = message else { throw TransportError.closed }
        return report
    }
}
#endif
