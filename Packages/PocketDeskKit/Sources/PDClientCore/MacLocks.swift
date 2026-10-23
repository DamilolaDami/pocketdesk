import Foundation

/// Macs locked behind Face ID (or the iPhone's passcode). Using a locked Mac (opening it,
/// running its shortcuts, files, the clipboard) asks first; once unlocked it stays so until
/// PocketDesk leaves the screen. Pure; `SessionController` does the asking and the saving.
struct MacLocks: Codable, Sendable, Equatable {
    private(set) var locked: Set<UUID> = []
    /// Unlocked since the app came to the front; never saved.
    private var unlocked: Set<UUID> = []

    private enum CodingKeys: String, CodingKey { case locked }

    func isLocked(_ host: UUID?) -> Bool { host.map(locked.contains) ?? false }

    func needsUnlock(_ host: UUID?) -> Bool {
        guard let host else { return false }
        return locked.contains(host) && !unlocked.contains(host)
    }

    /// Locking happens right after the person proved who they are, so the Mac stays usable
    /// until the app goes away.
    mutating func set(_ host: UUID, locked isLocked: Bool) {
        if isLocked {
            locked.insert(host)
            unlocked.insert(host)
        } else {
            locked.remove(host)
            unlocked.remove(host)
        }
    }

    mutating func unlock(_ host: UUID) {
        if locked.contains(host) { unlocked.insert(host) }
    }

    mutating func relockAll() {
        unlocked = []
    }

    mutating func forget(_ host: UUID) {
        locked.remove(host)
        unlocked.remove(host)
    }

    static func load(from url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
