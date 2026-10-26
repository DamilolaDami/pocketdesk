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
    /// Asks "Run …?" before it does anything: for Quit, Sleep and the like.
    public var asksFirst: Bool?
    /// Always runs on this Mac, whatever Settings › Run On says. `nil` follows Settings.
    public var macID: UUID?

    public init(id: UUID = UUID(), name: String, symbol: String, color: ShortcutColor, action: MacAction,
                showsMac: Bool? = nil, asksFirst: Bool? = nil, macID: UUID? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.color = color
        self.action = action
        self.showsMac = showsMac
        self.asksFirst = asksFirst
        self.macID = macID
    }

    /// Whether a tap asks before running.
    public var confirms: Bool { asksFirst ?? false }

    /// What a tap does: open the stream, or run quietly and stay put.
    public var opensStream: Bool { showsMac ?? action.needsPicture }

    /// The Mac app this opens, if it opens one by bundle ID (for its icon).
    public var appBundleID: String? {
        if case .openApp(let bundleID, _) = action { bundleID } else { nil }
    }

    /// The same shortcut under a new identity, for "Duplicate" and for adding a preset twice.
    public func copy() -> Shortcut {
        Shortcut(name: name, symbol: symbol, color: color, action: action, showsMac: showsMac,
                 asksFirst: asksFirst, macID: macID)
    }
}

// MARK: Sharing

extension Shortcut {
    /// Longer links than this aren't shortcuts anyone typed.
    public static let maxSharedLength = 24_000

    /// `pocketdesk://add?shortcut=…`: opens PocketDesk on another phone with this shortcut in
    /// the editor, to look over before saving. Leaves out its ID and its Mac, which mean
    /// nothing on another phone.
    public var sharingURL: URL {
        var shared = self
        shared.macID = nil
        let json = (try? JSONEncoder().encode(shared)) ?? Data()
        let encoded = json.base64EncodedString()
            .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
        var components = URLComponents()
        components.scheme = "pocketdesk"
        components.host = "add"
        components.queryItems = [URLQueryItem(name: "shortcut", value: encoded)]
        return components.url!
    }

