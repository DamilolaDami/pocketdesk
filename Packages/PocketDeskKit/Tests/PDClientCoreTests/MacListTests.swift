import Foundation
import Testing
@testable import PDClientCore
import PDProtocol

struct MacListTests {
    @Test func versionsThatDifferNeedAnUpdate() {
        #expect(DiscoveredHost.Side(macVersion: 13, phoneVersion: 14) == .mac)
        #expect(DiscoveredHost.Side(macVersion: 15, phoneVersion: 14) == .phone)
        #expect(DiscoveredHost.Side(macVersion: 14, phoneVersion: 14) == nil)
        // An older Mac that doesn't say: try, and let the handshake tell.
        #expect(DiscoveredHost.Side(macVersion: nil, phoneVersion: 14) == nil)
    }

    @Test func pairedOnlineAndRecentFirst() {
        let now = Date.now
        let hosts = [
            DiscoveredHost(id: "1", name: "Nearby Mac", isPaired: false),
            DiscoveredHost(id: "2", name: "Asleep", isPaired: true, isOnline: false, lastUsed: now),
            DiscoveredHost(id: "3", name: "Studio", isPaired: true, lastUsed: now.addingTimeInterval(-3600)),
            DiscoveredHost(id: "4", name: "Laptop", isPaired: true, lastUsed: now),
            DiscoveredHost(id: "5", name: "Mini", isPaired: true),
            DiscoveredHost(id: "6", name: "Air", isPaired: true),
        ]
        #expect(DiscoveredHost.ordered(hosts).map(\.name) == ["Laptop", "Studio", "Air", "Mini", "Asleep", "Nearby Mac"])
    }
}

struct QualityTests {
    @Test func lowPowerModeMeansBatterySaver() {
        #expect(StreamQuality.effective(preferred: .best, lowPowerMode: false) == .best)
        #expect(StreamQuality.effective(preferred: .balanced, lowPowerMode: true) == .batterySaver)
        #expect(StreamQuality.effective(preferred: .batterySaver, lowPowerMode: false) == .batterySaver)
    }
}
