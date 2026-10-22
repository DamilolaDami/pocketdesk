#if os(macOS)
import Foundation
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDHostCore

/// `HostSession` over a loopback pair with a fake Mac clipboard.
@Suite(.timeLimit(.minutes(1)))
struct ClipboardTests {
    private let clipboard = FakeClipboard()

    /// Runs a streaming session; `body` gets the phone's end and a reader for control messages.
    private func withSession(clipboardEnabled: Bool = true,
                             _ body: (LoopbackSession, () async throws -> ControlMessage?) async throws -> Void) async throws {
        let (hostEnd, phone) = LoopbackSession.pair()
        let session = HostSession(session: hostEnd, peer: Fingerprint(bytes: Data(repeating: 3, count: 32)),
                                  configuration: .init(hostName: "Test", clipboardInterval: .milliseconds(20)),
                                  frameSource: SyntheticFrameSource(), input: RecordingInputSink(),
                                  pairing: TrustEveryone(), clipboard: clipboard)
        let host = Task { try await session.run() }
        let video = Task { for try await _ in phone.videoFrames {} }
        defer { video.cancel() }
        try await phone.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 390, height: 844, scale: 3),
                                          clipboardEnabled: clipboardEnabled)))
        var messages = phone.controlMessages.makeAsyncIterator()
        let next: () async throws -> ControlMessage? = {
            while let message = try await messages.next() {
                switch message {
                case .ping(let value): try await phone.send(.pong(value))
                case .helloAck, .streamConfig, .linkQuality: continue
                default: return message
                }
            }
            return nil
        }
        // Sharing starts with the stream; what was copied before that stays on the Mac.
        while let message = try await messages.next() {
            if case .ping(let value) = message { try await phone.send(.pong(value)) }
            if case .streamConfig = message { break }
        }
        try await Task.sleep(for: .milliseconds(100))
        try await body(phone, next)
        try await phone.send(.bye(reason: "done"))
        try await host.value
    }

    @Test func copyingOnTheMacReachesThePhone() async throws {
        try await withSession { _, next async throws in
            await clipboard.copy(ClipboardItem(text: "hello from the Mac"))
            #expect(try await next() == .clipboard(ClipboardItem(text: "hello from the Mac")))
            await clipboard.copy(ClipboardItem(png: "iVBORw0KGgo="))
            #expect(try await next() == .clipboard(ClipboardItem(png: "iVBORw0KGgo=")))
        }
    }

    @Test func thePhonesClipboardLandsOnTheMacWithoutComingBack() async throws {
        try await withSession { phone, next in
            try await phone.send(.clipboard(ClipboardItem(text: "from the phone")))
            // Give the poller a few rounds to (wrongly) echo it, then copy something real.
            try await Task.sleep(for: .milliseconds(150))
            await clipboard.copy(ClipboardItem(text: "next"))
            #expect(try await next() == .clipboard(ClipboardItem(text: "next")))
        }
        #expect(await clipboard.written == [ClipboardItem(text: "from the phone")])
    }

    @Test func turnedOffNothingIsShared() async throws {
        try await withSession(clipboardEnabled: false) { phone, next in
            try await phone.send(.clipboard(ClipboardItem(text: "ignored")))
            await clipboard.copy(ClipboardItem(text: "private"))
            try await Task.sleep(for: .milliseconds(150))
            // Turned on mid-session: only what's copied from now on goes out.
            try await phone.send(.setClipboardEnabled(true))
            try await Task.sleep(for: .milliseconds(100))
            await clipboard.copy(ClipboardItem(text: "shared"))
            #expect(try await next() == .clipboard(ClipboardItem(text: "shared")))
        }
        #expect(await clipboard.written.isEmpty)
    }

    @Test func oversizedItemsAreRefused() {
        #expect(ClipboardItem(text: String(repeating: "a", count: 10)).fitsLimits)
        #expect(!ClipboardItem(text: String(repeating: "a", count: ClipboardItem.maxTextBytes + 1)).fitsLimits)
        #expect(!ClipboardItem(png: String(repeating: "A", count: ClipboardItem.maxImageBytes * 2)).fitsLimits)
    }
}
#endif
