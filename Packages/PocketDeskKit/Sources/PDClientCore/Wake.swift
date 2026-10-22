import Darwin
import Foundation
import PDProtocol

/// Sends Wake-on-LAN magic packets for a sleeping Mac.
///
/// iOS only lets an app *broadcast* with Apple's multicast networking entitlement (granted on
/// request). Without it the broadcasts fail and only the direct packet to the Mac's last
/// address goes out, which reaches a Mac on Ethernet more reliably than one asleep on Wi-Fi.
public enum WakeSender {
    /// Each interface's packet, to its subnet broadcast, the all-hosts broadcast and its last
    /// address. Returns how many datagrams were sent.
    @discardableResult
    public static func wake(_ info: WakeInfo, ports: [UInt16] = WakeOnLAN.ports) -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var sent = 0
        for interface in info.interfaces {
            guard let packet = WakeOnLAN.magicPacket(for: interface.mac) else { continue }
            let targets = [interface.broadcast, "255.255.255.255", interface.ipv4].compactMap { $0 }
            for target in Set(targets) {
                for port in ports where send(packet, to: target, port: port, on: fd) { sent += 1 }
            }
        }
        return sent
    }

    private static func send(_ packet: [UInt8], to host: String, port: UInt16, on fd: Int32) -> Bool {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return false }
        let result = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return result == packet.count
    }
}

/// Something remembered about each paired Mac (how to wake it, what kind it is), by host ID.
/// Persisted by `SessionController`.
struct PerMac<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    private var values: [String: Value] = [:]

    subscript(host: UUID?) -> Value? {
        get { host.flatMap { values[$0.uuidString] } }
        set { if let host { values[host.uuidString] = newValue } }
    }

    static func load(from url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Macs being woken: each connects as soon as it shows up, or gives up at its deadline.
/// Pure; `SessionController` feeds it the clock and discovery.
struct WakeAttempts: Sendable, Equatable {
    static let timeout: Duration = .seconds(40)
    private var deadlines: [UUID: ContinuousClock.Instant] = [:]

    var waking: Set<UUID> { Set(deadlines.keys) }

    mutating func start(_ host: UUID, at now: ContinuousClock.Instant) {
        deadlines[host] = now + Self.timeout
    }

    /// The ones that are online now: no longer waking.
    mutating func woke(_ online: Set<UUID>) -> [UUID] {
        let woke = deadlines.keys.filter(online.contains)
        for host in woke { deadlines[host] = nil }
        return woke
    }

    /// The ones past their deadline: they didn't wake.
    mutating func expire(at now: ContinuousClock.Instant) -> [UUID] {
        let expired = deadlines.filter { $0.value <= now }.map(\.key)
        for host in expired { deadlines[host] = nil }
        return expired
    }

    mutating func cancel(_ host: UUID) { deadlines[host] = nil }
}
