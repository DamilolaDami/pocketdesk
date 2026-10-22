/// Wake-on-LAN "magic packet": six 0xFF bytes, then the target's MAC address 16 times.
/// The network card listens for it while the Mac sleeps.
public enum WakeOnLAN {
    /// The usual ports; cards match the payload, not the port.
    public static let ports: [UInt16] = [9, 7]

    public static func magicPacket(for mac: String) -> [UInt8]? {
        guard let address = parse(mac) else { return nil }
        return [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: address, count: 16).joined())
    }

    /// "aa:bb:cc:dd:ee:ff" (or with dashes) → 6 bytes.
    public static func parse(_ mac: String) -> [UInt8]? {
        let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard bytes.count == 6, bytes != [0, 0, 0, 0, 0, 0] else { return nil }
        return bytes
    }
}
