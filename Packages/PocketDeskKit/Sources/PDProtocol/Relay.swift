import Foundation

/// Versioned independently from the end-to-end PocketDesk session. Flat JSON matches Quinn.
public enum RelayMessage: Sendable, Equatable, Codable {
    public static let alpn = "pocketdesk-relay/1"
    public static let maximumSize = 16_384
    case register(hostID: UUID)
    case allow(fingerprints: [String])
    case connect(host: String)
    case incoming(phone: String, session: UUID)
    case ready(session: UUID)
    case allocate(session: UUID)
    case forward(session: UUID, port: UInt16, token: String)
    case close(session: UUID)
    case notFound
    case error(reason: String)
    case ping
    case pong
    private enum Keys: String, CodingKey { case type, hostID, fingerprints, host, phone, session, port, token, reason }
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
        case "forward":
            self = .forward(
                session: try c.decode(UUID.self, forKey: .session), port: try c.decode(UInt16.self, forKey: .port),
                token: try c.decode(String.self, forKey: .token))
        case "close": self = .close(session: try c.decode(UUID.self, forKey: .session))
        case "notFound": self = .notFound
        case "error": self = .error(reason: try c.decode(String.self, forKey: .reason))
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
        case .forward(let session, let port, let token):
            try c.encode("forward", forKey: .type)
            try c.encode(session, forKey: .session)
            try c.encode(port, forKey: .port)
            try c.encode(token, forKey: .token)
        case .close(let session):
            try c.encode("close", forKey: .type)
            try c.encode(session, forKey: .session)
        case .notFound:
            try c.encode("notFound", forKey: .type)
        case .error(let reason):
            try c.encode("error", forKey: .type)
            try c.encode(reason, forKey: .reason)
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

/// Explicit self-hosted endpoint. An empty address means relay access is disabled.
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
    public static let addressKey = "PocketDesk.relayAddress"
    public static let enabledKey = "PocketDesk.relayEnabled"
}

/// Opaque nested UDP packets, fragmented to fit the outer QUIC minimum MTU.
public enum RelayPacket {
    public static let maximumPayload = 1500
    public static func uuidBytes(_ value: UUID) -> Data { withUnsafeBytes(of: value.uuid) { Data($0) } }
    public static func uuid(_ bytes: Data) -> UUID? {
        guard bytes.count == 16 else { return nil }
        let b = Array(bytes)
        return UUID(
            uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        )
    }
    public static func token(_ text: String) -> Data? {
        guard text.count == 32, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let chars = Array(text)
        return Data(stride(from: 0, to: 32, by: 2).compactMap { UInt8(String(chars[$0...$0 + 1]), radix: 16) })
    }
    public static func fragments(session: UUID, payload: Data, packet: UUID = UUID()) -> [Data] {
        guard !payload.isEmpty, payload.count <= maximumPayload else { return [] }
        let count: UInt8 = payload.count > 1000 ? 2 : 1
        return stride(from: 0, to: payload.count, by: 1000).enumerated().map { index, offset in
            uuidBytes(session) + uuidBytes(packet) + Data([UInt8(index), count])
                + payload.subdata(in: offset..<min(offset + 1000, payload.count))
        }
    }
}

/// One incomplete packet per session; bounded and expiring, even under malformed traffic.
public struct RelayPacketAssembler: Sendable {
    private struct Pending: Sendable {
        var packet: UUID
        var first: Data?
        var second: Data?
        var deadline: ContinuousClock.Instant
    }
    private var pending: [UUID: Pending] = [:]
    public init() {}
    public mutating func remove(_ session: UUID) { pending[session] = nil }
    public mutating func receive(_ data: Data, now: ContinuousClock.Instant = .now) -> (session: UUID, payload: Data)? {
        guard data.count > 34, data.count <= 1034,
            let session = RelayPacket.uuid(Data(data.prefix(16))),
            let packet = RelayPacket.uuid(Data(data.dropFirst(16).prefix(16)))
        else { return nil }
        let bytes = Array(data.prefix(34))
        let index = bytes[32]
        let count = bytes[33]
        let payload = Data(data.dropFirst(34))
        if count == 1, index == 0 { return (session, payload) }
        guard count == 2, index <= 1, index != 0 || payload.count == 1000,
            index != 1 || payload.count <= 500
        else { return nil }
        pending = pending.filter { $0.value.deadline > now }
        guard pending[session] != nil || pending.count < 2 else { return nil }
        if pending[session]?.packet != packet {
            pending[session] = Pending(packet: packet, deadline: now + .seconds(1))
        }
        if index == 0 { pending[session]?.first = payload } else { pending[session]?.second = payload }
        guard let first = pending[session]?.first, let second = pending[session]?.second else { return nil }
        pending[session] = nil
        return (session, first + second)
    }
}
