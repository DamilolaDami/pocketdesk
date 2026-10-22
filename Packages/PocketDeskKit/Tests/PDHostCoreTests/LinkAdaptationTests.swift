#if os(macOS)
import Foundation
import Synchronization
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDHostCore

@Suite struct RateControllerTests {
    private let busy = RateController.Sample(framesSent: 10, framesDropped: 10)
    private let quiet = RateController.Sample(framesSent: 30, framesDropped: 0)
    private let still = RateController.Sample(framesSent: 0, framesDropped: 0)

    @Test func startsAtFullQuality() {
        let rate = RateController()
        #expect(rate.step == RateController.Step(bitrate: 1, fps: 60, scale: 1))
        #expect(!rate.isWeak)
    }

    @Test func laddersDownBitrateThenFrameRateThenResolution() {
        let ladder = RateController.ladder
        let firstFPSCut = ladder.firstIndex { $0.fps < 60 }!
        let firstResize = ladder.firstIndex { $0.scale < 1 }!
        #expect(ladder[1].bitrate < 1 && ladder[1].fps == 60 && ladder[1].scale == 1)
        #expect(firstFPSCut < firstResize)
        #expect(zip(ladder, ladder.dropFirst()).allSatisfy { $0.bitrate > $1.bitrate })
    }

    @Test func dropsStepDownButHoldBetweenSteps() {
        var rate = RateController()
        do { let changed = rate.update(busy); #expect(changed) }
        #expect(rate.level == 1)
        // The step needs time to take effect before judging it.
        do { let changed = rate.update(busy); #expect(!changed) }
        do { let changed = rate.update(busy); #expect(changed) }
        #expect(rate.level == 2)
        #expect(rate.isWeak)
    }

    @Test func neverLeavesTheLadder() {
        var rate = RateController()
        for _ in 0..<100 { _ = rate.update(busy) }
        #expect(rate.level == RateController.ladder.count - 1)
    }

    @Test func slowSendsAndRoundTripsAreCongestion() {
        let rate = RateController()
        #expect(rate.isCongested(.init(framesSent: 5, framesDropped: 0, averageSendTime: .milliseconds(150))))
        var withBaseline = RateController()
        _ = withBaseline.update(.init(framesSent: 5, framesDropped: 0, roundTrip: .milliseconds(8)))
        #expect(!withBaseline.isCongested(.init(framesSent: 5, framesDropped: 0, roundTrip: .milliseconds(40))))
        #expect(withBaseline.isCongested(.init(framesSent: 5, framesDropped: 0, roundTrip: .milliseconds(200))))
        // An occasional dropped frame is normal.
        #expect(!rate.isCongested(.init(framesSent: 29, framesDropped: 1)))
    }

    @Test func recoversAfterAQuietStretch() {
        var rate = RateController()
        _ = rate.update(busy)
        for _ in 1..<RateController.baseRecoveryWindows { do { let changed = rate.update(quiet); #expect(!changed) } }
        do { let changed = rate.update(quiet); #expect(changed) }
        #expect(rate.level == 0)
    }

    @Test func aStillScreenProvesNothing() {
        var rate = RateController()
        _ = rate.update(busy)
        for _ in 0..<50 { do { let changed = rate.update(still); #expect(!changed) } }
        #expect(rate.level == 1)
    }

    @Test func aFailedStepUpBacksOff() {
        var rate = RateController()
        _ = rate.update(busy)
        for _ in 0..<RateController.baseRecoveryWindows { _ = rate.update(quiet) }
        #expect(rate.level == 0)
        _ = rate.update(busy)
        #expect(rate.level == 1)
        #expect(rate.recoveryWindows == RateController.baseRecoveryWindows * 2)
        for _ in 1..<rate.recoveryWindows { do { let changed = rate.update(quiet); #expect(!changed) } }
        do { let changed = rate.update(quiet); #expect(changed) }
        // Holding well at the restored level earns the quick recovery back.
        for _ in 0..<25 { _ = rate.update(quiet) }
        #expect(rate.recoveryWindows == RateController.baseRecoveryWindows)
    }
}

/// `HostSession` over an in-memory link with a bandwidth limit, the real HEVC encoder and
/// incompressible frames: the stream must shrink to fit, tell the phone, and come back.
@Suite(.timeLimit(.minutes(1)))
struct LinkAdaptationTests {
    @Test func weakLinkShrinksTheStreamThenRecovers() async throws {
        let (hostEnd, phone) = LoopbackSession.pair()
        let link = ThrottledSession(hostEnd, bitsPerSecond: 2_000_000)
        let frames = SyntheticFrameSource(noisy: true)
        let session = HostSession(session: link, peer: Fingerprint(bytes: Data(repeating: 7, count: 32)),
                                  configuration: .init(hostName: "Test", adaptInterval: .milliseconds(200)),
                                  frameSource: frames, input: RecordingInputSink(),
                                  pairing: TrustEveryone())
        let host = Task { try await session.run() }
        let video = Task { for try await _ in phone.videoFrames {} }
        defer { video.cancel() }
        try await phone.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 390, height: 844, scale: 3))))

        var configs: [StreamConfig] = []
        var qualities: [LinkQuality] = []
        var messages = phone.controlMessages.makeAsyncIterator()
        func next() async throws -> ControlMessage? {
            while let message = try await messages.next() {
                if case .ping(let value) = message { try await phone.send(.pong(value)); continue }
                if case .streamConfig(let config) = message { configs.append(config) }
                if case .linkQuality(let quality) = message { qualities.append(quality) }
                return message
            }
            return nil
        }

        // Down: bitrate, then frame rate, then a smaller picture, with the phone told it's weak.
        while try await next() != nil {
            if let last = configs.last, last.width < configs[0].width, qualities.last?.isWeak == true { break }
        }
        let full = configs[0]
        let shrunk = configs.last!
        #expect(full.fps == 60)
        #expect(shrunk.fps <= 30)
        #expect(shrunk.width * 3 == full.width * 2 || abs(shrunk.width - full.width * 2 / 3) <= 2)
        #expect(Double(shrunk.width) / Double(shrunk.height) - Double(full.width) / Double(full.height) < 0.01)
        #expect(qualities.contains { $0.bitrateKbps < full.bitrateKbps && $0.fps == 60 })
        #expect(qualities.last!.bitrateKbps < full.bitrateKbps / 2)

        // Up again once the link clears. (Ordinary frames: at the bottom rung the encoder skips
        // most pure-noise frames, which would look like a still screen.)
        link.bitsPerSecond.store(0, ordering: .relaxed)
        await frames.setNoisy(false)
        while try await next() != nil {
            if qualities.last?.isWeak == false { break }
        }
        #expect(qualities.last?.isWeak == false)

        try await phone.send(.bye(reason: "done"))
        try await host.value
    }
}

private struct TrustEveryone: PairingAuthority {
    func isTrusted(_ peer: Fingerprint) async -> Bool { true }
    func approve(peer: Fingerprint, deviceName: String, token: [UInt8]) async -> Bool { true }
}

#endif
