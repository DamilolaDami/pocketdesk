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
        #expect(messages.count == 12)
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
        var assembler = RelayPacketAssembler()
        let now = ContinuousClock.now
        #expect(assembler.receive(fragments[1], now: now) == nil)
        let assembled = assembler.receive(fragments[0], now: now)
        let packet = try #require(assembled)
        #expect(packet.session == id)
        #expect(packet.payload == payload)
        #expect(assembler.receive(Data(repeating: 0, count: 1600)) == nil)
        #expect(assembler.receive(fragments[0], now: now) == nil)
        #expect(assembler.receive(fragments[1], now: now + .seconds(2)) == nil)
        #expect(RelayPacket.fragments(session: id, payload: Data(repeating: 0, count: 1501)).isEmpty)
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
