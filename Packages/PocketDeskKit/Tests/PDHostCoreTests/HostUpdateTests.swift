#if os(macOS)
import Foundation
import PDProtocol
import PDSecurity
import PDTransport
import Testing
@testable import PDHostCore

@Suite(.serialized, .timeLimit(.minutes(1)))
struct HostUpdateTests {
    @Test func maintenanceNeedsExistingTrustAndNeverStartsCapture() async throws {
        for trusted in [false, true] {
            let pair = LoopbackSession.pair(), updater = RecordingUpdater(), frames = SyntheticFrameSource()
            let session = HostSession(session: pair.host, peer: .init(bytes: Data(repeating: 6, count: 32)),
                configuration: .init(hostName: "Test"), frameSource: frames, input: RecordingInputSink(),
                pairing: UpdateAuthority(trusted: trusted, allowed: true), hostUpdater: updater)
            let host = Task { try await session.run() }
            try await pair.client.send(.hostUpdate(.init(action: .status, deviceName: "Phone")))
            var control = pair.client.controlMessages.makeAsyncIterator()
            let reply = try #require(try await control.next())
            if trusted {
                guard case .hostUpdateStatus(let status) = reply else { Issue.record("expected maintenance status"); return }
                #expect(status.hostProtocol == protocolVersion)
                try await pair.client.send(.hostUpdate(.init(action: .install, deviceName: "Phone")))
                guard case .hostUpdateStatus(let next)? = try await control.next() else { Issue.record("expected update start"); return }
                #expect(next.phase == .downloading)
                // Maintenance cannot become a streaming session, even with a valid hello.
                try await pair.client.send(.hello(.init(deviceName: "Phone", viewport: .init(width: 400, height: 800, scale: 2))))
                try await host.value
                #expect(await updater.installs == 1)
            } else {
                guard case .bye = reply else { Issue.record("untrusted maintenance must be refused"); return }
                await pair.client.close(); _ = await host.result
                #expect(await updater.installs == 0)
            }
            #expect(await frames.startedSources.isEmpty)
            await pair.client.close()
        }
    }
    @Test func installRespectsMacApproval() async throws {
        let pair = LoopbackSession.pair(), updater = RecordingUpdater()
        let session = HostSession(session: pair.host, peer: .init(bytes: Data(repeating: 6, count: 32)),
            configuration: .init(hostName: "Test"), frameSource: SyntheticFrameSource(), input: RecordingInputSink(),
            pairing: UpdateAuthority(trusted: true, allowed: false), hostUpdater: updater)
        let host = Task { try await session.run() }
        try await pair.client.send(.hostUpdate(.init(action: .install, deviceName: "Phone")))
        var replies = pair.client.controlMessages.makeAsyncIterator()
        guard case .hostUpdateStatus(let denied)? = try await replies.next() else { Issue.record("expected refusal"); return }
        #expect(denied.phase == .failed)
        await pair.client.close()
        try await host.value
        #expect(await updater.installs == 0)
        await pair.client.close()
    }
}
actor RecordingUpdater: HostUpdating {
    private(set) var installs = 0
    let finishesImmediately: Bool
    init(finishesImmediately: Bool = false) { self.finishesImmediately = finishesImmediately }
    func status() -> HostUpdateStatus { .init(phase: installs == 0 ? .idle : (finishesImmediately ? .upToDate : .downloading), version: "1.1", build: "87") }
    func install() -> HostUpdateStatus { installs += 1; return status() }
}
private struct UpdateAuthority: PairingAuthority {
    let trusted: Bool
    let allowed: Bool
    func isTrusted(_ peer: Fingerprint) async -> Bool { trusted }
    func approve(peer: Fingerprint, deviceName: String, token: [UInt8]) async -> Bool { false }
    func allowSession(peer: Fingerprint, deviceName: String) async -> Bool { allowed }
}
#endif
