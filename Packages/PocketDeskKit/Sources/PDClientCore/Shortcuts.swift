import Foundation
import PDProtocol

/// A one-tap action on the Mac, shown as a tile on the phone (like the Shortcuts app).
public struct Shortcut: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// An SF Symbol name.
    public var symbol: String
    public var color: ShortcutColor
    public var action: MacAction
    /// Whether tapping it opens the stream. `nil` (and shortcuts saved before this existed)
    /// follows the action: media keys run in the background, everything else shows the Mac.
    public var showsMac: Bool?

    public init(id: UUID = UUID(), name: String, symbol: String, color: ShortcutColor, action: MacAction,
                showsMac: Bool? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.action = action
        self.showsMac = showsMac
    }

    /// What a tap does: open the stream, or run quietly and stay put.
    public var opensStream: Bool { showsMac ?? action.needsPicture }

    /// The Mac app this opens, if it opens one by bundle ID (for its icon).
    public var appBundleID: String? {
        if case .openApp(let bundleID, _) = action { bundleID } else { nil }
    }

    /// The same shortcut under a new identity, for "Duplicate" and for adding a preset twice.
    public func copy() -> Shortcut {
        Shortcut(name: name, symbol: symbol, color: color, action: action, showsMac: showsMac)
    }
}

/// Tile colors, by name so the UI layer picks the actual shades.
public enum ShortcutColor: String, Codable, Sendable, CaseIterable {
    case red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, brown, gray
}

/// Saved shortcuts, in the order they're shown. Pure value: `SessionController` persists it.
public struct ShortcutLibrary: Codable, Sendable, Equatable {
    public private(set) var shortcuts: [Shortcut]

    public init(shortcuts: [Shortcut] = ShortcutLibrary.starters) {
        self.shortcuts = shortcuts
    }

    /// Adds a new shortcut, or replaces the one with the same ID.
    public mutating func save(_ shortcut: Shortcut) {
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[index] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
    }

    public mutating func delete(_ id: Shortcut.ID) {
        shortcuts.removeAll { $0.id == id }
    }

    public mutating func duplicate(_ id: Shortcut.ID) {
        guard let index = shortcuts.firstIndex(where: { $0.id == id }) else { return }
        shortcuts.insert(shortcuts[index].copy(), at: index + 1)
    }

    /// Moves `id` to where `target` is (drag to reorder).
    public mutating func move(_ id: Shortcut.ID, to target: Shortcut.ID) {
        guard id != target, let from = shortcuts.firstIndex(where: { $0.id == id }),
              let to = shortcuts.firstIndex(where: { $0.id == target }) else { return }
        shortcuts.insert(shortcuts.remove(at: from), at: to)
    }

