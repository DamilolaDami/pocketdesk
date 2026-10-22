import Testing
import PDProtocol
@testable import PDClientCore

@Suite struct SessionStateTests {
    let newHost = DiscoveredHost(id: "a", name: "Studio Mac", isPaired: false)
    let config = StreamConfig(codec: .hevc, width: 1206, height: 2622, fps: 60, bitrateKbps: 12_000)

    @Test func unpairedHostGoesThroughPairing() {
        var state = SessionState.idle
        for event: SessionEvent in [.startDiscovery, .hostsChanged([newHost]), .select(newHost)] {
            state = state.reduce(event)
        }
        #expect(state == .pairing(host: newHost, code: nil))

        // Confirming before the code arrives is ignored.
        #expect(state.reduce(.pairingConfirmed) == state)

        state = state.reduce(.pairingCode("123456")).reduce(.pairingConfirmed)
        guard case .connecting(let host) = state else { Issue.record("expected connecting"); return }
        #expect(host.isPaired)

        state = state.reduce(.connected(config))
        #expect(state == .streaming(host: host, config: config, source: nil))
    }

    @Test func pairedHostConnectsDirectly() {
        let paired = DiscoveredHost(id: "b", name: "Laptop", isPaired: true)
        let state = SessionState.discovering(hosts: [paired]).reduce(.select(paired))
        #expect(state == .connecting(host: paired))
    }

    @Test func disconnectWhileStreamingFails() {
        let state = SessionState.streaming(host: newHost, config: config, source: nil)
            .reduce(.disconnected(reason: "Mac went to sleep"))
        #expect(state == .failed(message: "Mac went to sleep"))
    }

    @Test func laterConfigsUpdateTheStreamAndKeepTheSource() {
        let window = WindowInfo(id: 1, appName: "Notes", bundleID: nil, title: "Todo", width: 800, height: 600)
        let smaller = StreamConfig(codec: .hevc, width: 1600, height: 1200, fps: 60, bitrateKbps: 8_000)
        let state = SessionState.streaming(host: newHost, config: config, source: nil)
            .reduce(.sourceChanged(window))
            .reduce(.connected(smaller))
        #expect(state == .streaming(host: newHost, config: smaller, source: window))
    }

    @Test func cancelAlwaysReturnsToIdle() {
        #expect(SessionState.connecting(host: newHost).reduce(.cancel) == .idle)
    }
}
