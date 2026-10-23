#if os(macOS)
import Foundation
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDHostCore

@Suite(.timeLimit(.minutes(1)))
struct QualityTests {
    @Test func ceilingsGetSmaller() {
        let best = QualityCeiling(.best), balanced = QualityCeiling(.balanced), saver = QualityCeiling(.batterySaver)
        #expect(best.zoomHeadroom > balanced.zoomHeadroom && balanced.zoomHeadroom > saver.zoomHeadroom)
        #expect(saver.fps == 30 && balanced.fps == 60)
        #expect(saver.bitrate < balanced.bitrate && balanced.bitrate < best.bitrate)
    }

    @Test func batterySaverRestartsTheStreamSmaller() async throws {
        let (hostEnd, phone) = LoopbackSession.pair()
        let session = HostSession(session: hostEnd, peer: Fingerprint(bytes: Data(repeating: 5, count: 32)),
                                  configuration: .init(hostName: "Test"), frameSource: SyntheticFrameSource(),
                                  input: RecordingInputSink(), pairing: TrustEveryone(), clipboard: FakeClipboard())
        let host = Task { try await session.run() }
        let video = Task { for try await _ in phone.videoFrames {} }
        defer { video.cancel() }
        try await phone.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 390, height: 844, scale: 3))))
        var control = PhoneControl(phone)
        func nextConfig() async throws -> StreamConfig? {
            while let message = try await control.next() {
                if case .streamConfig(let config) = message { return config }
            }
            return nil
        }
        let best = try #require(try await nextConfig())
        try await phone.send(.setQuality(.batterySaver))
        let saver = try #require(try await nextConfig())
        #expect(saver.fps == 30)
        #expect(saver.width < best.width && saver.height < best.height)
        #expect(saver.bitrateKbps < best.bitrateKbps)
        try await phone.send(.bye(reason: "done"))
        try await host.value
    }
}
#endif
