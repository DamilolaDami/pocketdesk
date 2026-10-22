import Darwin
import Foundation
import PDProtocol
import Testing
@testable import PDClientCore

@Suite struct WakeTests {
    private let mac = WakeInfo(interfaces: [.init(mac: "a4:83:e7:01:02:fe", ipv4: "127.0.0.1")])

    @Test func sendsTheMagicPacketToTheMacsLastAddress() throws {
        // Listen where the Mac would be, on a spare port instead of 9.
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        #expect(WakeSender.wake(mac, ports: [UInt16(bigEndian: address.sin_port)]) >= 1)
        var buffer = [UInt8](repeating: 0, count: 200)
        let received = recv(fd, &buffer, buffer.count, 0)
        #expect(Array(buffer.prefix(max(0, received))) == WakeOnLAN.magicPacket(for: "a4:83:e7:01:02:fe"))
    }

    @Test func perMacValuesPersistAndForget() throws {
        let host = UUID(), other = UUID()
        var book = PerMac<WakeInfo>()
        book[host] = mac
        #expect(book[host] == mac && book[other] == nil && book[nil] == nil)

        let url = URL.temporaryDirectory.appending(path: "pocketdesk-\(UUID())/wake.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try book.save(to: url)
        #expect(try PerMac<WakeInfo>.load(from: url) == book)
        book[host] = nil
        #expect(book[host] == nil)
    }

    @Test func attemptsEndWhenTheMacAppearsOrTimesOut() {
        let soon = UUID(), never = UUID()
        let start = ContinuousClock.now
        var attempts = WakeAttempts()
        attempts.start(soon, at: start)
        attempts.start(never, at: start)
        #expect(attempts.woke([soon, UUID()]) == [soon])
        #expect(attempts.waking == [never])
        #expect(attempts.expire(at: start + .seconds(10)).isEmpty)
        #expect(attempts.expire(at: start + WakeAttempts.timeout) == [never])
        #expect(attempts.waking.isEmpty)
    }
}