    /// Where the app keeps its shortcuts: the App Group container, so the widget extension and
    /// Siri see the same list. Falls back to the app's own folder when there's no group (tests,
    /// unsigned builds), moving an older copy across the first time.
    public static var sharedURL: URL {
        let legacy = URL.applicationSupportDirectory.appending(path: "PocketDesk/shortcuts.json")
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return legacy
        }
        let shared = group.appending(path: "shortcuts.json")
        if !FileManager.default.fileExists(atPath: shared.path(percentEncoded: false)),
           FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)) {
            try? FileManager.default.copyItem(at: legacy, to: shared)
        }
        return shared
    }

    public static let appGroup = "group.com.pocketdesk.app"

    public static func load(from url: URL) throws -> ShortcutLibrary {
        try JSONDecoder().decode(ShortcutLibrary.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    /// What a new install starts with.
    public static var starters: [Shortcut] {
        ["Netflix", "YouTube", "Music", "Safari", "Spotlight", "Mission Control"].compactMap { name in
            ShortcutPreset.all.first { $0.shortcut.name == name }?.shortcut.copy()
        }
    }
}

/// Ready-made shortcuts offered in the editor.
public struct ShortcutPreset: Sendable, Identifiable {
    public enum Category: String, Sendable, CaseIterable {
        case websites = "Websites", apps = "Apps", controls = "Mac Controls"
    }

    public var category: Category
    public var shortcut: Shortcut
    public var id: String { shortcut.name }

    // CGEventFlags bits and kVK_* codes (Carbon's Events.h), spelled out so this stays
    // portable to iOS.
    public static let command: UInt32 = 0x10_0000
    public static let control: UInt32 = 0x4_0000
    public static let option: UInt32 = 0x8_0000
    public static let shift: UInt32 = 0x2_0000

    public static let all: [ShortcutPreset] = [
        website("Netflix", "https://www.netflix.com", symbol: "play.tv.fill", color: .red),
        website("YouTube", "https://www.youtube.com", symbol: "play.rectangle.fill", color: .red),
        website("Prime Video", "https://www.primevideo.com", symbol: "film.fill", color: .blue),
        website("Disney+", "https://www.disneyplus.com", symbol: "sparkles.tv.fill", color: .indigo),
        website("Twitch", "https://www.twitch.tv", symbol: "gamecontroller.fill", color: .purple),
        website("Gmail", "https://mail.google.com", symbol: "envelope.fill", color: .orange),
        website("GitHub", "https://github.com", symbol: "chevron.left.forwardslash.chevron.right", color: .gray),
        app("Safari", "com.apple.Safari", symbol: "safari.fill", color: .blue),
        app("Music", "com.apple.Music", symbol: "music.note", color: .pink),
        app("Spotify", "com.spotify.client", symbol: "headphones", color: .green),
        app("Messages", "com.apple.MobileSMS", symbol: "message.fill", color: .green),
        app("Mail", "com.apple.mail", symbol: "envelope.fill", color: .blue),
        app("Notes", "com.apple.Notes", symbol: "note.text", color: .yellow),
        app("Calendar", "com.apple.iCal", symbol: "calendar", color: .red),
        app("Photos", "com.apple.Photos", symbol: "photo.on.rectangle", color: .orange),
        app("Finder", "com.apple.finder", symbol: "folder.fill", color: .teal),
        app("Terminal", "com.apple.Terminal", symbol: "terminal.fill", color: .gray),
        app("Xcode", "com.apple.dt.Xcode", symbol: "hammer.fill", color: .blue),
        app("VS Code", "com.microsoft.VSCode", symbol: "curlybraces", color: .blue),
        app("Slack", "com.tinyspeck.slackmacgap", symbol: "number", color: .purple),
        keys("Spotlight", code: 0x31, command, symbol: "magnifyingglass", color: .gray),
        keys("Mission Control", code: 0x7E, control, symbol: "rectangle.3.group.fill", color: .indigo),
        keys("Switch App", code: 0x30, command, symbol: "square.stack.3d.forward.dottedline.fill", color: .teal),
        keys("Full Screen", code: 0x03, command | control, symbol: "arrow.up.left.and.arrow.down.right", color: .mint),
        keys("Close Window", code: 0x0D, command, symbol: "xmark.square.fill", color: .orange),
        keys("Quit App", code: 0x0C, command, symbol: "power", color: .red),
        keys("Lock Mac", code: 0x0C, command | control, symbol: "lock.fill", color: .gray),
        media("Play / Pause", .playPause, symbol: "playpause.fill", color: .red),
        media("Next Track", .next, symbol: "forward.fill", color: .pink),
        media("Previous Track", .previous, symbol: "backward.fill", color: .pink),
        media("Volume Up", .volumeUp, symbol: "speaker.wave.3.fill", color: .blue),
        media("Volume Down", .volumeDown, symbol: "speaker.wave.1.fill", color: .blue),
        media("Mute", .mute, symbol: "speaker.slash.fill", color: .gray),
    ]

    private static func website(_ name: String, _ url: String, symbol: String, color: ShortcutColor) -> ShortcutPreset {
        ShortcutPreset(category: .websites,
                       shortcut: Shortcut(name: name, symbol: symbol, color: color, action: .openURL(url)))
    }

    private static func app(_ name: String, _ bundleID: String, symbol: String, color: ShortcutColor) -> ShortcutPreset {
        ShortcutPreset(category: .apps, shortcut: Shortcut(name: name, symbol: symbol, color: color,
                                                           action: .openApp(bundleID: bundleID, name: name)))
    }

    private static func media(_ name: String, _ key: MediaKey, symbol: String, color: ShortcutColor) -> ShortcutPreset {
        ShortcutPreset(category: .controls, shortcut: Shortcut(name: name, symbol: symbol, color: color, action: .media(key)))
    }

    private static func keys(_ name: String, code: UInt16, _ modifiers: UInt32, symbol: String,
                             color: ShortcutColor) -> ShortcutPreset {
        ShortcutPreset(category: .controls, shortcut: Shortcut(name: name, symbol: symbol, color: color,
                                                               action: .keystroke(code: code, modifiers: modifiers)))
    }
}

extension MacAction {
    /// Whether a tap shows the Mac unless the shortcut says otherwise. Media keys, volume and
    /// Mac Shortcuts you hear or feel, not see; steps need it if any of theirs does.
    public var needsPicture: Bool {
        switch self {
        case .media, .setVolume, .wait, .runShortcut: false
        case .steps(let steps): steps.contains(where: \.needsPicture)
        case .openURL, .openApp, .keystroke: true
        }
    }

    /// One line for the editor and tiles: "netflix.com", "Opens Music", "⌃↑".
    public var summary: String {
        switch self {
        case .openURL(let string):
            let host = URL(string: string)?.host() ?? string
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        case .openApp(_, let name):
            return "Opens \(name)"
        case .keystroke(let code, let modifiers):
            return Self.keyName(code: code, modifiers: modifiers)
        case .media(let key):
            return switch key {
            case .playPause: "Play / Pause"
            case .next: "Next track"
            case .previous: "Previous track"
            case .volumeUp: "Volume up"
            case .volumeDown: "Volume down"
            case .mute: "Mute"
            }
        case .runShortcut(_, let name):
            return "Runs “\(name)”"
        case .setVolume(let level):
            return "Volume \(level)%"
        case .wait(let milliseconds):
            return milliseconds % 1000 == 0 ? "Wait \(milliseconds / 1000) s"
                : "Wait \((Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(1)))) s"
        case .steps(let steps):
            return steps.count == 1 ? steps[0].summary : "\(steps.count) steps"
        }
    }

    static func keyName(code: UInt16, modifiers: UInt32) -> String {
        var name = ""
        if modifiers & ShortcutPreset.control != 0 { name += "⌃" }
        if modifiers & ShortcutPreset.option != 0 { name += "⌥" }
        if modifiers & ShortcutPreset.shift != 0 { name += "⇧" }
        if modifiers & ShortcutPreset.command != 0 { name += "⌘" }
        let keys: [UInt16: String] = [0x31: "Space", 0x7E: "↑", 0x7D: "↓", 0x7B: "←", 0x7C: "→", 0x30: "⇥",
                                      0x24: "↩", 0x35: "⎋", 0x03: "F", 0x0C: "Q", 0x0D: "W"]
        return name + (keys[code] ?? "Key \(code)")
    }
}
