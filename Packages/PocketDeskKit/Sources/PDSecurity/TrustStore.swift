import Foundation

/// A peer this device has paired with. The host keeps one per phone; the phone keeps one
/// per Mac (keyed by fingerprint, with the host ID for matching Bonjour results).
public struct PairedPeer: Codable, Sendable, Hashable, Identifiable {
    public var id: Fingerprint { fingerprint }
    public var fingerprint: Fingerprint
    public var name: String
    /// Host's stable ID (from the invite). `nil` for phones on the host side.
    public var hostID: UUID?
    public var pairedAt: Date

    public init(fingerprint: Fingerprint, name: String, hostID: UUID? = nil, pairedAt: Date = .now) {
        self.fingerprint = fingerprint
        self.name = name
        self.hostID = hostID
        self.pairedAt = pairedAt
    }
}

/// The set of pinned peers. A plain value; persistence is the owner's job (`save(to:)`).
public struct TrustStore: Codable, Sendable, Equatable {
    public private(set) var peers: [Fingerprint: PairedPeer] = [:]

    public init(peers: [PairedPeer] = []) {
        for peer in peers { self.peers[peer.fingerprint] = peer }
    }

    public func trusts(_ fingerprint: Fingerprint) -> Bool { peers[fingerprint] != nil }

    public func peer(hostID: UUID) -> PairedPeer? { peers.values.first { $0.hostID == hostID } }

    public mutating func pin(_ peer: PairedPeer) { peers[peer.fingerprint] = peer }

    public mutating func revoke(_ fingerprint: Fingerprint) { peers[fingerprint] = nil }

    public static func load(from url: URL) throws -> TrustStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return TrustStore() }
        let store = try JSONDecoder().decode(TrustStore.self, from: Data(contentsOf: url))
        #if os(iOS)
        // Migrate existing pairings while unlocked. Lock Screen intents need the pins just
        // like DeviceIdentity needs its AfterFirstUnlock key; no private keys live here.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        #endif
        return store
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        #endif
    }
}
