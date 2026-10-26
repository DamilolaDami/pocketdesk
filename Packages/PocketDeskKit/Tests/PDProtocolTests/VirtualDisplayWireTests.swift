import Foundation
import Testing
@testable import PDProtocol

struct VirtualDisplayWireTests {
    @Test func requestsAndReportsRoundTrip() throws {
        let leaseID = UUID(), requestID = UUID()
        let report = VirtualDisplayReport(revision: 7, supported: true, allowed: true, modes: [.standard], phase: .active,
            workspace: .init(leaseID: leaseID, logicalID: "stable-logical-id", displayID: 99, ownerName: "iPad", isOwner: true,
                acceptedMode: .standard, geometry: .init(x: -1280, y: 200, width: 1280, height: 800, pixelWidth: 1280, pixelHeight: 800)),
            requestID: requestID, requestedMode: .init(width: 960, height: 1280))
        for message in [ControlMessage.watchVirtualDisplay, .createVirtualDisplay(.init(id: requestID, mode: .standard)),
                        .endVirtualDisplay(.init(leaseID: leaseID)), .virtualDisplay(report),
                        .virtualDisplay(.init(problem: .disabled, message: "Enable on the Mac"))] {
            #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }
    @Test func devicePreferencesAreBoundedAndKeepAspectWithoutRetinaMultiplication() {
        let phone = VirtualDisplayMode.preferred(for: .init(width: 402, height: 874, scale: 3))
        let pad = VirtualDisplayMode.preferred(for: .init(width: 1366, height: 1024, scale: 2))
        #expect(phone.height == 1280 && phone.width < phone.height && phone.isBoundedRequest)
        #expect(pad.width == 1280 && pad.height < pad.width && pad.isBoundedRequest)
        #expect(VirtualDisplayMode.preferred(for: .init(width: .nan, height: .infinity, scale: 2)) == .standard)
        #expect(!VirtualDisplayMode(width: Int.max, height: -1).isBoundedRequest)
        #expect(!VirtualDisplayMode(width: 1280, height: 800, scale: 2).isBoundedRequest)
    }
}
