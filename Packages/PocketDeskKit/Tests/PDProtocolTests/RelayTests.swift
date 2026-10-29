import Foundation
import Testing

@testable import PDProtocol

struct RelayTests {
    @Test func hostedDefaultPreservesCustomConfiguration() throws {
        let name = "relay-default-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(RelayServer.savedAddress(in: defaults) == RelayServer.defaultAddress)
        defaults.set("  ", forKey: RelayServer.addressKey)
        #expect(RelayServer.savedAddress(in: defaults) == RelayServer.defaultAddress)
        defaults.set("custom.example:5443", forKey: RelayServer.addressKey)
        #expect(RelayServer.savedAddress(in: defaults) == "custom.example:5443")
        #expect(!defaults.bool(forKey: RelayServer.enabledKey))
    }

    @Test func sharedRustFixturesRoundTripAndFrame() throws {
        let url = try #require(
            Bundle.module.url(forResource: "relay-messages", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let messages = try JSONDecoder().decode([RelayMessage].self, from: data)
        let values = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(messages.count == 16)
        for (message, value) in zip(messages, values) {
            let framed = try message.framed()
            let length = framed.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            #expect(length == framed.count - 4)
            let encoded = try JSONSerialization.jsonObject(with: Data(framed.dropFirst(4))) as? NSDictionary
            #expect(encoded == value as NSDictionary)
        }
    }
    @Test func packetReassemblyRejectsMalformedAndExpiredFragments() throws {
        let payload = Data(repeating: 42, count: 1500)
        let id = UUID()
        let fragments = RelayPacket.fragments(session: id, payload: payload)
        #expect(fragments.count == 3)
        #expect(fragments.allSatisfy { $0.count <= 34 + 752 })
        var assembler = RelayPacketAssembler()
        let now = ContinuousClock.now
        #expect(assembler.receive(fragments[1], now: now) == nil)
        let assembled = assembler.receive(fragments[0], now: now)
        let packet = try #require(assembled)
        #expect(packet.session == id)
        #expect(packet.payload == payload)
        // The trailing parity piece doesn't start another packet.
        #expect(assembler.receive(fragments[2], now: now) == nil)
        #expect(assembler.receive(Data(repeating: 0, count: 1600)) == nil)
        let late = RelayPacket.fragments(session: id, payload: payload)
        #expect(assembler.receive(late[0], now: now) == nil)
        #expect(assembler.receive(late[1], now: now + .seconds(2)) == nil)
        #expect(RelayPacket.fragments(session: id, payload: Data(repeating: 0, count: 1501)).isEmpty)
        #expect(RelayPacket.fragments(session: id, payload: Data(repeating: 0, count: 1000)).count == 1)
    }
    /// The relay's leg to a phone loses a few percent of pieces: any two of a packet's three
    /// pieces must rebuild it, whichever is lost, at odd and even lengths.
    @Test(arguments: [1001, 1200, 1351, 1500])
    func packetReassemblySurvivesALostPiece(length: Int) {
        let id = UUID()
        let payload = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let pieces = RelayPacket.fragments(session: id, payload: payload)
        for lost in 0..<3 {
            var assembler = RelayPacketAssembler()
            let kept = pieces.indices.filter { $0 != lost }.map { pieces[$0] }
            #expect(assembler.receive(kept[1]) == nil)
            #expect(assembler.receive(kept[0])?.payload == payload)
        }
    }
    @Test func packetReassemblyRejectsInconsistentPieces() {
        let id = UUID()
        let packet = UUID()
        let pieces = RelayPacket.fragments(session: id, payload: Data(repeating: 5, count: 1200), packet: packet)
        var parity = pieces[2]
        parity[34] = 0x02  // claims 512 + the low byte: too short to need splitting
        var assembler = RelayPacketAssembler()
        #expect(assembler.receive(pieces[0]) == nil)
        #expect(assembler.receive(parity) == nil)
        let other = RelayPacket.fragments(session: id, payload: Data(repeating: 5, count: 1400))
        var mismatched = other[1]
        mismatched.replaceSubrange(16..<32, with: RelayPacket.uuidBytes(packet))
        var fresh = RelayPacketAssembler()
        #expect(fresh.receive(pieces[0]) == nil)
        #expect(fresh.receive(mismatched) == nil)
    }
    @Test func packetReassemblySurvivesReordering() throws {
        let id = UUID()
        let a = RelayPacket.fragments(session: id, payload: Data(repeating: 1, count: 1200))
        let b = RelayPacket.fragments(session: id, payload: Data(repeating: 2, count: 1200))
        var assembler = RelayPacketAssembler()
        #expect(assembler.receive(a[0]) == nil)
        #expect(assembler.receive(b[0]) == nil)
        #expect(assembler.receive(a[1])?.payload == Data(repeating: 1, count: 1200))
        #expect(assembler.receive(b[1])?.payload == Data(repeating: 2, count: 1200))
    }
    @Test func packetReassemblyStaysBounded() {
        let id = UUID()
        let packets = (0...RelayPacketAssembler.maximumPending).map { _ in
            RelayPacket.fragments(session: id, payload: Data(repeating: 7, count: 1200))
        }
        var assembler = RelayPacketAssembler()
        let start = ContinuousClock.now
        for (offset, pieces) in packets.enumerated() {
            #expect(assembler.receive(pieces[0], now: start + .milliseconds(offset)) == nil)
        }
        // One too many: the oldest gave way, the newest is still held.
        #expect(assembler.receive(packets[0][1], now: start + .milliseconds(100)) == nil)
        #expect(assembler.receive(packets.last![1], now: start + .milliseconds(100)) != nil)
        assembler.remove(id)
        #expect(assembler.receive(packets[1][1], now: start + .milliseconds(100)) == nil)
    }
    @Test func addressValidation() {
        #expect(RelayServer(address: "relay.example.com") == RelayServer(host: "relay.example.com", port: 4433))
        #expect(RelayServer(address: "[::1]:4444") == RelayServer(host: "::1", port: 4444))
        for value in [
            "", "https://relay.example.com", "relay.example.com/path", "user@relay.example.com", "relay.example.com:0",
            "relay.example.com:65536",
        ] {
            #expect(RelayServer(address: value) == nil)
        }
    }
}
