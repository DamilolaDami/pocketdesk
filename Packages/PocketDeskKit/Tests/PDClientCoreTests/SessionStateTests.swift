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

    @Test func aDroppedStreamReconnectsAndKeepsWhatItShowed() {
        let window = WindowInfo(id: 1, appName: "Notes", bundleID: nil, title: "Todo", width: 800, height: 600)
        var state = SessionState.streaming(host: newHost, config: config, source: window)
            .reduce(.interrupted(reason: "The Mac closed the connection."))
        #expect(state == .reconnecting(host: newHost, config: config, source: window, attempt: 1))

        state = state.reduce(.interrupted(reason: "Couldn't reach the Mac."))
        #expect(state == .reconnecting(host: newHost, config: config, source: window, attempt: 2))
        // Still on the screen it was: a window picked meanwhile doesn't count.
        #expect(state.reduce(.sourceChanged(nil)) == state)

        // The Mac starts again on a display; the controller asks for the window.
        let smaller = StreamConfig(codec: .hevc, width: 1600, height: 1200, fps: 60, bitrateKbps: 8_000)
        #expect(state.reduce(.connected(smaller)) == .streaming(host: newHost, config: smaller, source: nil))
    }

    @Test func reconnectingEndsOnAFinalReasonOrCancel() {
        let state = SessionState.reconnecting(host: newHost, config: config, source: nil, attempt: 3)
        #expect(state.reduce(.disconnected(reason: "Declined on the Mac")) == .failed(message: "Declined on the Mac"))
        #expect(state.reduce(.cancel) == .idle)
    }

    @Test func onlyAStreamThatWasUpReconnects() {
        #expect(SessionState.connecting(host: newHost).reduce(.interrupted(reason: "Couldn't reach the Mac."))
                == .failed(message: "Couldn't reach the Mac."))
        #expect(SessionState.pairing(host: newHost, code: "123456").reduce(.interrupted(reason: "Lost"))
                == .failed(message: "Lost"))
        #expect(SessionState.idle.reduce(.interrupted(reason: "Lost")) == .idle)
    }

    @Test func reconnectAttemptsBackOffThenStop() {
        let policy = ReconnectPolicy()
        #expect(policy.delay(beforeAttempt: 0) == nil)
        #expect(policy.delay(beforeAttempt: 1) == .milliseconds(500))
        #expect(policy.delay(beforeAttempt: 2) == .seconds(1))
        let delays = (1...policy.delays.count).compactMap(policy.delay(beforeAttempt:))
        #expect(delays == delays.sorted())
        #expect(delays.reduce(.zero, +) < .seconds(30))
        #expect(policy.delay(beforeAttempt: policy.delays.count + 1) == nil)
        #expect(ReconnectPolicy.gaveUp(on: "Studio Mac", reason: "Couldn't reach the Mac.")
                == "Couldn't reconnect to Studio Mac. Couldn't reach the Mac.")
    }
}
