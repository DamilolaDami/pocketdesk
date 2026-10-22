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
