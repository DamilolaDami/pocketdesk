import CryptoKit
import Foundation
import Security

/// SHA-256 of a device's DER certificate. This is what peers pin: a session is only accepted
/// when the other side presents the exact certificate learned during pairing.
public struct Fingerprint: Hashable, Codable, Sendable, CustomStringConvertible {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public init(certificateDER: Data) {
        bytes = Data(SHA256.hash(data: certificateDER))
    }

    /// Fingerprint of the leaf certificate a TLS peer presented.
    public init?(trust: sec_trust_t) {
        let trust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        self.init(certificateDER: SecCertificateCopyData(leaf) as Data)
    }

    /// Fingerprint of the peer on an established TLS/QUIC connection.
    public init?(peerOf metadata: sec_protocol_metadata_t) {
        var leaf: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata) { certificate in
            if leaf == nil {
                let ref = sec_certificate_copy_ref(certificate).takeRetainedValue()
                leaf = SecCertificateCopyData(ref) as Data
            }
        }
        guard let leaf else { return nil }
        self.init(certificateDER: leaf)
    }

    /// Short form for UI and logs, e.g. `3F9A·C21B·77D0`.
    public var description: String {
        bytes.prefix(6).map { String(format: "%02X", $0) }
            .chunked(2).map { $0.joined() }.joined(separator: "·")
    }
}

extension Array {
    fileprivate func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
