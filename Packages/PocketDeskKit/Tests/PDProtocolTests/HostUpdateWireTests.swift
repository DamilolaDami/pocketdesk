import Foundation
import PDProtocol
import Testing

struct HostUpdateWireTests {
    @Test func maintenanceEnvelopeStaysVersionIndependent() throws {
        #expect(maintenanceALPN == "pocketdesk-maintenance/1")
        // Preserve this fixture as stream protocol versions evolve.
        let fixture = Data(#"{"hostUpdate":{"_0":{"action":"install","deviceName":"Phone"}}}"#.utf8)
        #expect(try JSONDecoder().decode(ControlMessage.self, from: fixture) == .hostUpdate(.init(action: .install, deviceName: "Phone")))
        let status = HostUpdateStatus(phase: .downloading, version: "1.2", build: "100", hostProtocol: 999, progress: 0.5)
        let message = ControlMessage.hostUpdateStatus(status)
        #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
    }
}
