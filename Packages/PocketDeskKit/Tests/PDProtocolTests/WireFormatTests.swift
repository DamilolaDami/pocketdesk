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
        .media(.playPause),
        .media(.volumeDown),
        .runShortcut(id: "7DC33540-3D02-4FB6-A1BC-5A12E2FE3B16", name: "Movie Night"),
        .setVolume(60),
        .mediaIn(.playPause, player: .spotify),
        .steps([.openURL("https://www.netflix.com"), .wait(milliseconds: 1500), .keystroke(code: 0x03, modifiers: 0x14_0000)]),
    ])
    func actionsRoundTrip(_ action: MacAction) throws {
        let data = try JSONEncoder().encode(ControlMessage.run(action))
        #expect(try JSONDecoder().decode(ControlMessage.self, from: data) == .run(action))
    }

    @Test func stepsStayWithinLimits() {
        #expect(MacAction.steps([.media(.playPause), .wait(milliseconds: 500)]).isValid)
        #expect(!MacAction.steps([]).isValid)
        #expect(!MacAction.steps([.steps([.media(.mute)])]).isValid) // one level deep
        #expect(!MacAction.steps(Array(repeating: .media(.mute), count: MacAction.maxSteps + 1)).isValid)
        #expect(!MacAction.steps([.wait(milliseconds: 60_000)]).isValid)
        #expect(!MacAction.setVolume(101).isValid)
        #expect(MacAction.mediaIn(.next, player: .music).isValid)
        #expect(!MacAction.mediaIn(.volumeUp, player: .music).isValid) // volume is the Mac's
        #expect(alpn == "pocketdesk/\(protocolVersion)")
    }

    @Test func macShortcutsRoundTrip() throws {
        let messages: [ControlMessage] = [
            .listMacShortcuts, .macShortcuts([MacShortcut(id: "A-1", name: "Focus")]), .watchStatus,
            .macStatus(MacStatus(volume: 60, muted: false,
                                 nowPlaying: NowPlaying(title: "Stranger Things", artist: "Netflix", isPlaying: true))),
            .macStatus(MacStatus()),
            .macStatus(MacStatus(nowPlaying: NowPlaying(title: "Song", isPlaying: false, artwork: "AAAA"),
                                 battery: MacBattery(level: 82, isCharging: true, onPower: true))),
        ]
        for message in messages {
            #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }

    @Test func menuMessagesRoundTrip() throws {
        let file = MenuItem(path: [2], title: "File", children: [
            MenuItem(path: [2, 0], title: "New Window", shortcut: "⌘N"),
            .separator(path: [2, 1]),
            MenuItem(path: [2, 2], title: "Open Recent", children: [MenuItem(path: [2, 2, 0], title: "notes.txt")]),
            MenuItem(path: [2, 3], title: "Show Sidebar", isEnabled: false, isChecked: true),
        ])
        let messages: [ControlMessage] = [
            .watchMenus(true), .watchMenus(false), .menuBar(nil), .getClipboard, .actionDone,
            .menuBar(MenuBar(appName: "Safari", bundleID: "com.apple.Safari", menus: [file])),
            .pressMenuItem(MenuPress(path: [2, 0], title: "New Window")),
            .caret(Caret(x: 0.25, y: 0.5, height: 0.02)),
            .setQuality(.batterySaver),
            .hello(Hello(deviceName: "Phone", viewport: Viewport(width: 400, height: 800, scale: 3), quality: .balanced)),
        ]
        for message in messages {
            #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }

    @Test func displayMessagesRoundTrip() throws {
        let display = DisplayInfo(id: 2, width: 2560, height: 1440, name: "Studio Display", persistentID: "monitor-uuid")
        let messages: [ControlMessage] = [
            .hello(Hello(deviceName: "Phone", viewport: Viewport(width: 400, height: 800, scale: 3), preferredDisplayID: "monitor-uuid")),
            .helloAck(HelloAck(hostName: "Mac", displays: [display])),
            .helloAck(HelloAck(hostName: "Mac", displays: [display], wallpaper: "AAAA")),
            .listDisplays, .displays([display]), .selectDisplay(2),
            .streamConfig(StreamConfig(codec: .hevc, width: 2560, height: 1440, fps: 60, bitrateKbps: 10_000, displayID: 2)),
        ]
        for message in messages {
            #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }

    @Test func catalogMessagesRoundTrip() throws {
        let messages: [ControlMessage] = [
            .hello(Hello(deviceName: "iPhone", viewport: Viewport(width: 1, height: 1, scale: 1), mode: .catalog)),
            .apps([MacApp(name: "Music", bundleID: "com.apple.Music")]),
            .requestAppIcons(["com.apple.Music"]),
            .appIcon(AppIcon(bundleID: "com.apple.Music", png: "iVBORw0KGgo=")),
            .linkQuality(LinkQuality(isWeak: true, bitrateKbps: 2_400, fps: 30, roundTripMillis: 95)),
            .linkQuality(LinkQuality(isWeak: false, bitrateKbps: 18_000, fps: 60)),
            .clipboard(ClipboardItem(text: "copied")),
            .clipboard(ClipboardItem(png: "iVBORw0KGgo=")),
            .setClipboardEnabled(false),
            .key(KeyPress(code: 0x30, isDown: true, modifiers: 1 << 20)),
            .hello(Hello(deviceName: "iPhone", viewport: Viewport(width: 1, height: 1, scale: 1), clipboardEnabled: false)),
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            #expect(try JSONDecoder().decode(ControlMessage.self, from: data) == message)
        }
    }
}
