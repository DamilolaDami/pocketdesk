import Foundation
import PDProtocol
import Testing

@Suite struct WakeOnLANTests {
    @Test func magicPacketIsSyncThenSixteenCopies() throws {
        let packet = try #require(WakeOnLAN.magicPacket(for: "a4:83:e7:01:02:fe"))
        #expect(packet.count == 102)
        #expect(packet.prefix(6).allSatisfy { $0 == 0xFF })
        for copy in 0..<16 {
            #expect(Array(packet[6 + copy * 6 ..< 12 + copy * 6]) == [0xA4, 0x83, 0xE7, 0x01, 0x02, 0xFE])
        }
    }

    @Test func parsesColonsAndDashesRejectsJunk() {
        #expect(WakeOnLAN.parse("A4-83-E7-01-02-FE") == [0xA4, 0x83, 0xE7, 0x01, 0x02, 0xFE])
        #expect(WakeOnLAN.parse("a4:83:e7:01:02") == nil)
        #expect(WakeOnLAN.parse("a4:83:e7:01:02:zz") == nil)
        #expect(WakeOnLAN.parse("a4:83:e7:1:2:fe") == nil)
        #expect(WakeOnLAN.parse("00:00:00:00:00:00") == nil)
    }

    @Test func helloAckCarriesWakeInfo() throws {
        let wake = WakeInfo(interfaces: [.init(mac: "a4:83:e7:01:02:fe", ipv4: "192.168.1.20", broadcast: "192.168.1.255")],
                            wakeForNetworkAccess: true)
        for message in [ControlMessage.helloAck(HelloAck(hostName: "Mac", displays: [], wake: wake)),
                        .helloAck(HelloAck(hostName: "Mac", displays: []))] {
            #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }
}
