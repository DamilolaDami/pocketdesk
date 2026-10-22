#if os(macOS)
import AppKit
import PDProtocol

public enum MacActionError: Error, Equatable, CustomStringConvertible {
    case invalidURL(String)
    case appNotFound(String)
    case couldNotOpen(String)

    public var description: String {
        switch self {
        case .invalidURL(let url): "“\(url)” isn't a link the Mac can open."
        case .appNotFound(let name): "\(name) isn't installed on this Mac."
        case .couldNotOpen(let name): "The Mac couldn't open \(name)."
        }
    }
}

extension InputInjector {
    public func perform(_ action: MacAction) async throws {
        switch action {
        case .openURL(let string):
            // Local files are out of scope for shortcuts: they'd behave differently on every Mac.
            guard let url = URL(string: string), let scheme = url.scheme, scheme != "file" else {
                throw MacActionError.invalidURL(string)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                try await NSWorkspace.shared.open(url, configuration: configuration)
            } catch {
                throw MacActionError.couldNotOpen(url.host() ?? string)
            }

        case .openApp(let bundleID, let name):
            guard let appURL = Self.application(bundleID: bundleID, name: name) else {
                throw MacActionError.appNotFound(name)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            } catch {
                throw MacActionError.couldNotOpen(name)
            }

        case .keystroke(let code, let modifiers):
            inject(.key(code: code, isDown: true, modifiers: modifiers))
            inject(.key(code: code, isDown: false, modifiers: modifiers))

        case .media(let key):
            await Self.press(key)
        }
    }

    /// Media keys aren't key codes: the keyboard sends them as system-defined events
    /// (subtype 8, `NX_KEYTYPE_*` in the top half of `data1`), down then up.
    @MainActor
    static func press(_ key: MediaKey) {
        let type: Int = switch key {
        case .playPause: 16 // NX_KEYTYPE_PLAY
        case .next: 17 // NX_KEYTYPE_NEXT
        case .previous: 18 // NX_KEYTYPE_PREVIOUS
        case .volumeUp: 0 // NX_KEYTYPE_SOUND_UP
        case .volumeDown: 1 // NX_KEYTYPE_SOUND_DOWN
        case .mute: 7 // NX_KEYTYPE_MUTE
        }
        for state in [0xA, 0xB] { // key down, key up
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                           data1: (type << 16) | (state << 8), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// By bundle ID first, then by name in the usual app folders.
    static func application(bundleID: String?, name: String) -> URL? {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       URL.homeDirectory.appending(path: "Applications").path(percentEncoded: false)]
        return folders
            .map { URL(filePath: $0).appending(path: "\(name).app") }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }
}
#endif
