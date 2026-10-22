import CryptoKit
import Foundation

/// Long-term device identity. The private key lives in the Keychain (Secure Enclave on device
/// where available); the public key is what the peer pins after pairing.
public struct DeviceIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
}

/// What the host shows as a QR code. Scanning it is the pairing trust root: the phone learns
/// the host's public key out of band, so no one on the network can impersonate the host.
public struct PairingInvite: Codable, Sendable, Equatable {
    public var hostID: UUID
    public var hostName: String
    public var hostPublicKey: Data
    /// One-time token; the host rejects pairing attempts that don't present it.
    public var token: Data

    public init(hostID: UUID, hostName: String, hostPublicKey: Data, token: Data) {
        self.hostID = hostID
        self.hostName = hostName
        self.hostPublicKey = hostPublicKey
        self.token = token
    }

    public static func make(hostID: UUID, hostName: String, identity: DeviceIdentity) -> PairingInvite {
        PairingInvite(hostID: hostID, hostName: hostName, hostPublicKey: identity.publicKey,
                      token: Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }))
    }
}

public enum PairingError: Error, Sendable {
    case invalidPublicKey
}

public enum Pairing {
    /// Derives the session secret both sides compute from their own private key and the
    /// peer's public key. Bound to the invite token so a replayed invite yields a different key.
    public static func sharedKey(identity: DeviceIdentity, peerPublicKey: Data, token: Data) throws -> SymmetricKey {
        let peer: Curve25519.KeyAgreement.PublicKey
        do { peer = try .init(rawRepresentation: peerPublicKey) } catch { throw PairingError.invalidPublicKey }
        let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: peer)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: token,
                                              sharedInfo: Data("pocketdesk-pairing-v1".utf8),
                                              outputByteCount: 32)
    }

    /// Six-digit code both screens display. The user confirms they match before the host
    /// trusts the phone (defends the rare case where the QR was photographed by someone else).
    public static func verificationCode(for key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("sas".utf8), using: key)
        let value = mac.withUnsafeBytes { raw in
            raw.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        return String(format: "%06u", value % 1_000_000)
    }
}
