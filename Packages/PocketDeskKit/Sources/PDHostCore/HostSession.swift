#if os(macOS)
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import PDProtocol
import PDSecurity
import PDTransport

/// Decides who may use this Mac. Implemented by `HostService`.
public protocol PairingAuthority: Sendable {
    func isTrusted(_ peer: Fingerprint) async -> Bool
    /// Checks `token` against the open invite, asks the person at the Mac to confirm the
    /// verification code, and pins the phone if they accept.
    func approve(peer: Fingerprint, deviceName: String, token: [UInt8]) async -> Bool
    /// A paired phone wants to stream: may it? (Yes, unless the Mac asks before each one.)
    func allowSession(peer: Fingerprint, deviceName: String) async -> Bool
}

public extension PairingAuthority {
    func allowSession(peer: Fingerprint, deviceName: String) async -> Bool { true }
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
        /// How often the link is measured and the stream refitted (see `RateController`).
        public var adaptInterval: Duration
        /// Told to the phone in `helloAck` so it can wake this Mac later.
        public var wake: WakeInfo?
        /// How often the Mac's clipboard is checked for something new to send.
        public var clipboardInterval: Duration
        /// How often volume and now playing are checked for a phone watching them.
        public var statusInterval: Duration

        public init(hostName: String, fps: Int = 60, maxFramesInFlight: Int = 2, refineFrames: Int = 8,
                    adaptInterval: Duration = .milliseconds(500), wake: WakeInfo? = nil,
                    clipboardInterval: Duration = .milliseconds(500), statusInterval: Duration = .seconds(1)) {
            self.clipboardInterval = clipboardInterval
            self.statusInterval = statusInterval
            self.hostName = hostName
            self.fps = fps
            self.maxFramesInFlight = maxFramesInFlight
            self.refineFrames = refineFrames
            self.adaptInterval = adaptInterval
            self.wake = wake
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
    private let catalog: any AppCatalogSource
    private let clipboard: any ClipboardSink
    private let onEvent: @Sendable (Event) -> Void

    private var audioEnabled = true
    private var clipboardEnabled = false
    private var clipboardTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    /// The Mac clipboard's change count as last sent or written; anything newer goes out.
    private var clipboardSeen = 0
    private var currentSource: CaptureSource?
    private var selectedDisplayID: UInt32?
    private var viewport = Viewport(width: 390, height: 844, scale: 3)
    private var encoder: HEVCEncoder?
    private var pumpTasks: [Task<Void, Never>] = []
    private var inputTask: Task<Void, Never>?
    private var generation: UInt32 = 0
    private var nextFrameID: UInt32 = 0
    private var framesInFlight = 0
    private var lastFrameAccepted = ContinuousClock.now
    private var lastFrame: CapturedFrame?
    private var lastCaptureAt = ContinuousClock.now
    private var refinesLeft = 0
    public private(set) var stats = Stats()

    // Link adaptation. Bitrate and frame rate change in place; resolution restarts the stream.
    private var rate = RateController()
    private var adaptTask: Task<Void, Never>?
    /// Stream restarts, one at a time: the message loop and adaptation can both ask for one.
    private var streamChange: Task<Void, any Error>?
    /// What the current stream size gets at full quality.
    private var fullBitrateKbps = 0
    private var lastSubmitAt = ContinuousClock.now
    private var sendTime = Duration.zero
    private var sends = 0
    private let clockEpoch = ContinuousClock.now
    private var pendingPing: (value: UInt64, sentAt: ContinuousClock.Instant)?
    private var roundTrip: Duration?
    private var smoothedRoundTrip: Duration?
    /// A restart opens with a keyframe burst that isn't the link's fault: skip that window.
    private var settling = false
    static let minBitrateKbps = 800
    static let log = Logger(subsystem: "com.pocketdesk.host", category: "session")

    public init(session: any PeerSession, peer: Fingerprint, configuration: Configuration,
                frameSource: any FrameSource, input: any InputSink, pairing: any PairingAuthority,
                catalog: any AppCatalogSource = InstalledApps(), clipboard: any ClipboardSink = MacPasteboard(),
                onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.catalog = catalog
        self.clipboard = clipboard
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

        var first = try await messages.next()
        var justPaired = false
        if await pairing.isTrusted(peer) {
            // The phone gave up waiting just before the person at the Mac accepted, and asked
            // again: it's already pinned, so say yes.
            if case .pairRequest? = first {
                try await session.send(.pairResult(accepted: true))
                first = try await messages.next()
            }
        } else {
            guard case .pairRequest(let request)? = first else {
                await finish(with: .bye(reason: "Not paired with this Mac"))
                return
            }
            let accepted = await pairing.approve(peer: peer, deviceName: request.deviceName, token: request.token)
            guard accepted else {
                await finish(with: .pairResult(accepted: false))
                return
            }
            try await session.send(.pairResult(accepted: true))
            justPaired = true
            first = try await messages.next()
        }

        guard case .hello(let hello)? = first else {
            await finish(with: .bye(reason: "Expected hello"))
            return
        }
        guard hello.version == protocolVersion else {
            await finish(with: .bye(reason: "Unsupported protocol version \(hello.version)"))
            return
        }
        audioEnabled = hello.audioEnabled
        viewport = hello.viewport
        if hello.mode == .catalog {
            // A quick question from the shortcut editor, or a shortcut run from Siri or a widget:
            // no picture, no input, no "connected".
            try await session.send(.helloAck(HelloAck(hostName: configuration.hostName, displays: [],
                                                      wake: configuration.wake)))
            var allowed: Bool?
            defer { statusTask?.cancel() }
            while let message = try await messages.next() {
                switch message {
                case .listApps, .requestAppIcons, .listMacShortcuts: try await answer(message)
                case .watchStatus: startWatchingStatus()
                case .run(let action):
                    // Running something is using the Mac: "Ask Before Each Connection" applies.
                    if allowed == nil { allowed = await pairing.allowSession(peer: peer, deviceName: hello.deviceName) }
                    guard allowed == true else {
                        try await session.send(.actionFailed("The Mac didn't allow this."))
                        continue
                    }
                    try await run(action)
                case .bye: return
                default: continue
                }
            }
            return
        }
        // The person at the Mac just approved this phone; don't ask them twice.
        if !justPaired, await !pairing.allowSession(peer: peer, deviceName: hello.deviceName) {
            await finish(with: .bye(reason: "The Mac didn't allow this connection."))
            return
        }
        onEvent(.connected(peer: peer, deviceName: hello.deviceName))
        do {
            // Listing displays already needs Screen Recording, so it's inside the goodbye path.
            let displays = try await frameSource.displays()
            try await session.send(.helloAck(HelloAck(hostName: configuration.hostName, displays: displays,
                                                      wake: configuration.wake)))
            let preferred = hello.preferredDisplayID.flatMap { saved in displays.first { $0.persistentID == saved }?.id }
            do {
                try await startStreaming(preferred.map(CaptureSource.display))
            } catch CaptureError.sourceNotFound where preferred != nil {
                // The saved monitor may disappear between enumeration and capture.
                try await startStreaming(nil)
            }
        } catch {
            // Tell the phone why instead of just dropping the connection.
            await finish(with: .bye(reason: Self.describeStreamingFailure(error)))
            throw error
        }

        adaptTask = Task { await self.adaptToLink() }
        clipboardEnabled = hello.clipboardEnabled
        clipboardSeen = await clipboard.changeCount()
        clipboardTask = Task { await self.watchClipboard() }
        // Owned by the actor so `stopStreaming` can wait for it: tasks holding the session must
        // not outlive the connection.
        inputTask = Task { [session, input] in
            do { for try await event in session.inputEvents { input.inject(event) } } catch {}
        }

        while let message = try await messages.next() {
            switch message {
            case .setAudioEnabled(let enabled):
                if enabled != audioEnabled {
                    audioEnabled = enabled
                    try await startStreaming(currentSource)
                }
            case .requestKeyframe:
                encoder?.requestKeyframe()
            case .clipboard(let item):
                guard clipboardEnabled, item.fitsLimits, !item.isEmpty else { continue }
                clipboardSeen = await clipboard.write(item)
            case .setClipboardEnabled(let enabled):
                clipboardEnabled = enabled
                // Turning it back on mustn't send whatever was copied while it was off.
                if enabled { clipboardSeen = await clipboard.changeCount() }
            case .listDisplays:
                try await session.send(.displays(try await frameSource.displays()))
            case .selectDisplay(let id):
                // Resolve before stopping the current pump: a stale picker must not end it.
                do {
                    try await startStreaming(.display(id))
                } catch CaptureError.sourceNotFound {
                    try await session.send(.displays(try await frameSource.displays()))
                    try await session.send(.actionFailed("That display is no longer connected. Choose another display."))
                }
            case .listWindows:
                try await session.send(.windows(try await frameSource.windows()))
            case .selectSource(let windowID):
                do {
                    try await startStreaming(windowID.map(CaptureSource.window) ?? selectedDisplayID.map(CaptureSource.display))
                } catch {
                    await finish(with: .bye(reason: Self.describeStreamingFailure(error)))
                    throw error
                }
            case .insertText(let text):
                input.insertText(text)
            case .key(let press):
                input.inject(.key(code: press.code, isDown: press.isDown, modifiers: press.modifiers))
            case .run(let action):
                try await run(action)
            case .listApps, .requestAppIcons, .listMacShortcuts:
                try await answer(message)
            case .watchStatus:
                startWatchingStatus()
            case .ping(let value):
                try await session.send(.pong(value))
            case .pong(let value):
                if let pendingPing, pendingPing.value == value {
                    let sample = ContinuousClock.now - pendingPing.sentAt
                    roundTrip = max(roundTrip ?? .zero, sample)
                    smoothedRoundTrip = smoothedRoundTrip.map { $0 * 0.8 + sample * 0.2 } ?? sample
                    self.pendingPing = nil
                }
            case .bye:
                return
            case .hello, .helloAck, .pairRequest, .pairResult, .windows, .displays, .streamConfig, .linkQuality,
                 .actionFailed, .apps, .appIcon, .macShortcuts, .macStatus:
                continue
            }
        }
    }

    /// Live tiles: the status now, then again whenever it changes.
    private func startWatchingStatus() {
        guard statusTask == nil else { return }
        statusTask = Task { await self.watchStatus() }
    }

    private func watchStatus() async {
        var last: MacStatus?
        while !Task.isCancelled {
            let status = await catalog.status()
            if status != last {
                guard (try? await session.send(.macStatus(status))) != nil else { return }
                last = status
            }
            try? await Task.sleep(for: configuration.statusInterval)
        }
    }

    /// A phone shortcut; one that can't be done says why.
    private func run(_ action: MacAction) async throws {
        guard action.isValid else {
            try await session.send(.actionFailed("That shortcut has too many steps or too long a wait."))
            return
        }
        do {
            try await input.perform(action)
        } catch {
            try await session.send(.actionFailed(String(describing: error)))
        }
    }

    private func answer(_ question: ControlMessage) async throws {
        switch question {
        case .listMacShortcuts:
            try await session.send(.macShortcuts(await catalog.shortcuts()))
        case .listApps:
            try await session.send(.apps(await catalog.apps()))
        case .requestAppIcons(let bundleIDs):
            for bundleID in bundleIDs.prefix(1000) {
                let png = await catalog.iconPNG(bundleID: bundleID)
                try await session.send(.appIcon(AppIcon(bundleID: bundleID, png: png?.base64EncodedString())))
            }
        default:
            break
        }
    }

    /// Ends the session from the Mac: the phone is told why and hangs up, which ends `run`.
    /// If it doesn't within a couple of seconds, the connection is closed anyway.
    public func end(reason: String) async {
        try? await session.send(.bye(reason: reason))
        let session = session
        Task {
            try? await Task.sleep(for: .seconds(2))
            await session.close()
        }
    }

    // MARK: Streaming

    /// Sends a session's last message and waits for the phone to hang up (up to a second):
    /// closing the QUIC connection straight away would discard it unsent.
    private func finish(with message: ControlMessage) async {
        try? await session.send(message)
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

    /// `keepingSource` restarts whatever is streaming when the restart actually runs (link
    /// adaptation must not undo a display switch queued ahead of it).
    private func startStreaming(_ source: CaptureSource?, keepingSource: Bool = false) async throws {
        let previous = streamChange
        let change = Task {
            _ = await previous?.result
            try await self.restartStreaming(keepingSource ? self.currentSource : source)
        }
        streamChange = change
        try await change.value
    }

    private func restartStreaming(_ source: CaptureSource?) async throws {
        let resolved = try await frameSource.resolve(source)
        let full = StreamSizing.fit(sourceWidth: resolved.pixelWidth, sourceHeight: resolved.pixelHeight, into: viewport)
        let size = StreamSizing.scale(full, by: rate.step.scale)
        let displayID: UInt32?
        if case .display(let id) = resolved.source { displayID = id } else { displayID = nil }
        fullBitrateKbps = StreamSizing.bitrateKbps(width: full.width, height: full.height, fps: configuration.fps)
        let config = StreamConfig(codec: .hevc, width: size.width, height: size.height, fps: streamFPS,
                                  bitrateKbps: streamBitrateKbps, displayID: displayID)
        let encoder = try HEVCEncoder(width: config.width, height: config.height, fps: config.fps,
                                      bitrateKbps: config.bitrateKbps)
        await stopPump()
        currentSource = resolved.source
        if let displayID { selectedDisplayID = displayID }
        generation &+= 1
        framesInFlight = 0
        lastFrame = nil
        refinesLeft = 0
        self.encoder = encoder
        input.setSourceFrame(resolved.screenFrame)

        // The phone learns the new size before the first frame of the new generation.
        try await session.send(.streamConfig(config))
        await frameSource.configureAudio(enabled: audioEnabled, generation: generation)
        let frames = try await frameSource.start(resolved, width: config.width, height: config.height, fps: config.fps)
        onEvent(.streaming(peer: peer, config: config, window: resolved.window))
        settling = true

        let audioFrames = await frameSource.audioFrames()
        let generation = generation
        pumpTasks = [
            Task {
                do {
                    for try await (header, payload) in audioFrames {
                        guard !Task.isCancelled else { return }
                        try await self.session.send(audio: header, payload: payload)
                    }
                } catch {
                    if !Task.isCancelled {
                        try? await self.session.send(.actionFailed("Mac audio stopped: \(error.localizedDescription)"))
                    }
                }
            },
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
            // Capture runs at the session's rate; a lower link-fitted rate skips frames here.
            // A skipped last frame still reaches the phone through `refineStillFrames`.
            if ContinuousClock.now - lastSubmitAt < .seconds(1) / streamFPS * 0.8 { continue }
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
        lastSubmitAt = .now
        encoder.encode(pixelBuffer, presentationTime: presentationTime)
    }

    private func pumpEncoded(from encoder: HEVCEncoder, generation: UInt32) async {
        for await frame in encoder.frames {
            guard !Task.isCancelled else { return }
            if frame.isDropped {
                framesInFlight = max(0, framesInFlight - 1)
                continue
            }
            var flags: VideoFrameHeader.Flags = []
            if frame.isKeyframe { flags.formUnion([.keyframe, .parameterSets]) }
            let header = VideoFrameHeader(frameID: nextFrameID, captureTimeMicros: frame.presentationTimeMicros,
                                          flags: flags, payloadLength: UInt32(frame.payload.count),
                                          sourceGeneration: generation)
            nextFrameID &+= 1
            let started = ContinuousClock.now
            do {
                try await session.send(frame: header, payload: frame.payload)
            } catch {
                return
            }
            sendTime += .now - started
            sends += 1
            framesInFlight = max(0, framesInFlight - 1)
            lastFrameAccepted = .now
            stats.framesSent += 1
            stats.bytesSent += frame.payload.count
        }
    }

    // MARK: Clipboard

    /// Sends what's copied on the Mac while the session is live (and sharing is on).
    private func watchClipboard() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: configuration.clipboardInterval)
            guard !Task.isCancelled, clipboardEnabled else { continue }
            let count = await clipboard.changeCount()
            guard count != clipboardSeen else { continue }
            clipboardSeen = count
            guard let item = await clipboard.read(), !item.isEmpty else { continue }
            guard item.fitsLimits else {
                Self.log.info("Clipboard item too large to send")
                continue
            }
            try? await session.send(.clipboard(item))
        }
    }

