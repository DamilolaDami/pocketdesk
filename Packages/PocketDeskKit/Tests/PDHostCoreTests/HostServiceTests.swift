#if os(macOS)
// Uses the macOS host engines (encoder, capture, HostService).
import CoreGraphics
import CoreMedia
import Foundation
import Network
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDHostCore

/// The whole host over real QUIC on 127.0.0.1: pairing, handshake, streaming (real HEVC
/// encoder, synthetic frames), input and source switching.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class HostServiceTests {
    let run = UUID().uuidString
    let trustStoreURL: URL
    let phone: DeviceIdentity
    let frames = SyntheticFrameSource()
    let input = RecordingInputSink()
    let events = EventLog()
    var service: HostService!
    var serviceTask: Task<Void, any Error>?

    init() throws {
        trustStoreURL = FileManager.default.temporaryDirectory.appending(path: "pd-tests-\(run)/trusted.json")
        phone = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.tests.phone.\(run)")
    }

    deinit {
        serviceTask?.cancel()
        DeviceIdentity.delete(label: phone.label)
        DeviceIdentity.delete(label: "com.pocketdesk.tests.host.\(run)")
        try? FileManager.default.removeItem(at: trustStoreURL.deletingLastPathComponent())
    }

    /// Starts the service. `approve` answers the verification-code prompt.
    func startService(approve: @escaping @Sendable (PairingApproval) -> Bool = { _ in true }) async throws -> UInt16 {
        let events = events
        let box = ServiceBox()
        let service = try HostService(
            configuration: .init(hostID: UUID(), hostName: "Test Mac", identityLabel: "com.pocketdesk.tests.host.\(run)",
                                 trustStoreURL: trustStoreURL, advertise: false),
            makeFrameSource: { [frames] in frames }, input: input
        ) { event in
            events.append(event)
            if case .approvalRequested(let approval) = event {
                Task { await box.service?.resolveApproval(approval.id, accepted: approve(approval)) }
            }
        }
        await box.set(service)
        self.service = service
        serviceTask = Task { try await service.run() }
        for _ in 0..<200 {
            if let port = await service.port { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TransportError.timedOut
    }

    func connect(port: UInt16, timeout: Duration = .seconds(5),
                 _ body: @escaping @Sendable (QUICPeerSession) async throws -> Void) async throws {
        try await QUICClient.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), identity: phone,
                                     host: service.identity.fingerprint, timeout: timeout, body)
    }

    @Test func pairsThenStreamsAndAcceptsInput() async throws {
        let port = try await startService()
        let invite = await service.openInvite()
        let hostFingerprint = service.identity.fingerprint
        let phoneFingerprint = phone.fingerprint
        let input = input

        try await connect(port: port) { session in
            var control = PhoneControl(session)
            try await session.send(.pairRequest(PairRequest(token: [UInt8](invite.token), deviceName: "Test iPhone")))
            #expect(try await control.next() == .pairResult(accepted: true))

            try await session.send(.hello(Hello(deviceName: "Test iPhone", viewport: Viewport(width: 402, height: 874, scale: 3))))
            guard case .helloAck(let ack)? = try await control.next() else { Issue.record("expected helloAck"); return }
            #expect(ack.hostName == "Test Mac")
            #expect(ack.displays.count == 2)

            guard case .streamConfig(let config)? = try await control.next() else { Issue.record("expected streamConfig"); return }
            #expect(config.codec == .hevc)
            #expect(config.width == 1920 && config.height == 1080) // 1080p display fits a 2622 px long edge

            var video = session.videoFrames.makeAsyncIterator()
            let (header, payload) = try #require(try await video.next())
            #expect(header.flags.contains([.keyframe, .parameterSets]))
            let dimensions = CMVideoFormatDescriptionGetDimensions(try formatDescription(fromKeyframe: payload))
            #expect(Int(dimensions.width) == config.width && Int(dimensions.height) == config.height)
            let second = try #require(try await video.next())
            #expect(second.0.frameID == header.frameID + 1)

            for _ in 0..<50 where input.events.isEmpty {
                try await session.send(InputEvent.button(.left, isDown: true, x: 0.5, y: 0.5))
                try await Task.sleep(for: .milliseconds(20))
            }
            try await session.send(.insertText("héllo"))

            // Shortcuts run in order; one that can't be done says why.
            try await session.send(.run(.openURL("https://www.netflix.com")))
            try await session.send(.run(.openApp(bundleID: nil, name: "Missing")))
            #expect(try await control.next() == .actionFailed("Missing isn't installed on this Mac."))

            // Switch to a window: new config, new generation, keyframe first.
            try await session.send(.selectSource(windowID: 42))
            guard case .streamConfig(let windowConfig)? = try await control.next() else { Issue.record("expected streamConfig"); return }
            #expect(windowConfig.width == 1600 && windowConfig.height == 1200)
            var next = try #require(try await video.next())
            while next.0.sourceGeneration == header.sourceGeneration { next = try #require(try await video.next()) }
            #expect(next.0.flags.contains(.keyframe))

            try await session.send(.ping(5))
            #expect(try await control.next() == .pong(5))
            try await session.send(.bye(reason: "done"))
            for _ in 0..<100 where !input.text.contains("héllo") { try await Task.sleep(for: .milliseconds(10)) }
        }

        // The person at the Mac saw the same code the phone would compute.
        let approval = try #require(events.all.compactMap { event -> PairingApproval? in
            if case .approvalRequested(let approval) = event { approval } else { nil }
        }.first)
        #expect(approval.code == Pairing.verificationCode(host: hostFingerprint, client: phoneFingerprint, token: invite.token))
        #expect(await service.isTrusted(phoneFingerprint))
        #expect(input.events.first == .button(.left, isDown: true, x: 0.5, y: 0.5))
        #expect(input.text == ["héllo"])
        #expect(input.actions == [.openURL("https://www.netflix.com")])
        #expect(input.sourceFrames.last == CGRect(x: 100, y: 50, width: 800, height: 600))
        #expect(await frames.startedSources == [.display(1), .window(42)])
        #expect(events.all.contains(.inviteChanged(nil))) // single use
        #expect(try TrustStore.load(from: trustStoreURL).trusts(phoneFingerprint))
    }

    @Test func audioPreferenceChangesRestartCurrentSourceWithNewGeneration() async throws {
        var trust = TrustStore()
        trust.pin(PairedPeer(fingerprint: phone.fingerprint, name: "Phone"))
        try trust.save(to: trustStoreURL)
        let port = try await startService()
        try await connect(port: port) { session in
            var control = PhoneControl(session)
            try await session.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 400, height: 800, scale: 1),
                                               audioEnabled: false)))
            guard case .helloAck? = try await control.next(),
                  case .streamConfig? = try await control.next() else { Issue.record("missing handshake"); return }
            try await session.send(.selectSource(windowID: 42))
            guard case .streamConfig? = try await control.next() else { Issue.record("missing source config"); return }
            try await session.send(.setAudioEnabled(true))
            guard case .streamConfig? = try await control.next() else { Issue.record("missing audio restart config"); return }
            try await session.send(.setAudioEnabled(false))
            guard case .streamConfig? = try await control.next() else { Issue.record("missing mute config"); return }
            // A ping orders this assertion after capture setup, which follows streamConfig.
            try await session.send(.ping(42))
            #expect(try await control.next() == .pong(42))
            try await session.send(.bye(reason: "done"))
        }
        #expect(await frames.audioConfigurations.map { $0.0 } == [false, false, true, false])
        #expect(await frames.audioConfigurations.map { $0.1 } == [1, 2, 3, 4])
        #expect(await frames.startedSources == [.display(1), .window(42), .window(42), .window(42)])
    }

    @Test func remembersDisplayAndSwitchesWithoutReconnecting() async throws {
        var trust = TrustStore()
        trust.pin(PairedPeer(fingerprint: phone.fingerprint, name: "Phone"))
        try trust.save(to: trustStoreURL)
        let port = try await startService()
        let input = input
        try await connect(port: port) { session in
            var control = PhoneControl(session)
            var video = session.videoFrames.makeAsyncIterator()
            try await session.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 2560, height: 1440, scale: 1),
                                               preferredDisplayID: "external")))
            guard case .helloAck(let ack)? = try await control.next(),
                  case .streamConfig(let initial)? = try await control.next() else { Issue.record("missing handshake"); return }
            #expect(ack.displays.map(\.name) == ["Built-in", "External"])
            #expect(initial.displayID == 2)
            #expect(initial.width == 2560 && initial.height == 1440)
            let first = try #require(try await video.next())
            #expect(first.0.flags.contains(.keyframe))
            #expect(input.sourceFrames.last == CGRect(x: -2560, y: 0, width: 2560, height: 1440))

            try await session.send(.selectDisplay(1))
            guard case .streamConfig(let main)? = try await control.next() else { Issue.record("missing display config"); return }
            #expect(main.displayID == 1)
            var next = try #require(try await video.next())
            while next.0.sourceGeneration == first.0.sourceGeneration { next = try #require(try await video.next()) }
            #expect(next.0.flags.contains([.keyframe, .parameterSets]))
            #expect(next.0.sourceGeneration > first.0.sourceGeneration)
            #expect(input.sourceFrames.last == CGRect(x: 0, y: 0, width: 1920, height: 1080))

            try await session.send(.selectSource(windowID: 42))
            guard case .streamConfig(let window)? = try await control.next() else { Issue.record("missing window config"); return }
            #expect(window.displayID == nil)
            try await session.send(.selectSource(windowID: nil))
            guard case .streamConfig(let whole)? = try await control.next() else { Issue.record("missing whole-display config"); return }
            #expect(whole.displayID == 1)

            try await session.send(.selectDisplay(2))
            guard case .streamConfig(let external)? = try await control.next() else { Issue.record("missing external config"); return }
            #expect(external.displayID == 2)
            try await session.send(.setAudioEnabled(false))
            guard case .streamConfig(let muted)? = try await control.next() else { Issue.record("missing audio config"); return }
            #expect(muted.displayID == 2)

            // A monitor removed while the picker was open must leave the session usable.
            try await session.send(.selectDisplay(999))
            guard case .displays(let refreshed)? = try await control.next(),
                  case .actionFailed? = try await control.next() else { Issue.record("missing stale-display response"); return }
            #expect(refreshed.count == 2)
            try await session.send(.ping(11))
            #expect(try await control.next() == .pong(11))
            try await session.send(.bye(reason: "done"))
        }
        #expect(await frames.startedSources == [.display(2), .display(1), .window(42), .display(1), .display(2), .display(2)])
    }

    @Test func unavailableRememberedDisplayFallsBackToMain() async throws {
        var trust = TrustStore()
        trust.pin(PairedPeer(fingerprint: phone.fingerprint, name: "Phone"))
        try trust.save(to: trustStoreURL)
        let port = try await startService()
        try await connect(port: port) { session in
            var control = PhoneControl(session)
            try await session.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 400, height: 800, scale: 1),
                                               preferredDisplayID: "unplugged")))
            guard case .helloAck? = try await control.next(),
                  case .streamConfig(let config)? = try await control.next() else { Issue.record("missing handshake"); return }
            #expect(config.displayID == 1)
            try await session.send(.bye(reason: "done"))
        }
        #expect(await frames.startedSources == [.display(1)])
    }

    @Test func pairedPhoneReconnectsWithoutInvite() async throws {
        var store = TrustStore()
        store.pin(PairedPeer(fingerprint: phone.fingerprint, name: "Test iPhone"))
        try store.save(to: trustStoreURL)
        let port = try await startService()

        try await connect(port: port) { session in
            try await session.send(.hello(Hello(deviceName: "Test iPhone", viewport: Viewport(width: 402, height: 874, scale: 3))))
            var control = PhoneControl(session)
            guard case .helloAck? = try await control.next() else { Issue.record("expected helloAck"); return }
            try await session.send(.bye(reason: "done"))
        }
    }

    /// The phone gave up waiting just before the Mac accepted, then scanned again.
    @Test func pairedPhoneThatAsksAgainIsAccepted() async throws {
        var store = TrustStore()
        store.pin(PairedPeer(fingerprint: phone.fingerprint, name: "Test iPhone"))
        try store.save(to: trustStoreURL)
        let port = try await startService()

        try await connect(port: port) { session in
            var control = PhoneControl(session)
            try await session.send(.pairRequest(PairRequest(token: Array(repeating: 1, count: 16), deviceName: "Test iPhone")))
            #expect(try await control.next() == .pairResult(accepted: true))
            try await session.send(.hello(Hello(deviceName: "Test iPhone", viewport: Viewport(width: 402, height: 874, scale: 3))))
            guard case .helloAck? = try await control.next() else { Issue.record("expected helloAck"); return }
            try await session.send(.bye(reason: "done"))
        }
    }

    @Test func unknownPhoneWithoutInviteCannotConnect() async throws {
        let port = try await startService()
        await #expect(throws: (any Error).self) {
            try await self.connect(port: port, timeout: .seconds(2)) { session in
                try await session.send(.hello(Hello(deviceName: "Stranger", viewport: Viewport(width: 1, height: 1, scale: 1))))
                _ = try await session.controlMessages.first { _ in true }
            }
        }
    }

    @Test func rejectedCodeIsNotPinned() async throws {
        let port = try await startService(approve: { _ in false })
        let invite = await service.openInvite()

        try await connect(port: port) { session in
            try await session.send(.pairRequest(PairRequest(token: [UInt8](invite.token), deviceName: "Test iPhone")))
            #expect(try await session.controlMessages.first { _ in true } == .pairResult(accepted: false))
        }
        #expect(await !service.isTrusted(phone.fingerprint))
    }

    @Test func wrongTokenIsRejectedWithoutPrompting() async throws {
        let port = try await startService()
        _ = await service.openInvite()

        try await connect(port: port) { session in
            try await session.send(.pairRequest(PairRequest(token: Array(repeating: 0, count: 16), deviceName: "Guesser")))
            #expect(try await session.controlMessages.first { _ in true } == .pairResult(accepted: false))
        }
        #expect(!events.all.contains { if case .approvalRequested = $0 { true } else { false } })
    }
}

