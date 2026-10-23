import Foundation

/// Where the app keeps what it knows about your Macs (pairings, how to wake them, names): the
/// App Group container, so the Share extension can send to them too. Falls back to the app's
/// own folder when there's no group (tests, unsigned builds), moving an older copy across the
/// first time.
public enum SharedStorage {
    public static func url(_ name: String) -> URL {
        let legacy = URL.applicationSupportDirectory.appending(path: "PocketDesk/\(name)")
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShortcutLibrary.appGroup) else {
            return legacy
        }
        let shared = group.appending(path: "Macs/\(name)")
        if !FileManager.default.fileExists(atPath: shared.path(percentEncoded: false)),
           FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)) {
            try? FileManager.default.createDirectory(at: shared.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: legacy, to: shared)
        }
        return shared
    }
}
