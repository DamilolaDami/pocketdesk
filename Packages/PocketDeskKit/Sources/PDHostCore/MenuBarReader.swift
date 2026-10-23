#if os(macOS)
import AppKit
import ApplicationServices
import PDProtocol

/// The frontmost app's menus, for the phone to show as native menus.
public protocol MenuBarSource: Sendable {
    /// The frontmost app's process ID, to notice it changing.
    func frontmostApp() async -> pid_t?
    /// Its menu bar, or `nil` if there's no frontmost app or its menus can't be read.
    func menuBar() async -> MenuBar?
    func press(_ press: MenuPress) async throws
}

public enum MenuPressError: Error, Sendable, Equatable, CustomStringConvertible {
    case notAllowed, changed, failed

    public var description: String {
        switch self {
        case .notAllowed: "PocketDesk needs the Accessibility permission on the Mac to use its menus."
        case .changed: "That menu changed on the Mac. Try again."
        case .failed: "The Mac couldn't choose that menu item."
        }
    }
}

/// Reads and presses menus through the Accessibility API (the grant input already needs).
/// Menus are read without opening them, so the Mac's screen doesn't change.
public struct AccessibilityMenus: MenuBarSource {
    /// How long one Accessibility call may wait on a busy app.
    static let readTimeout: Float = 1
    /// Pressing can wait on whatever the item does (a dialog, say); it still happens.
    static let pressTimeout: Float = 0.5

    public init() {}

    public func frontmostApp() async -> pid_t? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    public func menuBar() async -> MenuBar? {
        guard AXIsProcessTrusted() else { return nil }
        let front = await MainActor.run {
            NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.localizedName ?? "App", $0.bundleIdentifier) }
        }
        guard let (pid, name, bundleID) = front else { return nil }
        // Hundreds of round trips to another process: keep them off the caller's executor.
        return await Task.detached {
            guard let bar = Self.menuBarElement(pid: pid, timeout: Self.readTimeout) else { return nil }
            var budget = MenuBar.maxItems
            let menus = Self.children(of: bar).enumerated().map { index, item in
                let values = Self.values(of: item)
                let items = values.children.first.map { Self.items(in: $0, path: [index], depth: 1, budget: &budget) } ?? []
                return MenuItem(path: [index], title: values.title, isEnabled: values.isEnabled, children: items)
            }
            return MenuBar(appName: name, bundleID: bundleID, menus: menus.filter { !$0.title.isEmpty })
        }.value
    }

    public func press(_ press: MenuPress) async throws {
        guard AXIsProcessTrusted() else { throw MenuPressError.notAllowed }
        guard press.path.count >= 2, let pid = await frontmostApp() else { throw MenuPressError.changed }
        try await Task.detached {
            guard var element = Self.menuBarElement(pid: pid, timeout: Self.pressTimeout) else { throw MenuPressError.changed }
            for (level, index) in press.path.enumerated() {
                // Below the bar, each level sits inside the item's one AXMenu child.
                if level > 0 {
                    guard let menu = Self.children(of: element).first else { throw MenuPressError.changed }
                    element = menu
                }
                let items = Self.children(of: element)
                guard items.indices.contains(index) else { throw MenuPressError.changed }
                element = items[index]
            }
            guard Self.values(of: element).title == press.title else { throw MenuPressError.changed }
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            // "Cannot complete" means the item is still busy doing its thing (a dialog is up).
            guard result == .success || result == .cannotComplete else { throw MenuPressError.failed }
        }.value
    }

    // MARK: Reading

    private static func menuBarElement(pid: pid_t, timeout: Float) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        return (bar as! AXUIElement)
    }

    private static func items(in menu: AXUIElement, path: [Int], depth: Int, budget: inout Int) -> [MenuItem] {
        var items: [MenuItem] = []
        for (index, element) in children(of: menu).prefix(MenuBar.maxItemsPerMenu).enumerated() {
            guard budget > 0 else { break }
            budget -= 1
            let values = values(of: element)
            let itemPath = path + [index]
            var submenu: [MenuItem]?
            if let menu = values.children.first {
                submenu = depth < MenuBar.maxDepth ? Self.items(in: menu, path: itemPath, depth: depth + 1, budget: &budget) : []
            }
            if values.title.isEmpty, submenu == nil {
                items.append(.separator(path: itemPath))
                continue
            }
            items.append(MenuItem(path: itemPath, title: values.title, isEnabled: values.isEnabled,
                                  isChecked: values.isChecked,
                                  shortcut: MenuShortcutText.text(character: values.character, glyph: values.glyph,
                                                                  modifiers: values.modifiers),
                                  children: submenu))
        }
        return items
    }

    private struct Values {
        var title = ""
        var isEnabled = true
        var isChecked = false
        var character: String?
        var glyph: Int?
        var modifiers: Int?
        var children: [AXUIElement] = []
    }

    private static let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute,
                                     kAXMenuItemCmdCharAttribute, kAXMenuItemCmdGlyphAttribute,
                                     kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute]

    /// One round trip for everything about an element. Attributes it doesn't have come back as
    /// error values, which the casts skip.
    private static func values(of element: AXUIElement) -> Values {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let list = raw as? [AnyObject], list.count == 7 else { return Values() }
        var values = Values()
        values.title = list[0] as? String ?? ""
        values.isEnabled = list[1] as? Bool ?? true
        values.isChecked = !(list[2] as? String ?? "").isEmpty
        values.character = list[3] as? String
        values.glyph = list[4] as? Int
        values.modifiers = list[5] as? Int
        values.children = children(list[6])
        return values
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw) == .success else { return [] }
        return children(raw)
    }

    private static func children(_ raw: AnyObject?) -> [AXUIElement] {
        guard let array = raw as? [AnyObject] else { return [] }
        return array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }
}
#endif