@Suite struct HostStateTests {
    let peer = Fingerprint(certificateDER: Data("phone".utf8))
    let config = StreamConfig(codec: .hevc, width: 1920, height: 1080, fps: 60, bitrateKbps: 12_000)

    @Test func tracksSessionLifecycle() {
        var state = HostState()
            .reduce(.listening(port: 4242))
            .reduce(.sessionStarted(peer: peer, deviceName: "iPhone"))
            .reduce(.sessionStreaming(peer: peer, config: config, window: nil))
        #expect(state.listening == .listening(port: 4242))
        #expect(state.connected.first?.stream == config)

        state = state.reduce(.sessionEnded(peer: peer))
        #expect(state.connected.isEmpty)
    }

    @Test func approvalsQueueAndResolve() {
        let first = PairingApproval(id: UUID(), deviceName: "A", code: "111111")
        let second = PairingApproval(id: UUID(), deviceName: "B", code: "222222")
        let state = HostState()
            .reduce(.approvalRequested(first))
            .reduce(.approvalRequested(second))
            .reduce(.approvalResolved(id: first.id))
        #expect(state.pendingApprovals == [second])
    }

    @Test func stoppingClearsLiveState() {
        let state = HostState()
            .reduce(.sessionStarted(peer: peer, deviceName: "iPhone"))
            .reduce(.approvalRequested(PairingApproval(id: UUID(), deviceName: "A", code: "1")))
            .reduce(.stopped(error: "boom"))
        #expect(state.connected.isEmpty && state.pendingApprovals.isEmpty)
        #expect(state.listening == .stopped(error: "boom"))
    }
}

actor ServiceBox {
    private(set) var service: HostService?
    func set(_ service: HostService) { self.service = service }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [HostEvent] = []
    var all: [HostEvent] { lock.withLock { events } }
    func append(_ event: HostEvent) { lock.withLock { events.append(event) } }
}
#endif
