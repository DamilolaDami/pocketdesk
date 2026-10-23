#if os(macOS)
import Foundation
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDHostCore

struct MenuShortcutTextTests {
    @Test func commandIsImplied() {
        #expect(MenuShortcutText.text(character: "N", glyph: nil, modifiers: 0) == "⌘N")
        #expect(MenuShortcutText.text(character: "n", glyph: nil, modifiers: nil) == "⌘N")
    }

    @Test func modifiersInTheMacsOrder() {
        #expect(MenuShortcutText.text(character: "F", glyph: nil, modifiers: 1 | 2 | 4) == "⌃⌥⇧⌘F")
        #expect(MenuShortcutText.text(character: "I", glyph: nil, modifiers: 2) == "⌥⌘I")
    }

    @Test func withoutCommand() {
        #expect(MenuShortcutText.text(character: "F", glyph: nil, modifiers: 4 | 8) == "⌃F")
    }

    @Test func glyphsForKeysWithoutACharacter() {
        #expect(MenuShortcutText.text(character: nil, glyph: 0x17, modifiers: 0) == "⌘⌫")
        #expect(MenuShortcutText.text(character: nil, glyph: 0x6F, modifiers: 8) == "F1")
        #expect(MenuShortcutText.text(character: nil, glyph: 0x7A, modifiers: 1) == "⇧⌘F12")
        #expect(MenuShortcutText.text(character: nil, glyph: 0x88, modifiers: 8) == "F14")
        #expect(MenuShortcutText.text(character: " ", glyph: nil, modifiers: 4) == "⌃⌘Space")
    }

    @Test func noKeyNoShortcut() {
        #expect(MenuShortcutText.text(character: nil, glyph: nil, modifiers: 0) == nil)
        #expect(MenuShortcutText.text(character: "", glyph: 0, modifiers: 0) == nil)
    }
}

/// Menus a test controls: `bring` is another app coming forward on the Mac.
actor FakeMenus: MenuBarSource {
    private var app: pid_t = 1
    private var bar = MenuBar(appName: "Safari", menus: [MenuItem(path: [0], title: "File", children: [
        MenuItem(path: [0, 0], title: "New Window", shortcut: "⌘N"),
    ])])
    private(set) var pressed: [MenuPress] = []

    func bring(_ app: pid_t, _ bar: MenuBar) {
        self.app = app
        self.bar = bar
    }

    func frontmostApp() -> pid_t? { app }
    func menuBar() -> MenuBar? { bar }
    func press(_ press: MenuPress) throws {
        guard press.title == "New Window" else { throw MenuPressError.changed }
        pressed.append(press)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HostMenuTests {
    private let menus = FakeMenus()

    private func withSession(_ body: (LoopbackSession, () async throws -> ControlMessage?) async throws -> Void) async throws {
        let (hostEnd, phone) = LoopbackSession.pair()
        let session = HostSession(session: hostEnd, peer: Fingerprint(bytes: Data(repeating: 4, count: 32)),
                                  configuration: .init(hostName: "Test", menusInterval: .milliseconds(20)),
                                  frameSource: SyntheticFrameSource(), input: RecordingInputSink(),
                                  pairing: TrustEveryone(), clipboard: FakeClipboard(), menus: menus)
        let host = Task { try await session.run() }
        let video = Task { for try await _ in phone.videoFrames {} }
        defer { video.cancel() }
        try await phone.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 390, height: 844, scale: 3))))
        var control = PhoneControl(phone)
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

    @Test func sendsTheMenusThenFollowsTheFrontmostApp() async throws {
        try await withSession { phone, next in
            try await phone.send(.watchMenus(true))
            guard case .menuBar(let bar)? = try await next() else { Issue.record("no menus"); return }
            #expect(bar?.appName == "Safari")
            let notes = MenuBar(appName: "Notes", menus: [MenuItem(path: [0], title: "Format", children: [])])
            await menus.bring(2, notes)
            #expect(try await next() == .menuBar(notes))
        }
    }

    @Test func pressingAnItemSendsFreshMenus() async throws {
        try await withSession { phone, next in
            try await phone.send(.watchMenus(true))
            _ = try await next()
            try await phone.send(.pressMenuItem(MenuPress(path: [0, 0], title: "New Window")))
            guard case .menuBar? = try await next() else { Issue.record("no fresh menus"); return }
            try await phone.send(.pressMenuItem(MenuPress(path: [0, 0], title: "Close Window")))
            #expect(try await next() == .actionFailed(MenuPressError.changed.description))
        }
        #expect(await menus.pressed == [MenuPress(path: [0, 0], title: "New Window")])
    }
}
#endif
