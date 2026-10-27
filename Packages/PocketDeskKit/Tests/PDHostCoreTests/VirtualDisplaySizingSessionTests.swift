#if os(macOS)
import CoreGraphics
import Foundation
import PDProtocol
import PDSecurity
import PDTransport
import Testing
@testable import PDHostCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct VirtualDisplaySizingSessionTests {
    @Test(arguments: [StreamQuality.best, .balanced, .batterySaver], [30, 60])
    func modeChangeKeepsTheDisplayAndFencesOldInput(_ quality: StreamQuality, _ fps: Int) async throws {
        let frames = SyntheticFrameSource(), input = RecordingInputSink()
        let backend = FakeDisplayBackend(modeChanged: { mode in await frames.setVirtualMode(mode) })
        let manager = VirtualDisplayService(hostID: UUID(), enabled: true, backend: backend)
        await manager.start()
        let pair = LoopbackSession.pair()
        let session = HostSession(session: pair.host, peer: .init(bytes: Data(repeating: 3, count: 32)),
            configuration: .init(hostName: "Test"), frameSource: frames, input: input, pairing: TrustEveryone(), virtualDisplays: manager)
        await manager.setBeforeRemoval { id in await session.prepareToRemoveVirtualDisplay(id) }
        await manager.setConfigurationCallbacks(before: { id in await session.pauseForVirtualDisplayConfiguration(id) },
            after: { id in await session.resumeAfterVirtualDisplayConfiguration(id) })
        let host = Task { try await session.run() }
        do {
            var control = PhoneControl(pair.client, acknowledgeConfigurations: false)
            try await pair.client.send(.hello(.init(deviceName: "iPhone/iPad", viewport: .init(width: 874, height: 402, scale: 3), quality: quality)))
            _ = try await control.until { if case .streamConfig = $0 { true } else { false } }
            let create = VirtualDisplayRequest(mode: .standard)
            try await pair.client.send(.createVirtualDisplay(create))
            let initial = try await control.reportFor(create.id)
            let lease = try #require(initial.workspace)
            let old = try #require(control.latestConfig).sourceGeneration
            let mode = VirtualDisplayMode(width: 800, height: 1280, scale: 2, refreshRate: fps)
            let change = VirtualDisplayConfiguration(leaseID: lease.leaseID, mode: mode,
                viewport: .init(width: 402, height: 874, scale: 3))
            try await pair.client.send(.configureVirtualDisplay(change))
            let report = try await control.reportFor(change.id)
            let config = try #require(control.latestConfig)
            #expect(report.workspace?.leaseID == lease.leaseID && report.workspace?.displayID == lease.displayID)
            #expect(report.workspace?.acceptedMode == mode)
            #expect(config.sourceGeneration != old && config.fps <= min(fps, quality == .batterySaver ? 30 : 60))
            #expect(config.width <= mode.pixelWidth && config.height <= mode.pixelHeight)
            #expect(input.sourceFrames.last == CGRect(x: -800, y: -80, width: 800, height: 1280))
            #expect(await backend.createdCount == 1)
            #expect(await backend.configuredCount == 1)
            var video = pair.client.videoFrames.makeAsyncIterator()
            var first = try #require(try await video.next())
            while first.0.sourceGeneration != config.sourceGeneration { first = try #require(try await video.next()) }
            #expect(first.0.flags.contains([.keyframe, .parameterSets]))
            try await pair.client.send(.sourceReady(old))
            try await pair.client.send(.sourceText(generation: config.sourceGeneration, text: "not-ready"))
            try await pair.client.send(.sourceReady(config.sourceGeneration))
            try await pair.client.send(.sourceText(generation: old, text: "stale"))
            try await pair.client.send(.insertText("unscoped"))
            try await pair.client.send(.sourceText(generation: config.sourceGeneration, text: "accepted"))
            try await pair.client.send(.ping(10))
            _ = try await control.until { $0 == .pong(10) }
            #expect(input.text == ["accepted"])
            try await pair.client.send(.scoped(generation: old, event: .pointerMove(x: 0.1, y: 0.1)))
            try await pair.client.send(.scoped(generation: config.sourceGeneration, event: .pointerMove(x: 0.5, y: 0.5)))
            for _ in 0..<100 where input.events.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
            #expect(input.events == [.pointerMove(x: 0.5, y: 0.5)])
            #expect(await frames.audioConfigurations.last?.1 == config.sourceGeneration)
            let physicalViewport = Viewport(width: 800, height: 600, scale: 2)
            try await pair.client.send(.setViewport(physicalViewport))
            _ = try await control.until { if case .streamConfig = $0 { true } else { false } }
            #expect(await backend.configuredCount == 1)
            #expect(await backend.createdCount == 1) // Stream-only layout/quality change.
            try await pair.client.send(.bye(reason: "done")); try await host.value
            await pair.client.close(); await manager.shutdown()
        } catch {
            await pair.client.close(); host.cancel(); _ = await host.result; await manager.shutdown(); throw error
        }
    }
}

private extension PhoneControl {
    mutating func until(_ predicate: (ControlMessage) -> Bool) async throws -> ControlMessage {
        while let message = try await next() { if predicate(message) { return message } }
        throw TransportError.closed
    }
    mutating func reportFor(_ id: UUID) async throws -> VirtualDisplayReport {
        let message = try await until { if case .virtualDisplay(let report) = $0 { report.requestID == id } else { false } }
        guard case .virtualDisplay(let report) = message else { throw TransportError.closed }
        return report
    }
}
#endif
