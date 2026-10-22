#if os(macOS)
import Darwin
import Foundation
import PDProtocol

/// What a phone needs to wake this Mac: the hardware address of each network interface in use
/// (Wi-Fi, Ethernet), with its IPv4 and broadcast addresses, and whether macOS will wake for it.
public enum WakeAddresses {
    public static func current() -> WakeInfo {
        WakeInfo(interfaces: interfaces(), wakeForNetworkAccess: wakeForNetworkAccess())
    }

    /// `en*` interfaces that have both a MAC and an IPv4 address right now.
    static func interfaces() -> [WakeInfo.Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var macs: [String: String] = [:]
        var ipv4: [String: (address: String, broadcast: String)] = [:]
        var order: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), let address = entry.pointee.ifa_addr else { continue }
            if !order.contains(name) { order.append(name) }
            switch Int32(address.pointee.sa_family) {
            case AF_LINK:
                macs[name] = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> String? in
                    guard link.pointee.sdl_alen == 6 else { return nil }
                    // LLADDR(): the address follows the interface name in sdl_data.
                    let bytes = withUnsafeBytes(of: link.pointee.sdl_data) { data in
                        Array(data[Int(link.pointee.sdl_nlen)..<Int(link.pointee.sdl_nlen) + 6])
                    }
                    return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                }
            case AF_INET:
                guard let mask = entry.pointee.ifa_netmask else { continue }
                let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                ipv4[name] = (dotted(ip), dotted(ip | ~netmask))
            default:
                continue
            }
        }
        return order.compactMap { name in
            guard let mac = macs[name], let address = ipv4[name] else { return nil }
            return WakeInfo.Interface(mac: mac, ipv4: address.address, broadcast: address.broadcast)
        }
    }

    /// `pmset`'s `womp` ("wake on magic packet"): the "Wake for network access" setting.
    public static func wakeForNetworkAccess() -> Bool? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return parseWomp(output)
    }

    static func parseWomp(_ pmset: String) -> Bool? {
        for line in pmset.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[0] == "womp" { return fields[1] == "1" }
        }
        return nil
    }

    /// Network byte order `in_addr_t` → "192.168.1.20".
    private static func dotted(_ address: in_addr_t) -> String {
        withUnsafeBytes(of: address) { $0.map(String.init).joined(separator: ".") }
    }
}
#endif
