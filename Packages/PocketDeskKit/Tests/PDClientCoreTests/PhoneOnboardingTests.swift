import Testing
import PDProtocol
@testable import PDClientCore

struct PhoneOnboardingTests {
    private let host = DiscoveredHost(id: "mac", name: "Mac", isPaired: true)
    private let config = StreamConfig(codec: .hevc, width: 1206, height: 2622, fps: 60, bitrateKbps: 12_000)

    @Test func onlyNewUnpairedUsersSeeAutomaticSetup() {
        #expect(PhoneOnboarding(finished: false, hasPairedMacs: false).isPresented)
        #expect(!PhoneOnboarding(finished: true, hasPairedMacs: false).isPresented)
        #expect(!PhoneOnboarding(finished: false, hasPairedMacs: true).isPresented)
    }

    @Test func navigationAndAlreadyReadyShortcut() {
        var flow = PhoneOnboarding(finished: false, hasPairedMacs: false)
        flow.back()
        #expect(flow.step == .welcome)
        flow.advance()
        #expect(flow.step == .mac)
        flow.advance()
        #expect(flow.step == .find)
        flow.advance()
        #expect(flow.step == .find)
        flow.back()
        #expect(flow.step == .mac)
        flow.findMac()
        #expect(flow.step == .find)
    }

    @Test func cancelledOrFailedPairingDoesNotFinishSetup() {
        var flow = PhoneOnboarding(finished: false, hasPairedMacs: false)
        flow.findMac()
        for state in [SessionState.pairing(host: host, code: "123456"), .connecting(host: host),
                      .failed(message: "Declined"), .idle] {
            flow.receive(state)
            #expect(flow.isPresented)
            #expect(flow.step == .find)
            #expect(!flow.showsControls)
        }
    }

    @Test func controlsAppearOnceAfterARealConnection() {
        var flow = PhoneOnboarding(finished: false, hasPairedMacs: false)
        let stream = SessionState.streaming(host: host, config: config, source: nil)
        flow.receive(stream)
        #expect(!flow.isPresented)
        #expect(flow.showsControls)
        flow.dismissControls()
        flow.receive(stream)
        #expect(!flow.showsControls)
        flow.receive(.idle)
        flow.receive(stream)
        #expect(!flow.showsControls)
    }

    @Test func existingUsersDoNotGetTipsOverTheirStream() {
        var flow = PhoneOnboarding(finished: false, hasPairedMacs: true)
        flow.receive(.streaming(host: host, config: config, source: nil))
        #expect(!flow.showsControls)
    }

    @Test func skippingLeavesPairingAndFirstConnectionAvailable() {
        var flow = PhoneOnboarding(finished: false, hasPairedMacs: false)
        flow.dismiss()
        #expect(!flow.isPresented)
        flow.receive(.streaming(host: host, config: config, source: nil))
        #expect(flow.showsControls)
        flow.receive(.failed(message: "Disconnected"))
        #expect(!flow.showsControls)
    }
}