/// A menu item's key equivalent as the Mac shows it ("⌥⌘I", "⌃⇧F11"), from the
/// Accessibility attributes: a character or a glyph code, and modifier bits.
public enum MenuShortcutText {
    // kAXMenuItemModifier*: ⌘ is implied unless `noCommand` is set.
    static let shift = 1, option = 2, control = 4, noCommand = 8

    public static func text(character: String?, glyph: Int?, modifiers: Int?) -> String? {
        let key: String
        if let glyph, glyph != 0, let symbol = glyphs[glyph] {
            key = symbol
        } else if let character, !character.isEmpty {
            key = character == " " ? "Space" : character.uppercased()
        } else {
            return nil
        }
        let bits = modifiers ?? 0
        var text = ""
        if bits & control != 0 { text += "⌃" }
        if bits & option != 0 { text += "⌥" }
        if bits & shift != 0 { text += "⇧" }
        if bits & noCommand == 0 { text += "⌘" }
        return text + key
    }

    /// Carbon's `kMenu*Glyph` codes that menus use for keys without a character.
    static let glyphs: [Int: String] = {
        var table: [Int: String] = [
            0x02: "⇥", 0x03: "⇤", 0x04: "⌤", 0x09: "Space", 0x0A: "⌦", 0x0B: "↩", 0x0C: "↩", 0x0D: "↩",
            0x10: "⇣", 0x17: "⌫", 0x1B: "⎋", 0x1C: "⌧", 0x62: "⇞", 0x63: "⇪", 0x64: "←", 0x65: "→",
            0x66: "↖", 0x67: "?⃝", 0x68: "↑", 0x69: "↘", 0x6A: "↓", 0x6B: "⇟", 0x8C: "⏏",
        ]
        for n in 1...12 { table[0x6E + n] = "F\(n)" }
        for n in 13...15 { table[0x87 + n - 13] = "F\(n)" }
        return table
    }()
}
