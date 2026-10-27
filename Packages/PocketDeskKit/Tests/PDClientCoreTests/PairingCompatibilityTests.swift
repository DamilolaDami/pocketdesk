import PDClientCore
import Testing

struct PairingCompatibilityTests {
    @Test func QRPairingExplainsWhichSideNeedsUpdating() {
        #expect(PairingCompatibility.failure(macVersion: 25, phoneVersion: 21, macName: "Studio") ==
            "Update PocketDesk on this iPhone before pairing with Studio. The Mac and iPhone apps must use matching versions.")
        #expect(PairingCompatibility.failure(macVersion: 21, phoneVersion: 25, macName: "Studio") ==
            "Update PocketDesk on Studio before pairing. The Mac and iPhone apps must use matching versions.")
        #expect(PairingCompatibility.failure(macVersion: 25, phoneVersion: 25, macName: "Studio") == nil)
        #expect(PairingCompatibility.failure(macVersion: nil, phoneVersion: 25, macName: "Studio") == nil)
    }
}
