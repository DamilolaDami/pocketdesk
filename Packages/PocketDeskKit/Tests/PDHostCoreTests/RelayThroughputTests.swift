#if os(macOS)
    import Foundation
    import Network
    import PDProtocol
    import PDClientCore
    import PDSecurity
    import PDTransport
    import Testing
    @testable import PDHostCore

    /// How fast video gets through a relay. Against the deployed relay
    /// (`POCKETDESK_RELAY_REMOTE=relay.pocketdesk.runmira.dev:4433`) both ends run here, so every
    /// packet goes out to the relay and back: a real long-round-trip path, like a phone on cellular.
    ///
    /// Known issue: through the deployed relay this measures well under 0.1 Mbps, because about
    /// one full-size packet in five is lost while streaming (small packets and a local relay are
    /// fine). The cause isn't found yet; see "Open questions" in docs/RELAY.md.
    @Suite(.serialized, .timeLimit(.minutes(2)))
    struct RelayThroughputTests {
        static let frames = 40
        static let frameSize = 30_000

        /// The same transfer through a relay on this Mac (`POCKETDESK_RELAY_BINARY`), where
        /// round trips are near zero: separates "slow because far" from "slow regardless".
        @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETDESK_RELAY_BINARY"] != nil))
        func videoThroughLocalRelay() async throws {
            let binary = try #require(ProcessInfo.processInfo.environment["POCKETDESK_RELAY_BINARY"])
            let (server, pin, stop) = try await LocalRelay.start(binary: binary)
            defer { stop() }
            let kbps = try await measure(server: server, pin: pin)
            print("Local relay throughput: \(kbps) kbps")
            #expect(kbps > 1_500)
        }

        @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETDESK_RELAY_REMOTE"] != nil))
        func videoThroughDeployedRelay() async throws {
            let address = try #require(ProcessInfo.processInfo.environment["POCKETDESK_RELAY_REMOTE"])
            let server = try #require(RelayServer(address: address))
            let kbps = try await measure(server: server, pin: nil)
            print("Relay throughput: \(kbps) kbps over \(Self.frames) frames of \(Self.frameSize) bytes")
            // Well above the stream's lowest step (800 kbps) on any working connection.
            #expect(kbps > 1_500)
        }

        private func measure(server: RelayServer, pin: Fingerprint?) async throws -> Int {
            let suffix = UUID().uuidString
            let host = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.test.throughput.host.\(suffix)")
            let phone = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.test.throughput.phone.\(suffix)")
            defer { for id in [host, phone] { DeviceIdentity.delete(label: id.label) } }
            let listener = try QUICHostListener(identity: host, advertise: nil, maxUDPPayloadSize: 1200, loopbackOnly: true) {
                $0 == phone.fingerprint
            }
            let listenerTask = Task {
                try await listener.run { session in
                    var controls = session.controlMessages.makeAsyncIterator()
                    guard case .hello = try await controls.next() else { return }
                    try await session.send(.helloAck(HelloAck(hostName: "Relayed Mac", displays: [])))
                    for id in 1...Self.frames {
                        try await session.send(
                            frame: VideoFrameHeader(
                                frameID: UInt32(id), captureTimeMicros: UInt64(id), flags: id == 1 ? .keyframe : [],
                                payloadLength: UInt32(Self.frameSize), sourceGeneration: 0),
                            payload: Array(repeating: UInt8(id % 251), count: Self.frameSize))
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
            let status = ThroughputStatus()
            let agent = RelayAgent(
                identity: host, hostID: UUID(), port: try #require(listenerPort), server: server,
                peers: [phone.fingerprint], serverPin: pin
            ) { value in Task { await status.set(value) } }
            let agentTask = Task { await agent.run() }
            defer { agentTask.cancel() }
            for _ in 0..<2000 {
                if await status.ready { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await status.ready)
            let unavailableLAN = try RelayLoopbackSocket()
            defer { unavailableLAN.close() }
            let result = ThroughputResult()
            try await PathFinder.connect(
                local: .hostPort(host: "127.0.0.1", port: .init(rawValue: unavailableLAN.port)!),
                relay: server, identity: phone, host: host.fingerprint, serverPin: pin,
                onPath: { #expect($0 == .relay) }
            ) { session in
                try await session.send(
                    .hello(Hello(deviceName: "Phone", viewport: Viewport(width: 400, height: 800, scale: 3))))
                var controls = session.controlMessages.makeAsyncIterator()
                _ = try await controls.next()
                var frames = session.videoFrames.makeAsyncIterator()
                var start: ContinuousClock.Instant?
                for id in 1...Self.frames {
                    let frame = try #require(try await frames.next())
                    if start == nil { start = .now }
                    #expect(frame.1.count == Self.frameSize && frame.1.first == UInt8(id % 251))
                }
                let elapsed = ContinuousClock.now - (start ?? .now)
                // Everything after the first frame arrived in `elapsed`.
                let bits = Double((Self.frames - 1) * Self.frameSize * 8)
                await result.set(Int(bits / (elapsed / .seconds(1)) / 1000))
                try await session.send(.bye(reason: "done"))
            }
            return await result.kbps
        }
    }

    /// A throwaway relay process with a self-signed certificate, pinned by the test.
    enum LocalRelay {
        static func start(binary: String) async throws -> (RelayServer, Fingerprint, () -> Void) {
            let directory = FileManager.default.temporaryDirectory.appending(path: "relay-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let cert = directory.appending(path: "cert.pem")
            let key = directory.appending(path: "key.pem")
            let config = directory.appending(path: "openssl.cnf")
            try "[req]\ndistinguished_name=dn\n[dn]\n[server_cert]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n"
                .write(to: config, atomically: true, encoding: .utf8)
            try run("/usr/bin/openssl", [
                "req", "-config", config.path, "-extensions", "server_cert", "-x509", "-newkey", "ec", "-pkeyopt",
                "ec_paramgen_curve:P-256", "-pkeyopt", "ec_param_enc:named_curve", "-nodes", "-keyout", key.path,
                "-out", cert.path, "-days", "1", "-subj", "/CN=localhost",
            ])
            let pkcs8 = directory.appending(path: "key-pkcs8.pem")
            try run("/usr/bin/openssl", ["pkcs8", "-topk8", "-nocrypt", "-in", key.path, "-out", pkcs8.path])
            let der = directory.appending(path: "cert.der")
            try run("/usr/bin/openssl", ["x509", "-in", cert.path, "-outform", "DER", "-out", der.path])
            let pin = Fingerprint(certificateDER: try Data(contentsOf: der))
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
            for _ in 0..<100 {
                if (try? String(contentsOf: logURL, encoding: .utf8).contains("listening")) == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let stop = {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                try? output.close()
                try? FileManager.default.removeItem(at: directory)
            }
            return (RelayServer(host: "127.0.0.1", port: port), pin, stop)
        }
        private static func run(_ path: String, _ arguments: [String]) throws {
            let p = Process()
            p.executableURL = URL(filePath: path)
            p.arguments = arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
    }

    private actor ThroughputStatus {
        var ready = false
        func set(_ value: HostRelayStatus) { ready = value == .ready }
    }
    private actor ThroughputResult {
        var kbps = 0
        func set(_ value: Int) { kbps = value }
    }
#endif
