import PDProtocol

/// QR pairing must enforce the same advertised-version gate as the Mac card.
/// Otherwise incompatible ALPNs fail before either device can show a verification code.
public enum PairingCompatibility {
    public static func failure(macVersion: UInt16?, phoneVersion: UInt16 = protocolVersion, macName: String) -> String? {
        guard let side = DiscoveredHost.Side(macVersion: macVersion, phoneVersion: phoneVersion) else { return nil }
        switch side {
        case .mac: return "Update PocketDesk on \(macName) before pairing. The Mac and iPhone apps must use matching versions."
        case .phone: return "Update PocketDesk on this iPhone before pairing with \(macName). The Mac and iPhone apps must use matching versions."
        }
    }
}
