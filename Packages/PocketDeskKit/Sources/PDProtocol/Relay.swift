import Foundation

/// Versioned independently from the end-to-end PocketDesk session. Flat JSON matches Quinn.
public enum RelayMessage: Sendable, Equatable, Codable {
    /// Version 2: the phone's traffic travels as QUIC datagrams, like the Mac's.
    public static let alpn = "pocketdesk-relay/2"
    public static let maximumSize = 16_384
    case register(hostID: UUID)
    case allow(fingerprints: [String])
    case connect(host: String)
    case incoming(phone: String, session: UUID)
    case ready(session: UUID)
    case allocate(session: UUID)
    /// Forwarding is on: both devices now send this session's pieces as datagrams.
    case forward(session: UUID)
    case close(session: UUID)
    case notFound
    case error(reason: String)
    /// Mac → relay: send a Live Activity push to Apple for a phone the Mac allows. `payload`
    /// is the `aps` JSON as text, `token` the phone's device token in hex.
    case push(id: UUID, phone: String, token: String, environment: String, topic: String, payload: String, priority: Int = 10)
    /// Relay → Mac: Apple's HTTP status (200 is delivered), or why the relay didn't ask.
    case pushed(id: UUID, status: Int, reason: String?)
    case ping
    case pong
    private enum Keys: String, CodingKey {
        case type, hostID, fingerprints, host, phone, session, reason, id, token, environment, topic, payload, status, priority
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "register": self = .register(hostID: try c.decode(UUID.self, forKey: .hostID))
        case "allow": self = .allow(fingerprints: try c.decode([String].self, forKey: .fingerprints))
        case "connect": self = .connect(host: try c.decode(String.self, forKey: .host))
        case "incoming":
            self = .incoming(
                phone: try c.decode(String.self, forKey: .phone), session: try c.decode(UUID.self, forKey: .session))
        case "ready": self = .ready(session: try c.decode(UUID.self, forKey: .session))
        case "allocate": self = .allocate(session: try c.decode(UUID.self, forKey: .session))
        case "forward": self = .forward(session: try c.decode(UUID.self, forKey: .session))
        case "close": self = .close(session: try c.decode(UUID.self, forKey: .session))
        case "notFound": self = .notFound
        case "error": self = .error(reason: try c.decode(String.self, forKey: .reason))
        case "push":
            self = .push(id: try c.decode(UUID.self, forKey: .id), phone: try c.decode(String.self, forKey: .phone),
                         token: try c.decode(String.self, forKey: .token),
                         environment: try c.decode(String.self, forKey: .environment),
                         topic: try c.decode(String.self, forKey: .topic), payload: try c.decode(String.self, forKey: .payload),
                         priority: try c.decodeIfPresent(Int.self, forKey: .priority) ?? 10)
        case "pushed":
            self = .pushed(id: try c.decode(UUID.self, forKey: .id), status: try c.decode(Int.self, forKey: .status),
                           reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "ping": self = .ping
        case "pong": self = .pong
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown relay message")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .register(let hostID):
            try c.encode("register", forKey: .type)
            try c.encode(hostID, forKey: .hostID)
        case .allow(let fingerprints):
            try c.encode("allow", forKey: .type)
            try c.encode(fingerprints, forKey: .fingerprints)
        case .connect(let host):
            try c.encode("connect", forKey: .type)
            try c.encode(host, forKey: .host)
        case .incoming(let phone, let session):
            try c.encode("incoming", forKey: .type)
            try c.encode(phone, forKey: .phone)
            try c.encode(session, forKey: .session)
        case .ready(let session):
            try c.encode("ready", forKey: .type)
            try c.encode(session, forKey: .session)
        case .allocate(let session):
            try c.encode("allocate", forKey: .type)
            try c.encode(session, forKey: .session)
        case .forward(let session):
            try c.encode("forward", forKey: .type)
            try c.encode(session, forKey: .session)
        case .close(let session):
            try c.encode("close", forKey: .type)
            try c.encode(session, forKey: .session)
        case .notFound:
            try c.encode("notFound", forKey: .type)
        case .error(let reason):
            try c.encode("error", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .push(let id, let phone, let token, let environment, let topic, let payload, let priority):
            try c.encode("push", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(phone, forKey: .phone)
            try c.encode(token, forKey: .token)
            try c.encode(environment, forKey: .environment)
            try c.encode(topic, forKey: .topic)
            try c.encode(payload, forKey: .payload)
            if priority != 10 { try c.encode(priority, forKey: .priority) }
        case .pushed(let id, let status, let reason):
            try c.encode("pushed", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .ping:
            try c.encode("ping", forKey: .type)
        case .pong:
            try c.encode("pong", forKey: .type)
        }
    }
    public func framed() throws -> Data {
        let body = try JSONEncoder().encode(self)
        guard body.count <= Self.maximumSize else { throw RelayWireError.invalidPacket }
        let n = UInt32(body.count)
        return Data([
            UInt8(n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8),
            UInt8(truncatingIfNeeded: n),
        ]) + body
    }
}

public enum RelayWireError: Error, Sendable { case invalidPacket }

/// Validated relay endpoint. Remote access is enabled separately from the saved address.
public struct RelayServer: Sendable, Equatable, Codable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    public init?(address: String) {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URLComponents(string: "relay://" + text),
            let host = url.host, !host.isEmpty, !host.contains(where: { $0.isWhitespace }), !text.hasSuffix(":"),
            url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil, url.path.isEmpty,
            (1...65535).contains(url.port ?? 4433)
        else { return nil }
        self.host = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        self.port = UInt16(url.port ?? 4433)
    }
    public static let defaultAddress = "relay.pocketdesk.runmira.dev:4433"
    public static func savedAddress(in defaults: UserDefaults = .standard) -> String {
        let value = defaults.string(forKey: addressKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? defaultAddress : value
    }
    public static let addressKey = "PocketDesk.relayAddress"
    public static let enabledKey = "PocketDesk.relayEnabled"
}

/// Opaque nested UDP packets, fragmented to fit the outer QUIC minimum MTU.
///
/// A piece is a 16-byte session ID, 16-byte packet ID, index and count bytes, then its share
/// of the packet. Packets up to 1000 bytes travel whole. Larger ones travel as two halves and a
/// parity piece, any two of which rebuild the packet: the relay's leg to a phone loses a few
/// percent of pieces, and losing either half of a two-piece packet lost it, which held the
/// inner session well below what the path carries. The parity piece is the packet's length
/// (two bytes, big-endian), then the halves XORed together, the second padded with a zero.
public enum RelayPacket {
    public static let maximumPayload = 1500
    static let wholeLimit = 1000
    public static func uuidBytes(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }
    public static func uuid(_ bytes: Data) -> UUID? {
        guard bytes.count == 16 else { return nil }
        let b = Array(bytes)
        return UUID(
            uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        )
    }
    public static func fragments(session: UUID, payload: Data, packet: UUID = UUID()) -> [Data] {
        guard !payload.isEmpty, payload.count <= maximumPayload else { return [] }
        let header = uuidBytes(session) + uuidBytes(packet)
        guard payload.count > wholeLimit else { return [header + Data([0, 1]) + payload] }
        let bytes = Array(payload)
        let half = (bytes.count + 1) / 2
        let first = bytes[..<half], second = bytes[half...]
        var parity = [UInt8(bytes.count >> 8), UInt8(truncatingIfNeeded: bytes.count)] + first
        for (offset, byte) in second.enumerated() { parity[2 + offset] ^= byte }
        return [
            header + Data([0, 3]) + Data(first), header + Data([1, 3]) + Data(second), header + Data([2, 3]) + Data(parity),
        ]
    }
    /// The packet from any two of its three pieces, or nil if they don't fit together.
    static func rebuild(first: Data?, second: Data?, parity: Data?) -> Data? {
        if let first, let second {
            guard second.count == first.count || second.count == first.count - 1,
                first.count + second.count > wholeLimit
            else { return nil }
            return first + second
        }
        guard let parity, parity.count > 2 else { return nil }
        let p = Array(parity)
        let length = Int(p[0]) << 8 | Int(p[1])
        let half = (length + 1) / 2
        guard length > wholeLimit, length <= maximumPayload, p.count == 2 + half else { return nil }
        let known = Array(first ?? second ?? Data())
        guard known.count == (first == nil ? length - half : half) else { return nil }
        var missing = Array(p[2...])
        for (offset, byte) in known.enumerated() { missing[offset] ^= byte }
        return first == nil ? Data(missing) + Data(known) : Data(known) + Data(missing.prefix(length - half))
    }
}

/// Reassembles split packets; bounded and expiring, even under malformed traffic.
///
/// Networks reorder back-to-back packets (Fly's UDP path does it often), so a piece of the
/// next packet can arrive between the pieces of this one. Holding a single incomplete packet
/// per session threw this one away each time, which lost most full-size packets as soon as
/// there was any reordering. Several are held instead, the oldest giving way. Packets already
/// rebuilt are remembered for a while, so their leftover piece doesn't start another.
public struct RelayPacketAssembler: Sendable {
    /// Incomplete packets held at once, across sessions: well over a round of reordering.
    public static let maximumPending = 64
    /// Rebuilt packets remembered: the third piece trails the other two by a few packets.
    static let maximumDone = 256
    private struct Key: Hashable, Sendable {
        var session: UUID
        var packet: UUID
    }
    private struct Pending: Sendable {
        var pieces: [Data?] = [nil, nil, nil]
        var deadline: ContinuousClock.Instant
    }
    private var pending: [Key: Pending] = [:]
    private var done: Set<Key> = []
    private var doneOrder: [Key] = []
    public init() {}
    public mutating func remove(_ session: UUID) { pending = pending.filter { $0.key.session != session } }
    public mutating func receive(_ data: Data, now: ContinuousClock.Instant = .now) -> (session: UUID, payload: Data)? {
        guard data.count > 34, data.count <= 34 + RelayPacket.wholeLimit,
            let session = RelayPacket.uuid(Data(data.prefix(16))),
            let packet = RelayPacket.uuid(Data(data.dropFirst(16).prefix(16)))
        else { return nil }
        let bytes = Array(data.prefix(34))
        let index = Int(bytes[32])
        let count = bytes[33]
        let payload = Data(data.dropFirst(34))
        if count == 1, index == 0 { return (session, payload) }
        let half = (RelayPacket.maximumPayload + 1) / 2
        guard count == 3, index <= 2, payload.count <= (index == 2 ? 2 + half : half) else { return nil }
        let key = Key(session: session, packet: packet)
        guard !done.contains(key) else { return nil }
        if let held = pending[key], held.deadline <= now { pending[key] = nil }
        if pending[key] == nil {
            pending = pending.filter { $0.value.deadline > now }
            if pending.count >= Self.maximumPending,
                let oldest = pending.min(by: { $0.value.deadline < $1.value.deadline })?.key {
                pending[oldest] = nil
            }
            pending[key] = Pending(deadline: now + .seconds(1))
        }
        pending[key]?.pieces[index] = payload
        guard let pieces = pending[key]?.pieces, pieces.compactMap({ $0 }).count >= 2 else { return nil }
        pending[key] = nil
        remember(key)
        guard let rebuilt = RelayPacket.rebuild(first: pieces[0], second: pieces[1], parity: pieces[2]) else { return nil }
        return (session, rebuilt)
    }
    private mutating func remember(_ key: Key) {
        done.insert(key)
        doneOrder.append(key)
        if doneOrder.count > Self.maximumDone { done.remove(doneOrder.removeFirst()) }
    }
}
