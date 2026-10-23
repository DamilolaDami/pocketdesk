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

    @Test func relocksOnlyAfterTheDelay() {
        let mac = UUID()
        var locks = MacLocks()
        locks.set(mac, locked: true)
        let left = Date(timeIntervalSince1970: 1000)
        locks.left(at: left, delay: 60)
        #expect(!locks.needsUnlock(mac))
        locks.returned(at: left.addingTimeInterval(30), delay: 60)
        #expect(!locks.needsUnlock(mac))
        // Away again; the clock restarts.
        locks.left(at: left.addingTimeInterval(100), delay: 60)
        locks.returned(at: left.addingTimeInterval(170), delay: 60)
        #expect(locks.needsUnlock(mac))
    }

    @Test func noDelayRelocksAsItLeaves() {
        let mac = UUID()
        var locks = MacLocks()
        locks.set(mac, locked: true)
        locks.left(at: .now, delay: 0)
        #expect(locks.needsUnlock(mac))
    }
}
