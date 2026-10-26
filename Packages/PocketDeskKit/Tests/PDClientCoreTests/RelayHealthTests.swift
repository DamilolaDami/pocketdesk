import Foundation
import Testing
@testable import PDClientCore
import PDProtocol

struct RelayHealthTests {
    @Test func staleResultsCannotMarkAnotherServerOrNewerCheckReady() {
        var state = RelayHealthState()
        #expect(state.status == .unchecked)
        let old = state.begin(server: RelayServer(host: "old.example", port: 4433))
        let current = state.begin(server: RelayServer(host: "custom.example", port: 7443))
        state.finish(checkID: old, reachable: true)
        #expect(state.status == .checking && state.checkedAt == nil)
        #expect(state.server?.port == 7443)
        state.finish(checkID: current, reachable: false)
        #expect(state.status == .unreachable)
        state.finish(checkID: current, reachable: true)
        #expect(state.status == .unreachable)
        let retry = state.begin(server: state.server!)
        state.finish(checkID: retry, reachable: true)
        #expect(state.status == .reachable)
        state = RelayHealthState()
        state.finish(checkID: retry, reachable: true)
        #expect(state.status == .unchecked)
    }
}
