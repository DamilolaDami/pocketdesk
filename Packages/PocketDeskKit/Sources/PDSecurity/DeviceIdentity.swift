import Foundation
import Security
import SwiftASN1
import Synchronization
import X509

/// A device's long-term TLS identity: a P-256 key generated inside the Keychain (it never
/// leaves it) and a self-signed certificate over it. Trust comes from pinning the
/// certificate's `Fingerprint` during pairing, not from a CA.
public struct DeviceIdentity: Sendable {
    /// Where the key and certificate live.
    public enum Storage: Sendable {
        /// The modern Keychain. Always used on iOS; on macOS it needs a signed app with a
        /// keychain access group.
        case dataProtection
        /// The macOS file-based login keychain. Works for unsigned builds and `swift test`.
        case legacyFile

        public static var platformDefault: Storage {
            #if os(macOS)
            .legacyFile
            #else
            .dataProtection
            #endif
        }

        fileprivate var usesDataProtection: Bool { self == .dataProtection }
    }

    public let label: String
    public let certificateDER: Data
    public let fingerprint: Fingerprint
    private let identity: SendableIdentity

    /// For `QUIC().tls.localIdentity(_:)`.
    public var secIdentity: sec_identity_t { sec_identity_create(identity.ref)! }

    /// Serializes Keychain writes. The macOS file keychain intermittently fails key
    /// generation ("failed to generate CDSA key") when two threads create keys at once.
    private static let keychainLock = Mutex(())

    /// Loads the identity stored under `label`, creating it on first use.
    public static func loadOrCreate(label: String, storage: Storage = .platformDefault) throws -> DeviceIdentity {
        try keychainLock.withLock { _ in
            if let existing = try load(label: label, storage: storage) { return existing }
            return try create(label: label, storage: storage)
        }
    }

    public static func load(label: String, storage: Storage = .platformDefault) throws -> DeviceIdentity? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecUseDataProtectionKeychain: storage.usesDataProtection,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, "find certificate")
        let certificate = result as! SecCertificate
        return try DeviceIdentity(label: label, certificate: certificate, identity: identity(for: certificate, label: label, storage: storage))
    }

    /// Removes the key and certificate. Peers that pinned this identity must pair again.
    public static func delete(label: String, storage: Storage = .platformDefault) {
        keychainLock.withLock { _ in deleteUnlocked(label: label, storage: storage) }
    }

    private static func deleteUnlocked(label: String, storage: Storage) {
        for itemClass in [kSecClassCertificate, kSecClassKey] {
            // The file keychain deletes one match per call.
            while SecItemDelete([
                kSecClass: itemClass,
                kSecAttrLabel: label,
                kSecUseDataProtectionKeychain: storage.usesDataProtection,
            ] as CFDictionary) == errSecSuccess {}
        }
    }

    private static func create(label: String, storage: Storage) throws -> DeviceIdentity {
        var privateKeyAttributes: [CFString: Any] = [kSecAttrIsPermanent: true, kSecAttrLabel: label]
        if storage.usesDataProtection {
            privateKeyAttributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseDataProtectionKeychain: storage.usesDataProtection,
            kSecPrivateKeyAttrs: privateKeyAttributes,
        ] as CFDictionary, &error) else {
            throw error!.takeRetainedValue()
        }

        let signingKey = try Certificate.PrivateKey(key)
        // The common name is the storage label: the file keychain ignores `kSecAttrLabel` on
        // certificates and labels them by common name instead. Peers never display it.
        let name = try DistinguishedName { CommonName(label) }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: signingKey.publicKey,
            notValidBefore: now.addingTimeInterval(-86_400),
            notValidAfter: now.addingTimeInterval(86_400 * 365 * 30),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: signingKey)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)

        let secCertificate = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData)!
        var attributes: [CFString: Any] = [
            kSecValueRef: secCertificate,
            kSecAttrLabel: label,
            kSecUseDataProtectionKeychain: storage.usesDataProtection,
        ]
        if storage.usesDataProtection {
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        try check(SecItemAdd(attributes as CFDictionary, nil), "store certificate")
        return try DeviceIdentity(label: label, certificate: secCertificate,
                                  identity: identity(for: secCertificate, label: label, storage: storage))
    }

    private static func identity(for certificate: SecCertificate, label: String, storage: Storage) throws -> SecIdentity {
        #if os(macOS)
        if !storage.usesDataProtection {
            var identity: SecIdentity?
            try check(SecIdentityCreateWithCertificate(nil, certificate, &identity), "pair certificate with key")
            return identity!
        }
        #endif
        var result: CFTypeRef?
        try check(SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: label,
            kSecReturnRef: true,
            kSecUseDataProtectionKeychain: true,
        ] as CFDictionary, &result), "find identity")
        return result as! SecIdentity
    }

    private init(label: String, certificate: SecCertificate, identity: SecIdentity) {
        self.label = label
        self.certificateDER = SecCertificateCopyData(certificate) as Data
        self.fingerprint = Fingerprint(certificateDER: certificateDER)
        self.identity = SendableIdentity(ref: identity)
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == errSecSuccess else { throw IdentityError(action: action, status: status) }
    }
}

public struct IdentityError: Error, Sendable, CustomStringConvertible {
    public let action: String
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Couldn't \(action): \(message)"
    }
}

/// `@unchecked Sendable`: `SecIdentity` is an immutable CF handle that's safe to share
/// across threads; it just isn't annotated.
private struct SendableIdentity: @unchecked Sendable {
    let ref: SecIdentity
}
