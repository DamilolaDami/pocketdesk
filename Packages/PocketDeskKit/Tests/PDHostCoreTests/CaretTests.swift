#if os(macOS)
import CoreGraphics
import Foundation
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDHostCore

struct CaretMappingTests {
    @Test func placesTheCaretOnTheStreamedPicture() {
        let caret = Caret(frame: CGRect(x: 480, y: 270, width: 0, height: 18), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(caret == Caret(x: 0.25, y: Float(279.0 / 1080), height: Float(18.0 / 1080)))
    }

    @Test func aWindowOrAnotherDisplayHasItsOwnOrigin() {
        let window = CGRect(x: 100, y: 50, width: 800, height: 600)
        #expect(Caret(frame: CGRect(x: 500, y: 340, width: 0, height: 20), in: window) == Caret(x: 0.5, y: 0.5, height: Float(20.0 / 600)))
        #expect(Caret(frame: CGRect(x: -1280, y: 710, width: 0, height: 20), in: CGRect(x: -2560, y: 0, width: 2560, height: 1440))?.x == 0.5)
    }

    @Test func offThePictureIsNoCaret() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        #expect(Caret(frame: CGRect(x: -400, y: 100, width: 0, height: 18), in: display) == nil)
        #expect(Caret(frame: CGRect(x: 100, y: 1200, width: 0, height: 18), in: display) == nil)
        #expect(Caret(frame: CGRect(x: 100, y: 100, width: 0, height: 18), in: .zero) == nil)
    }
}

/// A caret a test moves.
actor FakeCaret: CaretSource {
    private var frame: CGRect?
    private(set) var reads = 0

    func move(to frame: CGRect?) { self.frame = frame }
    func caretFrame() -> CGRect? {
        reads += 1
        return frame
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HostCaretTests {
    private let caret = FakeCaret()

    private func withSession(_ body: (LoopbackSession, () async throws -> ControlMessage?) async throws -> Void) async throws {
        let (hostEnd, phone) = LoopbackSession.pair()
        var configuration = HostSession.Configuration(hostName: "Test")
        configuration.caretDelay = .milliseconds(20)
        let session = HostSession(session: hostEnd, peer: Fingerprint(bytes: Data(repeating: 5, count: 32)),
                                  configuration: configuration, frameSource: SyntheticFrameSource(),
                                  input: RecordingInputSink(), pairing: TrustEveryone(), clipboard: FakeClipboard(),
                                  menus: FakeMenus(), caret: caret)
        let host = Task { try await session.run() }
        let video = Task { for try await _ in phone.videoFrames {} }
        defer { video.cancel() }
        try await phone.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 390, height: 844, scale: 3))))
        var control = PhoneControl(phone)
        while let message = try await control.next() { if case .streamConfig = message { break } }
        let next: () async throws -> ControlMessage? = {
            while let message = try await control.next() {
                switch message {
                case .helloAck, .streamConfig: continue
                default: return message
                }
            }
            return nil
        }
        try await body(phone, next)
        try await phone.send(.bye(reason: "done"))
        try await host.value
    }

    @Test func typingSendsWhereTheCaretMoved() async throws {
        try await withSession { phone, next in
            await caret.move(to: CGRect(x: 960, y: 531, width: 0, height: 18))
            try await phone.send(.sourceText(generation: 1, text: "hello"))
            #expect(try await next() == .caret(Caret(x: 0.5, y: 0.5, height: Float(18.0 / 1080))))
            await caret.move(to: CGRect(x: 480, y: 531, width: 0, height: 18))
            try await phone.send(.sourceKey(generation: 1, press: KeyPress(code: 36, isDown: true)))
            try await phone.send(.sourceKey(generation: 1, press: KeyPress(code: 36, isDown: false)))
            #expect(try await next() == .caret(Caret(x: 0.25, y: 0.5, height: Float(18.0 / 1080))))
            // Asked for anything after this, the next answer must not be another caret.
            try await phone.send(.ping(7))
            #expect(try await next() == .pong(7))
        }
    }

    @Test func aBurstOfTypingReadsOnceAndAnUnmovedCaretIsntResent() async throws {
        try await withSession { phone, next in
            await caret.move(to: CGRect(x: 960, y: 531, width: 0, height: 18))
            for letter in "abcdef" { try await phone.send(.sourceText(generation: 1, text: String(letter))) }
            guard case .caret? = try await next() else { Issue.record("no caret"); return }
            #expect(await caret.reads == 1)
            try await phone.send(.sourceText(generation: 1, text: "g"))
            try await Task.sleep(for: .milliseconds(100))
            try await phone.send(.ping(8))
            #expect(try await next() == .pong(8))
        }
    }
}
#endif
