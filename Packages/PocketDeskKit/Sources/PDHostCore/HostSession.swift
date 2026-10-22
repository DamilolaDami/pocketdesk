#if os(macOS)
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PDProtocol
import PDSecurity
import PDTransport

/// Decides who may use this Mac. Implemented by `HostService`.
public protocol PairingAuthority: Sendable {
    func isTrusted(_ peer: Fingerprint) async -> Bool
    /// Checks `token` against the open invite, asks the person at the Mac to confirm the
    /// verification code, and pins the phone if they accept.
    func approve(peer: Fingerprint, deviceName: String, token: [UInt8]) async -> Bool
}

/// One phone's session: pairing gate, handshake, then streaming until either side ends it.
///
/// Video pump: capture → (drop if the network is behind) → encode → send. Frames are dropped
/// *before* encoding so the phone never sees stale frames and the encoder never queues.
public actor HostSession {
    public struct Configuration: Sendable {
        public var hostName: String
        public var fps: Int
        /// Frames allowed between "submitted to the encoder" and "QUIC accepted it".
        public var maxFramesInFlight: Int
        /// Re-encodes of the last frame once the screen goes still (see `refineStillFrame`).
        public var refineFrames: Int

        public init(hostName: String, fps: Int = 60, maxFramesInFlight: Int = 2, refineFrames: Int = 8) {
            self.hostName = hostName
            self.fps = fps
            self.maxFramesInFlight = maxFramesInFlight
            self.refineFrames = refineFrames
        }
    }

    public enum Event: Sendable {
        case connected(peer: Fingerprint, deviceName: String)
        case streaming(peer: Fingerprint, config: StreamConfig, window: WindowInfo?)
    }

    public struct Stats: Sendable, Equatable {
        public var framesSent = 0
        public var framesDropped = 0
        public var bytesSent = 0
    }

    private let session: any PeerSession
    private let peer: Fingerprint
    private let configuration: Configuration
    private let frameSource: any FrameSource
    private let input: any InputSink
    private let pairing: any PairingAuthority
    private let onEvent: @Sendable (Event) -> Void

    private var viewport = Viewport(width: 390, height: 844, scale: 3)
    private var encoder: HEVCEncoder?
    private var pumpTasks: [Task<Void, Never>] = []
    private var generation: UInt32 = 0
    private var nextFrameID: UInt32 = 0
    private var framesInFlight = 0
    private var lastFrameAccepted = ContinuousClock.now
    private var lastFrame: CapturedFrame?
    private var lastCaptureAt = ContinuousClock.now
    private var refinesLeft = 0
    public private(set) var stats = Stats()

    public init(session: any PeerSession, peer: Fingerprint, configuration: Configuration,
                frameSource: any FrameSource, input: any InputSink, pairing: any PairingAuthority,
                onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.session = session
        self.peer = peer
        self.configuration = configuration
        self.frameSource = frameSource
        self.input = input
        self.pairing = pairing
        self.onEvent = onEvent
    }

    /// Runs until the phone says bye, the connection drops, or the task is cancelled.
    public func run() async throws {
        do {
            try await runSession()
        } catch {
            await stopStreaming()
            throw error
        }
        await stopStreaming()
    }

    private func runSession() async throws {
        var messages = session.controlMessages.makeAsyncIterator()

        if await !pairing.isTrusted(peer) {
            guard case .pairRequest(let request)? = try await messages.next() else {
                try await session.send(.bye(reason: "Not paired with this Mac"))
                return
            }
            let accepted = await pairing.approve(peer: peer, deviceName: request.deviceName, token: request.token)
            try await session.send(.pairResult(accepted: accepted))
            guard accepted else { return }
        }

        guard case .hello(let hello)? = try await messages.next() else {
            try await session.send(.bye(reason: "Expected hello"))
            return
        }
        guard hello.version == protocolVersion else {
            try await session.send(.bye(reason: "Unsupported protocol version \(hello.version)"))
            return
        }
        viewport = hello.viewport
        onEvent(.connected(peer: peer, deviceName: hello.deviceName))
        do {
            // Listing displays already needs Screen Recording, so it's inside the goodbye path.
            let displays = try await frameSource.displays()
            try await session.send(.helloAck(HelloAck(hostName: configuration.hostName, displays: displays)))
            try await startStreaming(nil)
        } catch {
            // Tell the phone why instead of just dropping the connection.
            await sayGoodbye(Self.describeStreamingFailure(error))
            throw error
        }

        let inputTask = Task { [session, input] in
            for try await event in session.inputEvents { input.inject(event) }
        }
        defer { inputTask.cancel() }

        while let message = try await messages.next() {
            switch message {
            case .requestKeyframe:
                encoder?.requestKeyframe()
            case .listWindows:
                try await session.send(.windows(try await frameSource.windows()))
            case .selectSource(let windowID):
                do {
                    try await startStreaming(windowID.map(CaptureSource.window))
                } catch {
                    await sayGoodbye(Self.describeStreamingFailure(error))
                    throw error
                }
            case .insertText(let text):
                input.insertText(text)
            case .ping(let value):
                try await session.send(.pong(value))
            case .bye:
                return
            case .hello, .helloAck, .pairRequest, .pairResult, .windows, .streamConfig, .pong:
                continue
            }
        }
    }

    // MARK: Streaming

    /// Sends `bye` and waits for the phone to hang up (up to a second): closing the QUIC
    /// connection straight away would discard the unsent reason.
    private func sayGoodbye(_ reason: String) async {
        try? await session.send(.bye(reason: reason))
        let controlMessages = session.controlMessages
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do { for try await _ in controlMessages {} } catch {}
            }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
    }

    static func describeStreamingFailure(_ error: any Error) -> String {
        if !CGPreflightScreenCaptureAccess() {
            return "PocketDesk on the Mac needs Screen Recording permission (System Settings › Privacy & Security)."
        }
        switch error {
        case CaptureError.sourceNotFound: return "That window or display isn't available any more."
        case EncoderError.sessionCreation(let status): return "The Mac couldn't start the video encoder (\(status))."
        default: return "The Mac couldn't start streaming: \(error.localizedDescription)"
        }
    }

    private func startStreaming(_ source: CaptureSource?) async throws {
        stopPump()
        let resolved = try await frameSource.resolve(source)
        let size = StreamSizing.fit(sourceWidth: resolved.pixelWidth, sourceHeight: resolved.pixelHeight, into: viewport)
        let config = StreamConfig(codec: .hevc, width: size.width, height: size.height, fps: configuration.fps,
                                  bitrateKbps: StreamSizing.bitrateKbps(width: size.width, height: size.height,
                                                                        fps: configuration.fps))
        let encoder = try HEVCEncoder(width: config.width, height: config.height, fps: config.fps,
                                      bitrateKbps: config.bitrateKbps)
        generation &+= 1
        framesInFlight = 0
        lastFrame = nil
        refinesLeft = 0
        self.encoder = encoder
        input.setSourceFrame(resolved.screenFrame)

        // The phone learns the new size before the first frame of the new generation.
        try await session.send(.streamConfig(config))
        let frames = try await frameSource.start(resolved, width: config.width, height: config.height, fps: config.fps)
        onEvent(.streaming(peer: peer, config: config, window: resolved.window))

        let generation = generation
        pumpTasks = [
            Task { await self.pumpCapture(frames, into: encoder) },
            Task { await self.pumpEncoded(from: encoder, generation: generation) },
            Task { await self.refineStillFrames(into: encoder) },
        ]
    }

    private func pumpCapture(_ frames: AsyncStream<CapturedFrame>, into encoder: HEVCEncoder) async {
        for await frame in frames {
            guard !Task.isCancelled else { return }
            lastFrame = frame
            lastCaptureAt = .now
            refinesLeft = configuration.refineFrames
            submit(frame.pixelBuffer, presentationTime: frame.presentationTime, to: encoder)
        }
    }

    /// ScreenCaptureKit only delivers frames when pixels change, so after a change the encoder
    /// would never get the follow-up frames its rate control uses to sharpen a quickly coded
    /// picture: a still screen stays blurry. Once the screen has been still briefly, feed the
    /// last frame again a few times; each re-encode spends bits on the remaining error.
    private func refineStillFrames(into encoder: HEVCEncoder) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
            guard refinesLeft > 0, let lastFrame, ContinuousClock.now - lastCaptureAt > .milliseconds(150) else { continue }
            refinesLeft -= 1
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            submit(lastFrame.pixelBuffer, presentationTime: now, to: encoder)
        }
    }

    private func submit(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, to encoder: HEVCEncoder) {
        // An encoder error can lose a frame without output; don't let that stall the pump.
        if framesInFlight >= configuration.maxFramesInFlight, ContinuousClock.now - lastFrameAccepted < .seconds(1) {
            stats.framesDropped += 1
            return
        }
        if framesInFlight >= configuration.maxFramesInFlight { framesInFlight = 0 }
        framesInFlight += 1
        encoder.encode(pixelBuffer, presentationTime: presentationTime)
    }

    private func pumpEncoded(from encoder: HEVCEncoder, generation: UInt32) async {
        for await frame in encoder.frames {
            guard !Task.isCancelled else { return }
            var flags: VideoFrameHeader.Flags = []
            if frame.isKeyframe { flags.formUnion([.keyframe, .parameterSets]) }
            let header = VideoFrameHeader(frameID: nextFrameID, captureTimeMicros: frame.presentationTimeMicros,
                                          flags: flags, payloadLength: UInt32(frame.payload.count),
                                          sourceGeneration: generation)
            nextFrameID &+= 1
            do {
                try await session.send(frame: header, payload: frame.payload)
            } catch {
                return
            }
            framesInFlight = max(0, framesInFlight - 1)
            lastFrameAccepted = .now
            stats.framesSent += 1
            stats.bytesSent += frame.payload.count
        }
    }

    private func stopPump() {
        for task in pumpTasks { task.cancel() }
        pumpTasks = []
        encoder = nil
    }

    private func stopStreaming() async {
        stopPump()
        await frameSource.stop()
    }
}
#endif
