import Foundation
import Testing
@testable import PDSecurity

@Suite struct PairingTests {
    @Test func bothSidesDeriveTheSameCode() throws {
        let host = DeviceIdentity()
        let phone = DeviceIdentity()
        let invite = PairingInvite.make(hostID: UUID(), hostName: "Studio Mac", identity: host)

        let hostKey = try Pairing.sharedKey(identity: host, peerPublicKey: phone.publicKey, token: invite.token)
        let phoneKey = try Pairing.sharedKey(identity: phone, peerPublicKey: invite.hostPublicKey, token: invite.token)

        let code = Pairing.verificationCode(for: hostKey)
        #expect(code.count == 6)
        #expect(code == Pairing.verificationCode(for: phoneKey))
    }

    @Test func differentTokenGivesDifferentKey() throws {
        let host = DeviceIdentity()
        let phone = DeviceIdentity()
        let a = try Pairing.sharedKey(identity: host, peerPublicKey: phone.publicKey, token: Data([1]))
        let b = try Pairing.sharedKey(identity: host, peerPublicKey: phone.publicKey, token: Data([2]))
        #expect(a != b)
    }

    @Test func rejectsMalformedPublicKey() {
        #expect(throws: PairingError.self) {
            try Pairing.sharedKey(identity: DeviceIdentity(), peerPublicKey: Data([0, 1, 2]), token: Data())
        }
    }
}