    // MARK: Fitting the stream to the link

    private var streamFPS: Int { min(configuration.fps, rate.step.fps) }

    private var streamBitrateKbps: Int {
        max(Self.minBitrateKbps, Int(Double(fullBitrateKbps) * rate.step.bitrate))
    }

    /// Measures the link every `adaptInterval` and refits the stream when `RateController`
    /// moves. Round trips ride the control stream, so they include any queue there.
    private func adaptToLink() async {
        var last = stats
        while !Task.isCancelled {
            if pendingPing == nil {
                let value = UInt64((ContinuousClock.now - clockEpoch) / .nanoseconds(1))
                pendingPing = (value, .now)
                try? await session.send(.ping(value))
            }
            try? await Task.sleep(for: configuration.adaptInterval)
            guard !Task.isCancelled else { return }

            // A pong that hasn't come back is at least as slow as the wait so far.
            if let pendingPing, ContinuousClock.now - pendingPing.sentAt > configuration.adaptInterval {
                roundTrip = max(roundTrip ?? .zero, ContinuousClock.now - pendingPing.sentAt)
            }
            let sample = RateController.Sample(
                framesSent: stats.framesSent - last.framesSent, framesDropped: stats.framesDropped - last.framesDropped,
                averageSendTime: sends > 0 ? sendTime / sends : nil, roundTrip: roundTrip)
            last = stats
            // For tuning on real devices: `log stream --level debug --predicate 'subsystem == "com.pocketdesk.host"'`.
            Self.log.debug("""
                link: \(sample.framesSent) sent, \(sample.framesDropped) dropped,                 send \(sample.averageSendTime.map { $0 / .milliseconds(1) } ?? -1, format: .fixed(precision: 1)) ms,                 rtt \(sample.roundTrip.map { $0 / .milliseconds(1) } ?? -1, format: .fixed(precision: 1)) ms,                 target \(self.streamBitrateKbps) kbps @ \(self.streamFPS) fps
                """)
            sendTime = .zero
            sends = 0
            roundTrip = nil
            if settling {
                settling = false
                continue
            }

            let previous = rate.step
            guard rate.update(sample) else { continue }
            if rate.step.scale != previous.scale {
                do {
                    try await startStreaming(nil, keepingSource: true)
                } catch {
                    Self.log.error("Resize for the link failed (\(String(describing: self.currentSource), privacy: .public)): \(String(describing: error), privacy: .public)")
                    // Resolving the source failed before the old stream was touched: keep it,
                    // just slower. Otherwise there's nothing left to stream.
                    guard encoder != nil, !pumpTasks.isEmpty else {
                        // Not `finish`: the message loop is reading the control stream, and it
                        // can only have one reader.
                        await end(reason: Self.describeStreamingFailure(error))
                        return
                    }
                    encoder?.setRate(bitrateKbps: streamBitrateKbps, fps: streamFPS)
                }
            } else {
                encoder?.setRate(bitrateKbps: streamBitrateKbps, fps: streamFPS)
            }
            let roundTripMillis = smoothedRoundTrip.map { Int($0 / .milliseconds(1)) }
            try? await session.send(.linkQuality(LinkQuality(isWeak: rate.isWeak, bitrateKbps: streamBitrateKbps,
                                                             fps: streamFPS, roundTripMillis: roundTripMillis)))
        }
    }

    private func stopPump() async {
        let tasks = pumpTasks
        pumpTasks = []
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        encoder = nil
    }

    /// Ends everything this session started and waits for it, before the connection closes.
    private func stopStreaming() async {
        if let adaptTask {
            adaptTask.cancel()
            await adaptTask.value
            self.adaptTask = nil
        }
        statusTask?.cancel()
        statusTask = nil
        if let clipboardTask {
            clipboardTask.cancel()
            await clipboardTask.value
            self.clipboardTask = nil
        }
        if let inputTask {
            inputTask.cancel()
            await inputTask.value
            self.inputTask = nil
        }
        // A phone that vanished mid-shortcut mustn't leave ⌘ held down on the Mac.
        input.releaseKeys()
        await stopPump()
        await frameSource.stop()
    }
}
#endif
