import Foundation
import Testing
@testable import PDSecurity

@Suite struct PairingTests {
    let host = Fingerprint(certificateDER: Data("host-cert".utf8))
    let phone = Fingerprint(certificateDER: Data("phone-cert".utf8))

    @Test func inviteRoundTripsThroughURL() throws {
        let invite = PairingInvite.make(hostID: UUID(), hostName: "Studio Mac", hostFingerprint: host)
        #expect(invite.url.scheme == "pocketdesk")
        #expect(try PairingInvite(url: invite.url) == invite)
    }

    @Test func rejectsMalformedURL() {
        #expect(throws: PairingError.malformedInvite) {
            try PairingInvite(url: URL(string: "pocketdesk://pair?i=not-base64!")!)
        }
        #expect(throws: PairingError.malformedInvite) {
            try PairingInvite(url: URL(string: "https://example.com/pair")!)
        }
    }

    @Test func tokenMatching() {
        let invite = PairingInvite.make(hostID: UUID(), hostName: "Mac", hostFingerprint: host)
        #expect(invite.matches(token: invite.token))
        #expect(!invite.matches(token: Data(repeating: 0, count: invite.token.count)))
        #expect(!invite.matches(token: invite.token.prefix(4)))
    }

    @Test func verificationCodeIsStableAndBoundToBothPeers() {
        let token = Data(repeating: 9, count: 16)
        let code = Pairing.verificationCode(host: host, client: phone, token: token)
        #expect(code.count == 6)
        #expect(code.allSatisfy { $0.isNumber })
        #expect(code == Pairing.verificationCode(host: host, client: phone, token: token))
        let attacker = Fingerprint(certificateDER: Data("attacker".utf8))
        #expect(code != Pairing.verificationCode(host: host, client: attacker, token: token))
    }

    @Test func trustStorePinsAndRevokes() throws {
        var store = TrustStore()
        let hostID = UUID()
        store.pin(PairedPeer(fingerprint: host, name: "Mac", hostID: hostID))
        #expect(store.trusts(host))
        #expect(store.peer(hostID: hostID)?.name == "Mac")

        let url = FileManager.default.temporaryDirectory.appending(path: "pd-trust-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try store.save(to: url)
        #expect(try TrustStore.load(from: url) == store)

        store.revoke(host)
        #expect(!store.trusts(host))
    }
}

/// Touches the real Keychain (login keychain on macOS), so it cleans up after itself.
@Suite(.serialized) struct DeviceIdentityTests {
    @Test func createsThenReloadsSameIdentity() throws {
        let label = "com.pocketdesk.tests.\(UUID().uuidString)"
        defer { DeviceIdentity.delete(label: label) }

        let created = try DeviceIdentity.loadOrCreate(label: label)
        let loaded = try #require(try DeviceIdentity.load(label: label))
        #expect(loaded.fingerprint == created.fingerprint)
        #expect(Fingerprint(certificateDER: loaded.certificateDER) == created.fingerprint)

        DeviceIdentity.delete(label: label)
        #expect(try DeviceIdentity.load(label: label) == nil)
    }
}
