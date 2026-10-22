#if os(macOS)
// Uses the macOS host engines (encoder, capture, HostService).
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Network
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDClientCore
@testable import PDHostCore

/// The phone's `ClientConnection` against the real `HostService` over QUIC on 127.0.0.1:
/// pairing with an invite, then video into a display layer, then input to the Mac.
@Suite(.serialized, .timeLimit(.minutes(1)))
final class ClientConnectionTests {
    let run = UUID().uuidString
    let trustStoreURL: URL
    let phone: DeviceIdentity

    init() throws {
        trustStoreURL = FileManager.default.temporaryDirectory.appending(path: "pd-client-tests-\(run)/trusted.json")
        phone = try DeviceIdentity.loadOrCreate(label: "com.pocketdesk.tests.phone.\(run)")
    }

    deinit {
        DeviceIdentity.delete(label: phone.label)
        DeviceIdentity.delete(label: "com.pocketdesk.tests.host.\(run)")
        try? FileManager.default.removeItem(at: trustStoreURL.deletingLastPathComponent())
    }

    @Test func pairsStreamsIntoTheLayerAndSendsInput() async throws {
        let input = SinkRecorder()
        let box = HostBox()
        let service = try HostService(
            configuration: .init(hostID: UUID(), hostName: "Test Mac", identityLabel: "com.pocketdesk.tests.host.\(run)",
                                 trustStoreURL: trustStoreURL, advertise: false),
            makeFrameSource: { MovingFrames() }, input: input
        ) { event in
            if case .approvalRequested(let approval) = event {
                Task { await box.service?.resolveApproval(approval.id, accepted: true) }
            }
        }
        await box.set(service)
        let serviceTask = Task { try await service.run() }
        defer { serviceTask.cancel() }
        var port: UInt16?
        for _ in 0..<200 where port == nil {
            port = await service.port
            try await Task.sleep(for: .milliseconds(10))
        }
        let invite = await service.openInvite()

        let layer = AVSampleBufferDisplayLayer()
        let display = VideoDisplay()
        display.attach(layer)
        let events = ClientEvents()
        let connection = ClientConnection(
            identity: phone,
            request: .init(endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: try #require(port))!),
                           hostFingerprint: invite.hostFingerprint, invite: invite,
                           deviceName: "Test iPhone", viewport: Viewport(width: 402, height: 874, scale: 3)),
            display: display
        ) { events.append($0) }
        let connectionTask = Task { await connection.run() }

        for _ in 0..<300 where !events.all.contains(where: { if case .streamConfig = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Frames flow into the layer's renderer.
        for _ in 0..<300 where layer.sampleBufferRenderer.status != .rendering {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(layer.sampleBufferRenderer.status == .rendering)

        for _ in 0..<100 where input.events.isEmpty {
            connection.send(.pointerMove(x: 0.25, y: 0.75))
            try await Task.sleep(for: .milliseconds(20))
        }
        connection.send(.listWindows)
        for _ in 0..<100 where !events.all.contains(where: { if case .windows = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        // A shortcut the Mac can't run comes back as a notice; the session carries on.
        connection.send(.run(.openApp(bundleID: nil, name: "Missing")))
        for _ in 0..<100 where !events.all.contains(where: { if case .notice = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        connectionTask.cancel()
        await connectionTask.value

        let all = events.all
        let code = Pairing.verificationCode(host: invite.hostFingerprint, client: phone.fingerprint, token: invite.token)
        #expect(all.first == .awaitingApproval(code: code))
        #expect(all.contains(.paired(PairedPeer(fingerprint: invite.hostFingerprint, name: "Test Mac",
                                                hostID: invite.hostID, pairedAt: pairedAt(in: all)))))
        #expect(all.contains { if case .streamConfig(let config) = $0 { config.width == 1280 } else { false } })
        #expect(all.contains { if case .windows(let windows) = $0 { windows.count == 1 } else { false } })
        #expect(all.contains(.notice("Missing isn't installed on this Mac.")))
        #expect(all.last == .ended(reason: nil))
        #expect(input.events.first == .pointerMove(x: 0.25, y: 0.75))
    }

    @Test func declinedPairingEndsWithReason() async throws {
        let box = HostBox()
        let service = try HostService(
            configuration: .init(hostID: UUID(), hostName: "Test Mac", identityLabel: "com.pocketdesk.tests.host.\(run)",
                                 trustStoreURL: trustStoreURL, advertise: false),
            makeFrameSource: { MovingFrames() }, input: SinkRecorder()
        ) { event in
            if case .approvalRequested(let approval) = event {
                Task { await box.service?.resolveApproval(approval.id, accepted: false) }
            }
        }
        await box.set(service)
        let serviceTask = Task { try await service.run() }
        defer { serviceTask.cancel() }
        var port: UInt16?
        for _ in 0..<200 where port == nil {
            port = await service.port
            try await Task.sleep(for: .milliseconds(10))
        }
        let invite = await service.openInvite()
        let events = ClientEvents()
        let connection = ClientConnection(
            identity: phone,
            request: .init(endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: try #require(port))!),
                           hostFingerprint: invite.hostFingerprint, invite: invite,
                           deviceName: "Test iPhone", viewport: Viewport(width: 402, height: 874, scale: 3)),
            display: VideoDisplay()
        ) { events.append($0) }
        await connection.run()
        #expect(events.all.last == .ended(reason: ClientError.pairingDeclined.description))
    }

    private func pairedAt(in events: [ClientEvent]) -> Date {
        for event in events { if case .paired(let peer) = event { return peer.pairedAt } }
        return .distantPast
    }
}

/// 1280×720 frames that change every tick.
actor MovingFrames: FrameSource {
    private var task: Task<Void, Never>?
    func displays() -> [DisplayInfo] { [DisplayInfo(id: 1, width: 1280, height: 720)] }
    func windows() -> [WindowInfo] { [WindowInfo(id: 7, appName: "Notes", bundleID: nil, title: "Todo", width: 640, height: 480)] }
    func resolve(_ source: CaptureSource?) -> ResolvedSource {
        ResolvedSource(source: .display(1), pixelWidth: 1280, pixelHeight: 720, screenFrame: CGRect(x: 0, y: 0, width: 1280, height: 720))
    }
    func start(_ source: ResolvedSource, width: Int, height: Int, fps: Int) -> AsyncStream<CapturedFrame> {
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        task = Task {
            var index: Int64 = 0
            while !Task.isCancelled {
                continuation.yield(CapturedFrame(pixelBuffer: flatFrame(width: width, height: height, luma: UInt8(truncatingIfNeeded: index * 9)),
                                                 presentationTime: CMTime(value: index, timescale: 30)))
                index += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
            continuation.finish()
        }
        return stream
    }
    func stop() { task?.cancel() }
}

final class SinkRecorder: InputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [InputEvent] = []
    var events: [InputEvent] { lock.withLock { _events } }
    func setSourceFrame(_ frame: CGRect) {}
    func inject(_ event: InputEvent) { lock.withLock { _events.append(event) } }
    func insertText(_ text: String) {}
    func perform(_ action: MacAction) async throws {
        throw MacActionError.appNotFound("Missing")
    }
}

final class ClientEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ClientEvent] = []
    var all: [ClientEvent] { lock.withLock { events } }
    func append(_ event: ClientEvent) { lock.withLock { events.append(event) } }
}

actor HostBox {
    private(set) var service: HostService?
    func set(_ service: HostService) { self.service = service }
}
#endif
