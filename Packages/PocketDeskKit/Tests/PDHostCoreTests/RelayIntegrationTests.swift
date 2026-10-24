#if os(macOS)
    import Foundation
    import Network
    import PDProtocol
    import PDClientCore
    import PDSecurity
    import PDTransport
    import Testing
    @testable import PDHostCore

    /// Run with POCKETDESK_RELAY_BINARY pointing to `cargo build`'s Quinn executable.
    @Suite(.serialized, .timeLimit(.minutes(1)))
    struct RelayIntegrationTests {
        @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETDESK_RELAY_BINARY"] != nil))
        func appleQUICThroughQuinnPreservesPinnedSession() async throws {
            let binary = try #require(ProcessInfo.processInfo.environment["POCKETDESK_RELAY_BINARY"])
            let directory = FileManager.default.temporaryDirectory.appending(path: "relay-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cert = directory.appending(path: "cert.pem")
            let key = directory.appending(path: "key.pem")
            let config = directory.appending(path: "openssl.cnf")
            try
                "[req]\ndistinguished_name=dn\n[dn]\n[server_cert]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n"
                .write(to: config, atomically: true, encoding: .utf8)
            try run(
                "/usr/bin/openssl",
                [
                    "req", "-config", config.path, "-extensions", "server_cert", "-x509", "-newkey", "ec", "-pkeyopt",
                    "ec_paramgen_curve:P-256", "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-keyout", key.path,
                    "-out", cert.path, "-days", "1", "-subj", "/CN=localhost",
                ])
            let pkcs8 = directory.appending(path: "key-pkcs8.pem")
            try run("/usr/bin/openssl", ["pkcs8", "-topk8", "-nocrypt", "-in", key.path, "-out", pkcs8.path])
            let der = directory.appending(path: "cert.der")
            try run("/usr/bin/openssl", ["x509", "-in", cert.path, "-outform", "DER", "-out", der.path])
            let relayPin = Fingerprint(certificateDER: try Data(contentsOf: der))
            let reservation = try RelayLoopbackSocket()
            let port = reservation.port
            reservation.close()
            let logURL = directory.appending(path: "server.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let output = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(filePath: binary)
            process.arguments = ["--listen", "127.0.0.1:\(port)", "--cert", cert.path, "--key", pkcs8.path]
            process.standardError = output
            process.standardOutput = output
            try process.run()
            defer {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                try? output.close()
            }
            for _ in 0..<100 {
                if (try? String(contentsOf: logURL, encoding: .utf8).contains("listening")) == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let startup = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "No startup log"
            try #require(process.isRunning, Comment(rawValue: startup))
            let server = RelayServer(host: "127.0.0.1", port: port)
            try await exercise(server: server, relayPin: relayPin)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETDESK_RELAY_REMOTE"] != nil))
        func deployedRelayPreservesPinnedSession() async throws {
            let address = try #require(ProcessInfo.processInfo.environment["POCKETDESK_RELAY_REMOTE"])
            let server = try #require(RelayServer(address: address))
            let certificatePath = ProcessInfo.processInfo.environment["POCKETDESK_RELAY_REMOTE_CERT_DER"]
            let pin = try certificatePath.map { Fingerprint(certificateDER: try Data(contentsOf: URL(filePath: $0))) }
            try await exercise(server: server, relayPin: pin)
        }

        private func exercise(server: RelayServer, relayPin: Fingerprint?) async throws {
            let suffix = UUID().uuidString
            let host = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.test.relay.host.\(suffix)")
            let phone = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.test.relay.phone.\(suffix)")
            let stranger = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.test.relay.stranger.\(suffix)")
            defer { for id in [host, phone, stranger] { DeviceIdentity.delete(label: id.label) } }
            let listener = try QUICHostListener(identity: host, advertise: nil, maxUDPPayloadSize: 1200, loopbackOnly: true) { $0 == phone.fingerprint }
            let input = RelayInput()
            let listenerTask = Task {
                try await listener.run { session in
                    var controls = session.controlMessages.makeAsyncIterator()
                    guard case .hello = try await controls.next() else { return }
                    try await session.send(.helloAck(HelloAck(hostName: "Relayed Mac", displays: [])))
                    try await session.send(
                        frame: VideoFrameHeader(
                            frameID: 1, captureTimeMicros: 10, flags: .keyframe,
                            payloadLength: 30_000, sourceGeneration: 0), payload: Array(repeating: 77, count: 30_000))
                    try await session.send(
                        audio: AudioFrameHeader(captureTimeMicros: 10, sourceGeneration: 0, payloadLength: 100),
                        payload: Array(repeating: 22, count: 100))
                    for try await event in session.inputEvents {
                        await input.record(event)
                        break
                    }
                    while let message = try await controls.next() { if case .bye = message { return } }
                }
            }
            defer { listenerTask.cancel() }
            var listenerPort: UInt16?
            for _ in 0..<200 {
                if let port = listener.port {
                    listenerPort = port
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            let status = RelayStatusLog()
            let agent = RelayAgent(
                identity: host, hostID: UUID(), port: try #require(listenerPort), server: server,
                peers: [phone.fingerprint], serverPin: relayPin
            ) { value in Task { await status.set(value) } }
            let agentTask = Task { await agent.run() }
            defer { agentTask.cancel() }
            for _ in 0..<2000 {
                if await status.ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await status.ready)
            do {
                try await RelayPhonePath.connect(
                    server: server, identity: stranger, host: host.fingerprint, serverPin: relayPin
                ) { _ in
                    Issue.record("Unpaired phone reached forwarding")
                }
                Issue.record("Unpaired request should fail")
            } catch RelayError.notFound {}
            let unavailableLAN = try RelayLoopbackSocket()
            defer { unavailableLAN.close() }
            try await PathFinder.connect(
                local: .hostPort(host: "127.0.0.1", port: .init(rawValue: unavailableLAN.port)!),
                relay: server, identity: phone, host: host.fingerprint, serverPin: relayPin,
                onPath: { #expect($0 == .relay) }
            ) { session in
                #expect(session.peer == host.fingerprint)
                try await session.send(
                    .hello(Hello(deviceName: "Phone", viewport: Viewport(width: 400, height: 800, scale: 3))))
                var controls = session.controlMessages.makeAsyncIterator()
                #expect(try await controls.next() == .helloAck(HelloAck(hostName: "Relayed Mac", displays: [])))
                var frames = session.videoFrames.makeAsyncIterator()
                let frame = try #require(try await frames.next())
                #expect(frame.1 == Array(repeating: 77, count: 30_000))
                var audio = session.audioFrames.makeAsyncIterator()
                #expect(try await audio.next()?.1 == Array(repeating: 22, count: 100))
                for _ in 0..<50 {
                    if await input.event != nil { break }
                    try await session.send(.pointerMove(x: 0.5, y: 0.25))
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(await input.event == .pointerMove(x: 0.5, y: 0.25))
                try await session.send(.bye(reason: "done"))
            }
            await agent.update(peers: [])
            do {
                try await RelayPhonePath.connect(
                    server: server, identity: phone, host: host.fingerprint, serverPin: relayPin
                ) { _ in
                    Issue.record("Revoked phone reached forwarding")
                }
                Issue.record("Revoked request should fail")
            } catch RelayError.notFound {}
        }
        private func run(_ path: String, _ arguments: [String]) throws {
            let p = Process()
            p.executableURL = URL(filePath: path)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
    }
    private actor RelayStatusLog {
        var ready = false
        func set(_ value: HostRelayStatus) { ready = value == .ready }
    }
    private actor RelayInput {
        var event: InputEvent?
        func record(_ value: InputEvent) { event = value }
    }
#endif
