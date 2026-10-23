import Foundation
import Testing
@testable import PDClientCore

struct MacLocksTests {
    private let studio = UUID(), air = UUID()

    @Test func lockedMacsAskUntilUnlocked() {
        var locks = MacLocks()
        #expect(!locks.needsUnlock(studio))
        locks.set(studio, locked: true)
        // Locking just asked for Face ID: no second prompt right away.
        #expect(locks.isLocked(studio) && !locks.needsUnlock(studio))
        locks.relockAll()
        #expect(locks.needsUnlock(studio))
        #expect(!locks.needsUnlock(air))
        locks.unlock(studio)
        locks.unlock(air)
        #expect(!locks.needsUnlock(studio))
        #expect(!locks.isLocked(air))
        locks.set(studio, locked: false)
        locks.relockAll()
        #expect(!locks.needsUnlock(studio))
        #expect(!locks.needsUnlock(nil))
    }

    @Test func onlyTheLocksAreSaved() throws {
        var locks = MacLocks()
        locks.set(studio, locked: true)
        let url = URL.temporaryDirectory.appending(path: "locks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try locks.save(to: url)
        let loaded = try MacLocks.load(from: url)
        // A fresh launch starts locked.
        #expect(loaded.needsUnlock(studio))
        locks.forget(studio)
        #expect(!locks.isLocked(studio))
    }
}
