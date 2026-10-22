import CryptoKit
import Foundation

/// What the host shows as a QR code (`pocketdesk://pair?i=…`). Scanning it is the pairing
/// trust root: the phone learns the host's certificate fingerprint out of band, so nobody on
/// the network can impersonate the host.
public struct PairingInvite: Codable, Sendable, Equatable {
    public static let scheme = "pocketdesk"

    public var hostID: UUID
    public var hostName: String
    public var hostFingerprint: Fingerprint
    /// One-time secret. The phone presents it in `pairRequest`; the host rejects any other.
    public var token: Data

    public init(hostID: UUID, hostName: String, hostFingerprint: Fingerprint, token: Data) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostFingerprint = hostFingerprint
        self.token = token
    }

    public static func make(hostID: UUID, hostName: String, hostFingerprint: Fingerprint) -> PairingInvite {
        let token = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        return PairingInvite(hostID: hostID, hostName: hostName, hostFingerprint: hostFingerprint, token: token)
    }

    public var url: URL {
        let payload = try! JSONEncoder().encode(self)
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [URLQueryItem(name: "i", value: payload.base64URLEncoded())]
        return components.url!
    }

    public init(url: URL) throws(PairingError) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == Self.scheme, components.host == "pair",
              let value = components.queryItems?.first(where: { $0.name == "i" })?.value,
              let payload = Data(base64URLEncoded: value),
              let invite = try? JSONDecoder().decode(PairingInvite.self, from: payload)
        else { throw .malformedInvite }
        self = invite
    }

    /// Constant-time comparison, so response timing doesn't leak how much of a guess was right.
    public func matches(token candidate: Data) -> Bool {
        guard candidate.count == token.count else { return false }
        return zip(candidate, token).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public enum PairingError: Error, Sendable, Equatable {
    case malformedInvite
}

public enum Pairing {
    /// Six-digit code both screens display before the host pins the phone. Bound to both
    /// certificates and the token, so a man in the middle would produce different codes.
    public static func verificationCode(host: Fingerprint, client: Fingerprint, token: Data) -> String {
        var message = Data("pocketdesk-sas-v1".utf8)
        message.append(host.bytes)
        message.append(client.bytes)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: token))
        let value = mac.withUnsafeBytes { raw in
            raw.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        return String(format: "%06u", value % 1_000_000)
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }
}
