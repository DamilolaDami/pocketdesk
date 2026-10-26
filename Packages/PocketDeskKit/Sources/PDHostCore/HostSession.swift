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
        /// The desktop picture for `helloAck`, so the phone can draw this Mac.
        public var wallpaper: String?
        /// How often the Mac's clipboard is checked for something new to send.
        public var clipboardInterval: Duration
        /// How often volume and now playing are checked for a phone watching them.
        public var statusInterval: Duration
        /// How often the frontmost app is checked while the phone shows its menus.
        public var menusInterval: Duration
        /// How long after a keystroke the caret is read: the app needs a moment to move it.
        public var caretDelay: Duration = .milliseconds(60)
        /// Where received files go, and which folders the phone may browse.
        var files: HostFileTransfers.Folders = .standard

        public init(hostName: String, fps: Int = 60, maxFramesInFlight: Int = 2, refineFrames: Int = 8,
                    adaptInterval: Duration = .milliseconds(500), wake: WakeInfo? = nil,
                    clipboardInterval: Duration = .milliseconds(500), statusInterval: Duration = .seconds(1),
                    menusInterval: Duration = .milliseconds(500), wallpaper: String? = nil) {
            self.wallpaper = wallpaper
            self.clipboardInterval = clipboardInterval
            self.menusInterval = menusInterval
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
        /// The phone sent a file; it's in Downloads at `url`.
        case fileReceived(peer: Fingerprint, deviceName: String, url: URL)
        /// How to push to the phone's Now Playing Live Activity, or that it no longer wants it.
        case nowPlayingPush(peer: Fingerprint, NowPlayingPush)
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
    private let menus: any MenuBarSource
    private let caret: any CaretSource
    private let onEvent: @Sendable (Event) -> Void
    private let keepAwake: KeepAwake?
    private let keepAwakeID = UUID()

    /// When the phone last sent anything. A suspended app's connection can linger for a while
    /// without a word: Now Playing pushes treat a phone this quiet as gone.
    private var lastHeard = ContinuousClock.now
    private var isStreaming = false
    private var watchesStatus = false

    /// The phone is on screen with PocketDesk: streaming, or watching status and still pinging.
    public func phoneIsPresent(within quiet: Duration = .seconds(6)) -> Bool {
        isStreaming || (watchesStatus && ContinuousClock.now - lastHeard < quiet)
    }

    private var audioEnabled = true
    private var quality = StreamQuality.best
    private var clipboardEnabled = false
    private var clipboardTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var menusTask: Task<Void, Never>?
    private var caretTask: Task<Void, Never>?
    private var lastCaret: Caret?
    /// The streamed picture in global display points, to place the caret on it.
    private var sourceFrame: CGRect?
    private var files: HostFileTransfers?
    private var filesTask: Task<Void, Never>?
    /// Whether the person at the Mac allowed this connection-with-no-picture to do things.
    private var catalogAllowed: Bool?
    /// Set after a menu item is pressed: its menus may have changed even if the app didn't.
    private var menusStale = false
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
    /// How long a ping can go unanswered before the phone counts as gone.
    static let lostAfter: Duration = .seconds(15)
    static let log = Logger(subsystem: "com.pocketdesk.host", category: "session")

    public init(session: any PeerSession, peer: Fingerprint, configuration: Configuration,
                frameSource: any FrameSource, input: any InputSink, pairing: any PairingAuthority,
                catalog: any AppCatalogSource = InstalledApps(), clipboard: any ClipboardSink = MacPasteboard(),
                menus: any MenuBarSource = AccessibilityMenus(), caret: any CaretSource = AccessibilityCaret(),
                keepAwake: KeepAwake? = nil,
                onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.keepAwake = keepAwake
        self.catalog = catalog
        self.menus = menus
        self.caret = caret
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
        quality = hello.quality
        if let push = hello.nowPlayingPush { onEvent(.nowPlayingPush(peer: peer, push)) }
        let files = HostFileTransfers(session: session, peer: peer, folders: configuration.files) { [onEvent, peer] url in
            onEvent(.fileReceived(peer: peer, deviceName: hello.deviceName, url: url))
        }
        self.files = files
        filesTask = Task { [session] in
            do { for try await chunk in session.fileChunks { await files.handle(chunk) } } catch {}
        }
        viewport = hello.viewport
        if hello.mode == .catalog {
            // A quick question from the shortcut editor, or a shortcut run from Siri or a widget:
            // no picture, no input, no "connected".
            try await session.send(.helloAck(HelloAck(hostName: configuration.hostName, displays: [],
                                                      wake: configuration.wake, wallpaper: configuration.wallpaper)))
            defer { statusTask?.cancel() }
            while let message = try await messages.next() {
                lastHeard = .now
                func allow() async throws -> Bool { try await allowCatalogAction(deviceName: hello.deviceName) }
                switch message {
                case .listApps, .requestAppIcons, .listMacShortcuts: try await answer(message)
                case .watchStatus:
                    watchesStatus = true
                    startWatchingStatus()
                // The Mac cards show the round trip.
                case .ping(let value): try await session.send(.pong(value))
                case .run(let action):
                    guard try await allow() else { continue }
                    if try await run(action) { try await session.send(.actionDone) }
                // Paste to Mac and Copy from Mac on the phone's Mac cards.
                case .clipboard(let item):
                    guard try await allow() else { continue }
                    guard item.fitsLimits, !item.isEmpty else {
                        try await session.send(.actionFailed("That's too large for the Mac's clipboard."))
                        continue
                    }
                    _ = await clipboard.write(item)
                    try await session.send(.actionDone)
                case .getClipboard:
                    guard try await allow() else { continue }
                    try await sendClipboard()
                case _ where HostFileTransfers.handles(message):
                    // Files are using the Mac too.
                    if catalogAllowed == nil { catalogAllowed = await pairing.allowSession(peer: peer, deviceName: hello.deviceName) }
                    guard catalogAllowed == true else {
                        if case .listFiles(let path) = message {
                            try await session.send(.fileList(FileList(path: path, entries: [], problem: "The Mac didn't allow this.")))
                        } else if case .sendFile(let offer) = message {
                            try await session.send(.fileFailed(id: offer.id, reason: "The Mac didn't allow this."))
                        } else if case .getFile(let request) = message {
                            try await session.send(.fileFailed(id: request.id, reason: "The Mac didn't allow this."))
                        } else if case .mutateFile(let request) = message {
                            try await session.send(.fileMutationResult(.init(id: request.id, problem: .notAllowed,
                                                                            message: "The Mac didn't allow this file change.")))
                        }
                        continue
                    }
                    await files.handle(message)
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
        isStreaming = true
        await keepAwake?.send(.streaming(keepAwakeID, true))
        onEvent(.connected(peer: peer, deviceName: hello.deviceName))
        do {
            // Listing displays already needs Screen Recording, so it's inside the goodbye path.
            let displays = try await frameSource.displays()
            try await session.send(.helloAck(HelloAck(hostName: configuration.hostName, displays: displays,
                                                      wake: configuration.wake, wallpaper: configuration.wallpaper)))
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
            lastHeard = .now
            switch message {
            case .setAudioEnabled(let enabled):
                if enabled != audioEnabled {
                    audioEnabled = enabled
                    try await startStreaming(currentSource)
                }
            case .setQuality(let newQuality):
                if newQuality != quality {
                    quality = newQuality
                    try await startStreaming(currentSource, keepingSource: true)
                }
            case .requestKeyframe:
                encoder?.requestKeyframe()
            case .clipboard(let item):
                guard clipboardEnabled, item.fitsLimits, !item.isEmpty else { continue }
                clipboardSeen = await clipboard.write(item)
            case .getClipboard:
                try await sendClipboard()
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
                followCaret()
            case .key(let press):
                input.inject(.key(code: press.code, isDown: press.isDown, modifiers: press.modifiers))
                if press.isDown { followCaret() }
            case .run(let action):
                _ = try await run(action)
            case .listApps, .requestAppIcons, .listMacShortcuts:
                try await answer(message)
            case .watchStatus:
                startWatchingStatus()
            case .watchMenus(let watch):
                menusTask?.cancel()
                menusTask = watch ? Task { await self.watchMenus() } : nil
            case .sendFile, .getFile, .fileProgress, .fileFailed, .listFiles, .mutateFile:
                await files.handle(message)
            case .pressMenuItem(let press):
                do {
                    try await menus.press(press)
                } catch {
                    try await session.send(.actionFailed(String(describing: error)))
                }
                menusStale = true
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
                 .actionFailed, .actionDone, .apps, .appIcon, .macShortcuts, .macStatus, .menuBar, .caret,
                 .fileAccepted, .fileOffer, .fileData, .fileSaved, .fileList, .fileMutationResult:
                continue
            }
        }
    }

    /// Doing something on the Mac from a connection with no picture (not just looking):
    /// "Ask Before Each Connection" applies, once per connection.
    private func allowCatalogAction(deviceName: String) async throws -> Bool {
        if catalogAllowed == nil { catalogAllowed = await pairing.allowSession(peer: peer, deviceName: deviceName) }
        if catalogAllowed != true { try await session.send(.actionFailed("The Mac didn't allow this.")) }
        return catalogAllowed == true
    }

    /// What's copied on the Mac, asked for by the phone.
    private func sendClipboard() async throws {
        guard let item = await clipboard.read(), !item.isEmpty else {
            try await session.send(.actionFailed("Nothing is copied on the Mac."))
            return
        }
        guard item.fitsLimits else {
            try await session.send(.actionFailed("What's copied on the Mac is too large to send."))
            return
        }
        try await session.send(.clipboard(item))
    }

    /// Live tiles: the status now, then again whenever it changes.
    private func startWatchingStatus() {
        guard statusTask == nil else { return }
        statusTask = Task { await self.watchStatus() }
    }

    private func watchStatus() async {
        var last: MacStatus?
        while !Task.isCancelled {
            var status = await catalog.status()
            status.nowPlaying = status.nowPlaying?.coalescingTimeline(with: last?.nowPlaying)
            if status != last {
                guard (try? await session.send(.macStatus(status))) != nil else { return }
                last = status
            }
            try? await Task.sleep(for: configuration.statusInterval)
        }
    }

    /// Reads the caret once typing settles and tells the phone if it moved. Each keystroke
    /// starts over, so a burst of typing costs one read.
    private func followCaret() {
        caretTask?.cancel()
        caretTask = Task {
            try? await Task.sleep(for: configuration.caretDelay)
            guard !Task.isCancelled, let source = sourceFrame,
                  let frame = await caret.caretFrame(), let found = Caret(frame: frame, in: source),
                  !Task.isCancelled, found != lastCaret else { return }
            lastCaret = found
            try? await session.send(.caret(found))
        }
    }

    /// The frontmost app's menus now, then again when another app comes forward or an item
    /// was pressed (checkmarks and enabled items change).
    private func watchMenus() async {
        var shownApp: pid_t?
        var first = true
        while !Task.isCancelled {
            let app = await menus.frontmostApp()
            if first || app != shownApp || menusStale {
                first = false
                menusStale = false
                shownApp = app
                let bar = await menus.menuBar()
                guard !Task.isCancelled, (try? await session.send(.menuBar(bar))) != nil else { return }
            }
            try? await Task.sleep(for: configuration.menusInterval)
        }
    }

    /// A phone shortcut; one that can't be done says why.
    /// Does `action`; one that can't be done says why. `true` when it was done.
    private func run(_ action: MacAction) async throws -> Bool {
        guard action.isValid else {
            try await session.send(.actionFailed("That shortcut has too many steps or too long a wait."))
            return false
        }
        do {
            try await input.perform(action)
            return true
        } catch {
            try await session.send(.actionFailed(String(describing: error)))
            return false
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
        let full = StreamSizing.fit(sourceWidth: resolved.pixelWidth, sourceHeight: resolved.pixelHeight, into: viewport,
                                    zoomHeadroom: ceiling.zoomHeadroom)
        let size = StreamSizing.scale(full, by: rate.step.scale)
        let displayID: UInt32?
        if case .display(let id) = resolved.source { displayID = id } else { displayID = nil }
        fullBitrateKbps = Int(Double(StreamSizing.bitrateKbps(width: full.width, height: full.height,
                                                              fps: min(configuration.fps, ceiling.fps))) * ceiling.bitrate)
        let config = StreamConfig(codec: .hevc, width: size.width, height: size.height, fps: streamFPS,
                                  bitrateKbps: streamBitrateKbps, displayID: displayID)
        let encoder = try await HEVCEncoder.make(width: config.width, height: config.height, fps: config.fps,
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
        sourceFrame = resolved.screenFrame
        lastCaret = nil

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

    private var ceiling: QualityCeiling { QualityCeiling(quality) }
    private var streamFPS: Int { min(configuration.fps, rate.step.fps, ceiling.fps) }

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
            // The phone stopped answering. Over a relay the inner connection doesn't notice a
            // vanished peer for a long time, and a session left running holds a relay slot.
            if let pendingPing, ContinuousClock.now - pendingPing.sentAt > Self.lostAfter {
                await end(reason: "Lost the connection to the iPhone.")
                return
            }

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
        await keepAwake?.send(.streaming(keepAwakeID, false))
        isStreaming = false
        if let adaptTask {
            adaptTask.cancel()
            await adaptTask.value
            self.adaptTask = nil
        }
        statusTask?.cancel()
        statusTask = nil
        menusTask?.cancel()
        menusTask = nil
        caretTask?.cancel()
        caretTask = nil
        filesTask?.cancel()
        filesTask = nil
        await files?.stop()
        files = nil
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
