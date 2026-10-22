#if os(macOS)
import AppKit
import PDProtocol

public indirect enum MacActionError: Error, Equatable, CustomStringConvertible {
    case invalidURL(String)
    case appNotFound(String)
    case couldNotOpen(String)
    case shortcutFailed(String, reason: String)
    case playerNotOpen(String)
    case notAllowedToControl(String)
    case step(Int, MacActionError)

    public var description: String {
        switch self {
        case .invalidURL(let url): "“\(url)” isn't a link the Mac can open."
        case .appNotFound(let name): "\(name) isn't installed on this Mac."
        case .couldNotOpen(let name): "The Mac couldn't open \(name)."
        case .shortcutFailed(let name, let reason): "“\(name)” didn't run on the Mac: \(reason)"
        case .playerNotOpen(let name): "\(name) isn't open on the Mac."
        case .notAllowedToControl(let name):
            "The Mac didn't let PocketDesk control \(name). Allow it in System Settings › Privacy & Security › Automation."
        case .step(let number, let error): "Step \(number): \(error)"
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

        case .mediaIn(let key, let player):
            try await Self.tell(player, key)

        case .runShortcut(let id, let name):
            // A shortcut can take a while (or ask a question on the Mac): once it's been
            // running a few seconds, call it started rather than keep the phone waiting.
            let result: Subprocess.Result?
            do {
                result = try await MacShortcuts.run(["run", id ?? name], keepOutput: false, timeout: .seconds(4))
            } catch {
                throw MacActionError.couldNotOpen("Shortcuts")
            }
            guard let result else { return }
            guard result.status == 0 else {
                // "Error: The operation couldn’t be completed. Couldn’t find shortcut" → the last part.
                let reason = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacing(#/^Error: /#, with: "")
                    .replacing(#/^The operation couldn[’']t be completed\. ?/#, with: "")
                throw MacActionError.shortcutFailed(name, reason: reason.isEmpty ? "it stopped with an error." : reason)
            }

        case .setVolume(let level):
            guard SystemVolume.set(level) else { throw MacActionError.couldNotOpen("the sound settings") }

        case .wait(let milliseconds):
            try? await Task.sleep(for: .milliseconds(milliseconds))

        case .steps(let steps):
            for (index, step) in steps.enumerated() {
                do {
                    try await perform(step)
                } catch let error as MacActionError {
                    throw MacActionError.step(index + 1, error)
                }
            }
        }
    }

    /// Tells one player directly, so it's that app whatever else is playing. Never launches
    /// it: pausing an app that isn't open shouldn't open it. macOS asks the person at the Mac
    /// once per player before the first command goes through.
    static func tell(_ player: MediaPlayer, _ key: MediaKey) async throws {
        guard let command = player.command(for: key) else { return }
        let running = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty
        }
        guard running else { throw MacActionError.playerNotOpen(player.name) }
        // `osascript` rather than NSAppleScript: the first-time permission prompt can wait for
        // an answer, and that mustn't block this app. A slow answer counts as sent.
        let script = "tell application id \"\(player.bundleID)\" to \(command)"
        guard let result = try? await Subprocess.run("/usr/bin/osascript", ["-e", script], timeout: .seconds(30)) else { return }
        if result.error.contains("-1743") { throw MacActionError.notAllowedToControl(player.name) }
        guard result.status == 0 else { throw MacActionError.couldNotOpen(player.name) }
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
extension MediaPlayer {
    /// The AppleScript verb each player understands (Music, Spotify and TV share them).
    func command(for key: MediaKey) -> String? {
        switch key {
        case .playPause: "playpause"
        case .next: "next track"
        case .previous: "previous track"
        case .volumeUp, .volumeDown, .mute: nil
        }
    }
}
#endif
