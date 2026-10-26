import Foundation
import PDProtocol
import Testing
@testable import PDClientCore

struct VirtualDisplaySelectionTests {
    @Test func requestAcknowledgmentDoesNotOptimisticallySelectOrEraseNewerStatus() {
        let id = UUID()
        let initial = VirtualDisplayReport(revision: 4, supported: true, allowed: true, modes: [.standard])
        let state = VirtualDisplaySelection().reduce(.received(initial)).reduce(.requested(id))
        #expect(state.isBusy)
        #expect(state.reduce(.requested(UUID())).pendingID == id)
        let newer = state.reduce(.received(.init(revision: 7, supported: true, allowed: false)))
        let staleAck = newer.reduce(.received(.init(revision: 5, requestID: id, problem: .disabled, message: "Disabled on Mac")))
        #expect(staleAck.report?.revision == 7)
        #expect(staleAck.pendingID == nil)
        #expect(staleAck.problem == "Disabled on Mac")
        #expect(staleAck.reduce(.reset) == VirtualDisplaySelection())
    }
    @Test func onlyMatchingRequestCanFinishOrTimeOutThePendingAction() {
        let id = UUID()
        let state = VirtualDisplaySelection().reduce(.requested(id))
        #expect(state.reduce(.received(.init(requestID: UUID()))).pendingID == id)
        #expect(state.reduce(.timedOut(UUID())).pendingID == id)
        let expired = state.reduce(.timedOut(id))
        #expect(!expired.isBusy && expired.problem != nil)
    }
    @Test @MainActor func disconnectAndSwitchingMacsClearOwnershipAndPendingRequests() {
        let store = SessionStore()
        store.update(virtualDisplay: .received(.init(revision: 4, supported: true, allowed: true)))
        store.update(virtualDisplay: .requested(UUID()))
        store.send(.cancel)
        #expect(store.virtualDisplay == VirtualDisplaySelection())
    }
}