    /// The shortcut a `sharingURL` carries, under a new ID. `nil` for anything else, or for one
    /// the Mac wouldn't run.
    public init?(sharingURL url: URL) {
        guard url.scheme == "pocketdesk", url.host() == "add", url.absoluteString.count <= Self.maxSharedLength,
              var encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "shortcut" })?.value else { return nil }
        encoded = encoded.replacing("-", with: "+").replacing("_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let json = Data(base64Encoded: encoded),
              let shared = try? JSONDecoder().decode(Shortcut.self, from: json),
              shared.action.isValid,
              !shared.name.trimmingCharacters(in: .whitespaces).isEmpty, shared.name.count <= 100 else { return nil }
        self = shared.copy()
        macID = nil
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

    /// Puts shortcuts in this order (after a drag). IDs it doesn't know are ignored, and any
    /// it leaves out keep their place at the end, so a stale list can't lose a shortcut.
    public mutating func reorder(_ ids: [Shortcut.ID]) {
        let byID = Dictionary(uniqueKeysWithValues: shortcuts.map { ($0.id, $0) })
        var seen = Set<Shortcut.ID>()
        let ordered = ids.compactMap { id in seen.insert(id).inserted ? byID[id] : nil }
        shortcuts = ordered + shortcuts.filter { !seen.contains($0.id) }
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

    /// From the app's Info.plist, which takes it from the build (see `BUNDLE_ID_PREFIX`).
    public static let appGroup = Bundle.main.object(forInfoDictionaryKey: "PDAppGroup") as? String ?? "group.com.pocketdesk.app"

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
        case websites = "Websites", apps = "Apps", text = "Text", controls = "Mac Controls"
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
        website("Search YouTube", "https://www.youtube.com/results?search_query={text}", symbol: "magnifyingglass", color: .red),
        website("Search Netflix", "https://www.netflix.com/search?q={text}", symbol: "magnifyingglass", color: .red),
        website("Search Google", "https://www.google.com/search?q={text}", symbol: "magnifyingglass", color: .blue),
        website("Find in Maps", "https://maps.apple.com/?q={text}", symbol: "map.fill", color: .green),
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
        command("Lock Mac", .lockScreen, symbol: "lock.fill", color: .gray),
        command("Sleep Display", .sleepDisplay, symbol: "display", color: .indigo),
        command("Sleep Mac", .sleep, symbol: "moon.zzz.fill", color: .indigo, asksFirst: true),
        command("Dark Mode", .toggleDarkMode, symbol: "circle.lefthalf.filled", color: .gray),
        command("Screenshot", .screenshot, symbol: "camera.viewfinder", color: .teal),
        ShortcutPreset(category: .apps, shortcut: Shortcut(
            name: "Quit Music", symbol: "xmark.circle.fill", color: .red,
            action: .quitApp(bundleID: "com.apple.Music", name: "Music"))),
        text("Type on Mac", .typeText(MacAction.textPlaceholder), symbol: "keyboard.fill", color: .blue),
        text("Copy to Mac", .copyText(MacAction.textPlaceholder), symbol: "doc.on.clipboard.fill", color: .indigo),
        text("Type Today's Date", .typeText(MacAction.datePlaceholder), symbol: "calendar", color: .orange),
        text("Type the Time", .typeText(MacAction.timePlaceholder), symbol: "clock.fill", color: .orange),
        ShortcutPreset(category: .text, shortcut: Shortcut(
            name: "Search the Web", symbol: "magnifyingglass", color: .blue,
            // Spotlight, then the words, then Return: whatever the Mac's default search is.
            action: .steps([.keystroke(code: 0x31, modifiers: command), .wait(milliseconds: 400),
                            .typeText(MacAction.textPlaceholder + "\n")]))),
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

    private static func command(_ name: String, _ command: MacCommand, symbol: String, color: ShortcutColor,
                                asksFirst: Bool? = nil) -> ShortcutPreset {
        ShortcutPreset(category: .controls, shortcut: Shortcut(name: name, symbol: symbol, color: color,
                                                               action: .system(command), asksFirst: asksFirst))
    }

    private static func text(_ name: String, _ action: MacAction, symbol: String, color: ShortcutColor) -> ShortcutPreset {
        ShortcutPreset(category: .text, shortcut: Shortcut(name: name, symbol: symbol, color: color, action: action))
    }

    private static func keys(_ name: String, code: UInt16, _ modifiers: UInt32, symbol: String,
                             color: ShortcutColor) -> ShortcutPreset {
        ShortcutPreset(category: .controls, shortcut: Shortcut(name: name, symbol: symbol, color: color,
                                                               action: .keystroke(code: code, modifiers: modifiers)))
    }
}

extension MacAction {
    /// Where your words go in a website shortcut: `youtube.com/results?search_query={text}`.
    public static let textPlaceholder = "{text}"

    /// Today's date and the time, as the phone has them when it runs ("26 October 2026", "11:45").
    public static let datePlaceholder = "{date}"
    public static let timePlaceholder = "{time}"

    /// It needs words before it can run (a search, say): the phone asks first.
    public var asksForText: Bool {
        switch self {
        case .openURL(let text), .typeText(let text), .copyText(let text): text.contains(Self.textPlaceholder)
        case .steps(let steps): steps.contains(where: \.asksForText)
        default: false
        }
    }

    /// With the words in place (URL-encoded in links); in every step of a routine.
    public func filling(_ text: String) -> MacAction {
        replacing(Self.textPlaceholder, with: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// With `{date}` and `{time}` filled in for `now`.
    public func fillingClock(_ now: Date = .now) -> MacAction {
        replacing(Self.datePlaceholder, with: now.formatted(date: .long, time: .omitted))
            .replacing(Self.timePlaceholder, with: now.formatted(date: .omitted, time: .shortened))
    }

    private func replacing(_ placeholder: String, with value: String) -> MacAction {
        switch self {
        case .openURL(let url):
            let encoded = value.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? ""
            return .openURL(url.replacing(placeholder, with: encoded))
        case .typeText(let text):
            return .typeText(text.replacing(placeholder, with: value))
        case .copyText(let text):
            return .copyText(text.replacing(placeholder, with: value))
        case .steps(let steps):
            return .steps(steps.map { $0.replacing(placeholder, with: value) })
        default:
            return self
        }
    }

    /// RFC 3986's unreserved characters: everything else is escaped, spaces as `%20`.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// The site, for its favicon, with any placeholder taken out.
    public var website: String? {
        if case .openURL(let url) = self { url.replacing(Self.textPlaceholder, with: "") } else { nil }
    }

    /// Whether a tap shows the Mac unless the shortcut says otherwise. Media keys, volume and
    /// Mac Shortcuts you hear or feel, not see; steps need it if any of theirs does.
    public var needsPicture: Bool {
        switch self {
        case .media, .mediaIn, .setVolume, .wait, .runShortcut, .copyText, .quitApp, .system: false
        case .steps(let steps): steps.contains(where: \.needsPicture)
        case .openURL, .openApp, .keystroke, .typeText: true
        }
    }

    /// One line for the editor and tiles: "netflix.com", "Opens Music", "⌃↑".
    public var summary: String {
        switch self {
        case .openURL(let string):
            let template = string.contains(Self.textPlaceholder)
            let plain = string.replacing(Self.textPlaceholder, with: "")
            let host = URL(string: plain)?.host() ?? plain
            let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return template ? "\(site) · asks first" : site
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
        case .mediaIn(let key, let player):
            return "\(MacAction.media(key).summary) · \(player.name)"
        case .runShortcut(_, let name):
            return "Runs “\(name)”"
        case .setVolume(let level):
            return "Volume \(level)%"
        case .wait(let milliseconds):
            return milliseconds % 1000 == 0 ? "Wait \(milliseconds / 1000) s"
                : "Wait \((Double(milliseconds) / 1000).formatted(.number.precision(.fractionLength(1)))) s"
        case .typeText(let text):
            return "Types \(Self.quoted(text))"
        case .copyText(let text):
            return "Copies \(Self.quoted(text))"
        case .quitApp(_, let name):
            return "Quits \(name)"
        case .system(let command):
            return command.title
        case .steps(let steps):
            return steps.count == 1 ? steps[0].summary : "\(steps.count) steps"
        }
    }

    /// A snippet for a summary: “what you type”, or "what you say" for one that asks.
    private static func quoted(_ text: String) -> String {
        if text == textPlaceholder { return "what you say" }
        if text == datePlaceholder { return "today's date" }
        if text == timePlaceholder { return "the time" }
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return "“\(line.count > 24 ? line.prefix(24) + "…" : line)”"
    }

    /// Every placeholder, for the editor's insert buttons.
    public static let placeholders = [textPlaceholder, datePlaceholder, timePlaceholder]

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

extension MacCommand {
    public var title: String {
        switch self {
        case .lockScreen: "Lock screen"
        case .sleepDisplay: "Sleep display"
        case .sleep: "Sleep"
        case .toggleDarkMode: "Dark mode on / off"
        case .screenshot: "Screenshot to Desktop"
        }
    }
}
