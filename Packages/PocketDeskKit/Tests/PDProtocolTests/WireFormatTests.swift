import Foundation
import Testing
@testable import PDProtocol

@Suite struct InputEventTests {
    @Test(arguments: [
        InputEvent.pointerMove(x: 0.25, y: 0.75),
        .button(.right, isDown: true, x: 1, y: 0),
        .scroll(dx: -3.5, dy: 12),
        .key(code: 0x24, isDown: false, modifiers: 0x0010_0000),
    ])
    func roundTrips(_ event: InputEvent) throws {
        let bytes = event.encoded()
        #expect(bytes.count <= InputEvent.maxEncodedSize)
        #expect(try InputEvent(decoding: bytes) == event)
    }

    @Test func rejectsTruncatedInput() {
        let bytes = InputEvent.pointerMove(x: 1, y: 1).encoded().dropLast()
        #expect(throws: WireError.truncated) { try InputEvent(decoding: bytes) }
    }

    @Test func rejectsUnknownTag() {
        #expect(throws: WireError.unknownTag) { try InputEvent(decoding: [0xFF]) }
    }
}

@Suite struct VideoFrameHeaderTests {
    @Test func roundTrips() throws {
        let header = VideoFrameHeader(frameID: 42, captureTimeMicros: 1_234_567_890_123,
                                      flags: [.keyframe, .parameterSets], payloadLength: 65_000,
                                      sourceGeneration: 3)
        var bytes: [UInt8] = []
        header.encode(into: &bytes)
        #expect(bytes.count == VideoFrameHeader.encodedSize)
        #expect(try VideoFrameHeader(decoding: bytes) == header)
    }
}

@Suite struct ControlMessageTests {
    @Test func codableRoundTrip() throws {
        let message = ControlMessage.hello(Hello(deviceName: "iPhone",
                                                 viewport: Viewport(width: 402, height: 874, scale: 3)))
        let data = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(ControlMessage.self, from: data) == message)
    }

    @Test(arguments: [
        MacAction.openURL("https://www.netflix.com"),
        .openApp(bundleID: "com.apple.Music", name: "Music"),
        .openApp(bundleID: nil, name: "Spotify"),
        .keystroke(code: 0x31, modifiers: 0x100000),
    ])
    func actionsRoundTrip(_ action: MacAction) throws {
        let data = try JSONEncoder().encode(ControlMessage.run(action))
        #expect(try JSONDecoder().decode(ControlMessage.self, from: data) == .run(action))
    }
}
