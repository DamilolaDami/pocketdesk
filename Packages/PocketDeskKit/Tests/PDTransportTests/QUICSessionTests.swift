import Foundation
import Network
import PDProtocol
import PDSecurity
import Testing
@testable import PDTransport

/// Real QUIC over 127.0.0.1 with two Keychain identities. Every test calls
/// `removeIdentities()` so nothing is left in the login keychain.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct QUICSessionTests {
    let hostIdentity: DeviceIdentity
    let phoneIdentity: DeviceIdentity

    init() throws {
        let run = UUID().uuidString
        hostIdentity = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.tests.host.\(run)")
        phoneIdentity = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.tests.phone.\(run)")
    }

    func removeIdentities() {
        DeviceIdentity.delete(label: hostIdentity.label)
        DeviceIdentity.delete(label: phoneIdentity.label)
    }

    @Test func allThreeChannelsFlowBetweenPinnedPeers() async throws {
        defer { removeIdentities() }
        let phone = phoneIdentity.fingerprint
        let listener = try QUICHostListener(identity: hostIdentity, advertise: nil) { $0 == phone }
        let received = HostLog()

        let server = Task {
            try await listener.run { session in
                await received.record(peer: session.peer)
                for try await message in session.controlMessages {
                    await received.record(message)
                    guard case .hello = message else { continue }
                    try await session.send(.helloAck(HelloAck(hostName: "Test Host", displays: [])))
                    let header = VideoFrameHeader(frameID: 1, captureTimeMicros: 99, flags: .keyframe,
                                                  payloadLength: 3, sourceGeneration: 0)
                    try await session.send(frame: header, payload: [1, 2, 3])
                    for try await event in session.inputEvents {
                        await received.record(event)
                        break
                    }
                }
            }
        }
        defer { server.cancel() }

        let port = try await waitForPort(listener)
        try await QUICClient.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!),
                                     identity: phoneIdentity, host: hostIdentity.fingerprint) { session in
            try await session.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 400, height: 800, scale: 3))))

            var controls = session.controlMessages.makeAsyncIterator()
            let ack = try await controls.next()
            #expect(ack == .helloAck(HelloAck(hostName: "Test Host", displays: [])))

            var frames = session.videoFrames.makeAsyncIterator()
            let frame = try #require(try await frames.next())
            #expect(frame.0.frameID == 1)
            #expect(frame.0.flags.contains(.keyframe))
            #expect(frame.1 == [1, 2, 3])

            // Datagrams are unreliable: resend until the host has one.
            for _ in 0..<50 where await received.events.isEmpty {
                try await session.send(InputEvent.pointerMove(x: 0.5, y: 0.25))
                try await Task.sleep(for: .milliseconds(20))
            }
            try await session.send(.bye(reason: "done"))
            for _ in 0..<100 where await !received.messages.contains(.bye(reason: "done")) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        #expect(await received.peers == [phone])
        #expect(await received.events.first == .pointerMove(x: 0.5, y: 0.25))
        #expect(await received.messages.contains(.bye(reason: "done")))
    }

    @Test func hostRejectsUnpinnedPhone() async throws {
        defer { removeIdentities() }
        let listener = try QUICHostListener(identity: hostIdentity, advertise: nil) { _ in false }
        let server = Task { try await listener.run { _ in Issue.record("unpinned phone got a session") } }
        defer { server.cancel() }

        let port = try await waitForPort(listener)
        await #expect(throws: (any Error).self) {
            try await QUICClient.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!),
                                         identity: phoneIdentity, host: hostIdentity.fingerprint) { session in
                try await session.send(.ping(1))
                _ = try await session.controlMessages.first { _ in true }
            }
        }
    }

    @Test func phoneRejectsImpostorHost() async throws {
        defer { removeIdentities() }
        let listener = try QUICHostListener(identity: hostIdentity, advertise: nil) { _ in true }
        let server = Task { try await listener.run { _ in Issue.record("phone connected to the wrong host") } }
        defer { server.cancel() }

        let port = try await waitForPort(listener)
        let expected = Fingerprint(certificateDER: Data("some other mac".utf8))
        await #expect(throws: (any Error).self) {
            try await QUICClient.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!),
                                         identity: phoneIdentity, host: expected, timeout: .seconds(2)) { session in
                try await session.send(.ping(1))
            }
        }
    }
}

extension QUICSessionTests {
    @Test func discoversAndConnectsOverBonjour() async throws {
        defer { removeIdentities() }
        let hostID = UUID()
        let phone = phoneIdentity.fingerprint
        let listener = try QUICHostListener(identity: hostIdentity,
                                            advertise: .init(name: "PocketDesk Test \(hostID.uuidString.prefix(4))", hostID: hostID)) { $0 == phone }
        let server = Task {
            try await listener.run { session in
                for try await message in session.controlMessages {
                    if case .ping(let n) = message { try await session.send(.pong(n)) }
                }
            }
        }
        defer { server.cancel() }

        var found: BrowsedHost?
        for try await hosts in HostBrowser.hosts() {
            found = hosts.first { $0.hostID == hostID }
            if found != nil { break }
        }
        let host = try #require(found)
        #expect(host.protocolVersion == protocolVersion)

        try await QUICClient.connect(to: host.endpoint, identity: phoneIdentity, host: hostIdentity.fingerprint) { session in
            try await session.send(.ping(7))
            let reply = try await session.controlMessages.first { _ in true }
            #expect(reply == .pong(7))
        }
    }
}

extension QUICSessionTests {
    /// A failing session must end only its own connection; the next phone still gets in.
    @Test func listenerSurvivesAFailedSession() async throws {
        defer { removeIdentities() }
        let phone = phoneIdentity.fingerprint
        let listener = try QUICHostListener(identity: hostIdentity, advertise: nil) { $0 == phone }
        let sessions = HostLog()
        let server = Task {
            try await listener.run { session in
                await sessions.record(peer: session.peer)
                if await sessions.peers.count == 1 {
                    try await session.send(.bye(reason: "first fails"))
                    throw TransportError.closed
                }
                for try await message in session.controlMessages {
                    if case .ping(let n) = message { try await session.send(.pong(n)) }
                }
            }
        }
        defer { server.cancel() }
        let port = try await waitForPort(listener)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)

        // The first session's handler throws right away. (Whether its bye arrives is a race;
        // HostSession flushes final messages with `finish(with:)`, tested in PDHostCoreTests.)
        try? await QUICClient.connect(to: endpoint, identity: phoneIdentity, host: hostIdentity.fingerprint) { session in
            try await session.send(.ping(1))
            _ = try await session.controlMessages.first { _ in true }
        }

        try await QUICClient.connect(to: endpoint, identity: phoneIdentity, host: hostIdentity.fingerprint, timeout: .seconds(3)) { session in
            try await session.send(.ping(2))
            #expect(try await session.controlMessages.first { _ in true } == .pong(2))
        }
        #expect(await sessions.peers.count == 2)
    }
}

func waitForPort(_ listener: QUICHostListener) async throws -> UInt16 {
    for _ in 0..<200 {
        if let port = listener.port { return port }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw TransportError.closed
}

actor HostLog {
    private(set) var peers: [Fingerprint] = []
    private(set) var messages: [ControlMessage] = []
    private(set) var events: [InputEvent] = []

    func record(peer: Fingerprint) { peers.append(peer) }
    func record(_ message: ControlMessage) { messages.append(message) }
    func record(_ event: InputEvent) { events.append(event) }
}
