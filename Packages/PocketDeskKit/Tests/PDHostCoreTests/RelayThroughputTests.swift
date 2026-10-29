#if os(macOS)
    import Foundation
    import Network
    import Synchronization
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

        /// The local relay behind a stand-in for Fly's public UDP path: payloads over 1,200 bytes
        /// are dropped, there's a round trip, and now and then a packet arrives late, behind the
        /// next. Reordering used to cost most two-piece packets (about 0.8 Mbps here, and under
        /// 0.1 Mbps through the deployed relay); oversized packets vanished without a trace.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETDESK_RELAY_BINARY"] != nil))
        func videoThroughRelayWithFlysUDPLimit() async throws {
            let binary = try #require(ProcessInfo.processInfo.environment["POCKETDESK_RELAY_BINARY"])
            let (relay, pin, stop) = try await LocalRelay.start(binary: binary)
            defer { stop() }
            let proxy = try UDPLimitProxy(upstream: relay.port, limit: 1200, delay: .milliseconds(10),
                                          late: (share: 0.05, by: .microseconds(500)))
            defer { proxy.close() }
            let kbps = try await measure(server: RelayServer(host: "127.0.0.1", port: proxy.port), pin: pin)
            let dropped = proxy.dropped
            print("Relay throughput over a Fly-like path: \(kbps) kbps; oversized: \(dropped)")
            #expect(dropped.toRelay == 0 && dropped.fromRelay == 0)
            #expect(kbps > 1_500)
        }

        /// The deployed relay's leg back to a device loses about 2% of pieces. Losing either
        /// half of a split packet lost it, which held this path near 250 kbps; a parity piece
        /// rebuilds the packet from any two of its three pieces.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["POCKETDESK_RELAY_BINARY"] != nil))
        func videoThroughRelayWithLossyDownloadLeg() async throws {
            let binary = try #require(ProcessInfo.processInfo.environment["POCKETDESK_RELAY_BINARY"])
            let (relay, pin, stop) = try await LocalRelay.start(binary: binary)
            defer { stop() }
            let proxy = try UDPLimitProxy(upstream: relay.port, limit: 1200, delay: .milliseconds(67), loss: 0.02)
            defer { proxy.close() }
            let kbps = try await measure(server: RelayServer(host: "127.0.0.1", port: proxy.port), pin: pin)
            print("Relay throughput with 2% loss from the relay: \(kbps) kbps; lost: \(proxy.dropped.lost)")
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

    /// Forwards UDP between clients on this Mac and a relay on `upstream`, dropping (and
    /// counting) payloads over `limit` bytes the way Fly's public UDP path does. Each packet
    /// waits `delay`; a `late` share waits a little longer, so it lands behind the next, and a
    /// `loss` share of the relay's packets back to clients never arrives.
    final class UDPLimitProxy: Sendable {
        struct Dropped: Sendable, CustomStringConvertible {
            var toRelay = 0, fromRelay = 0, largest = 0, lost = 0
            var description: String { "\(toRelay) to the relay, \(fromRelay) from it, largest \(largest) bytes" }
        }
        let port: UInt16
        private let front: RelayLoopbackSocket
        private let counts = Mutex(Dropped())
        private let backs = Mutex([UInt16: RelayLoopbackSocket]())
        private let tasks = Mutex([Task<Void, Never>]())
        var dropped: Dropped { counts.withLock { $0 } }

        private let delay: DispatchTimeInterval
        private let late: (share: Double, by: DispatchTimeInterval)
        private let loss: Double
        private let queue = DispatchQueue(label: "pocketdesk.tests.udp-proxy")

        init(upstream: UInt16, limit: Int, delay: DispatchTimeInterval,
             late: (share: Double, by: DispatchTimeInterval) = (0, .never), loss: Double = 0) throws {
            self.delay = delay
            self.late = late
            self.loss = loss
            front = try RelayLoopbackSocket()
            port = front.port
            let front = front
            let task = Task { [self] in
                do {
                    for try await (data, client) in front.packets {
                        guard pass(data, limit: limit, toRelay: true) else { continue }
                        let back = try backs.withLock { backs in
                            if let back = backs[client] { return (back, false) }
                            let back = try RelayLoopbackSocket()
                            backs[client] = back
                            return (back, true)
                        }
                        if back.1 { relayBack(back.0, to: client, limit: limit) }
                        later { try? back.0.send(data, to: upstream) }
                    }
                } catch {}
            }
            tasks.withLock { $0.append(task) }
        }

        private func relayBack(_ back: RelayLoopbackSocket, to client: UInt16, limit: Int) {
            let front = front
            let task = Task { [self] in
                do {
                    for try await (data, _) in back.packets where pass(data, limit: limit, toRelay: false) {
                        if Double.random(in: 0..<1) < loss {
                            counts.withLock { $0.lost += 1 }
                            continue
                        }
                        later { try? front.send(data, to: client) }
                    }
                } catch {}
            }
            tasks.withLock { $0.append(task) }
        }

        /// A serial queue runs equal delays in the order they were scheduled.
        private func later(_ work: @escaping @Sendable () -> Void) {
            var deadline = DispatchTime.now() + delay
            if Double.random(in: 0..<1) < late.share { deadline = deadline + late.by }
            queue.asyncAfter(deadline: deadline, execute: work)
        }

        private func pass(_ data: Data, limit: Int, toRelay: Bool) -> Bool {
            guard data.count > limit else { return true }
            counts.withLock {
                if toRelay { $0.toRelay += 1 } else { $0.fromRelay += 1 }
                $0.largest = max($0.largest, data.count)
            }
            return false
        }

        func close() {
            tasks.withLock { for task in $0 { task.cancel() } }
            front.close()
            backs.withLock { for back in $0.values { back.close() } }
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
