import AVFoundation
import Foundation
import Synchronization
import Network
import os
import PDProtocol
import PDSecurity
import PDTransport
import Synchronization

/// What a connection reports to `SessionController`.
public enum ClientEvent: Sendable, Equatable {
    case path(ConnectionPath)
    /// Pairing: show this code; the person at the Mac must accept the same one.
    case awaitingApproval(code: String)
    case paired(PairedPeer)
    case displays([DisplayInfo])
    case virtualDisplay(VirtualDisplayReport)
    /// How to wake this Mac later (from its `helloAck`).
    case wake(WakeInfo)
    /// Its desktop picture, JPEG (from its `helloAck`).
    case wallpaper(Data)
    /// Something copied on the Mac.
    case clipboard(ClipboardItem)
    case streamConfig(StreamConfig)
    case linkQuality(LinkQuality)
    case windows([WindowInfo])
    /// Volume and now playing, for live tiles (after `watchStatus`).
    case macStatus(MacStatus)
    /// The frontmost Mac app's menus (after `watchMenus`); `nil` when they can't be read.
    case menuBar(MenuBar?)
    /// Where the Mac's text caret moved to while typing.
    case caret(Caret)
    /// File transfers over this stream (`nil` once it ends).
    case files(MacFiles?)
    /// Something to tell the person without ending the session (a shortcut that failed).
    case notice(String)
    case ended(reason: String?)
}

public enum ClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case pairingDeclined
    case hostEnded(String)
    case unexpectedMessage

    public var description: String {
        switch self {
        case .pairingDeclined: "Pairing was declined on the Mac."
        case .hostEnded(let reason): reason
        case .unexpectedMessage: "The Mac sent something unexpected."
        }
    }
}

/// One connection to a Mac: optional pairing, hello, then video (straight to the display),
/// control messages and input until either side ends it.
public actor ClientConnection {
    public struct Request: Sendable {
        public var endpoint: NWEndpoint?
        public var relay: RelayServer?
        public var findLocal: (@Sendable () async -> NWEndpoint?)?
        public var hostFingerprint: Fingerprint
        /// Set when pairing; the token and host fingerprint come from the scanned invite.
        public var invite: PairingInvite?
        public var deviceName: String
        public var viewport: Viewport
        public var preferredDisplayID: String?
        public var audioEnabled: Bool
        public var clipboardEnabled: Bool
        public var quality: StreamQuality
        public var nowPlayingPush: NowPlayingPush?

        public init(endpoint: NWEndpoint?, hostFingerprint: Fingerprint, invite: PairingInvite?,
                    deviceName: String, viewport: Viewport, audioEnabled: Bool = true, preferredDisplayID: String? = nil,
                    clipboardEnabled: Bool = true, quality: StreamQuality = .best, relay: RelayServer? = nil, findLocal: (@Sendable () async -> NWEndpoint?)? = nil, nowPlayingPush: NowPlayingPush? = nil) {
            self.nowPlayingPush = nowPlayingPush
            self.findLocal = findLocal
            self.relay = invite == nil ? relay : nil
            self.quality = quality
            self.clipboardEnabled = clipboardEnabled
            self.endpoint = endpoint
            self.hostFingerprint = hostFingerprint
            self.invite = invite
            self.deviceName = deviceName
            self.viewport = viewport
            self.preferredDisplayID = preferredDisplayID
            self.audioEnabled = audioEnabled
        }
    }

    static let log = Logger(subsystem: "com.pocketdesk", category: "connection")

    private let identity: DeviceIdentity
    private let request: Request
    private let display: VideoDisplay
    private let onEvent: @Sendable (ClientEvent) -> Void

    /// UI → Mac, in order. Streams (not ad-hoc Tasks) so a button-down never overtakes its
    /// button-up.
    private nonisolated let sourceEpoch = SourceEpochBox()
#if DEBUG && os(iOS)
    private nonisolated let traceCounters = Mutex(TraceCounters())
    private struct TraceCounters: Sendable {
        var frames = 0
        var bytes = 0
        var lastSample = ProcessInfo.processInfo.systemUptime
        var roundTripMillis: Double = 0
    }
    nonisolated func sampleTraceStatistics() -> StreamStats {
        traceCounters.withLock { value in
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = max(0.001, now - value.lastSample)
            var sample = StreamStats()
            sample.framesPerSecond = Double(value.frames) / elapsed
            sample.bitrateKbps = Double(value.bytes) * 8 / elapsed / 1000
            sample.roundTripMillis = value.roundTripMillis
            value.frames = 0; value.bytes = 0; value.lastSample = now
            return sample
        }
    }
#endif
    private let inputs = AsyncStream<InputEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
    private let outbox = AsyncStream<ControlMessage>.makeStream()

    public init(identity: DeviceIdentity, request: Request, display: VideoDisplay,
                onEvent: @escaping @Sendable (ClientEvent) -> Void) {
        self.identity = identity
        self.request = request
        self.display = display
        self.onEvent = onEvent
    }

    public nonisolated func send(_ input: InputEvent) {
        guard let generation = sourceEpoch.state.withLock({ $0.ready ? $0.generation : nil }) else { return }
        inputs.continuation.yield(.scoped(generation: generation, event: input))
    }

    public nonisolated func send(_ message: ControlMessage) {
        switch message {
        case .key(let press):
            guard let generation = sourceEpoch.state.withLock({ $0.ready ? $0.generation : nil }) else { return }
            outbox.continuation.yield(.sourceKey(generation: generation, press: press))
        case .insertText(let text):
            guard let generation = sourceEpoch.state.withLock({ $0.ready ? $0.generation : nil }) else { return }
            outbox.continuation.yield(.sourceText(generation: generation, text: text))
        default: outbox.continuation.yield(message)
        }
    }

    /// Runs until the connection ends; always finishes with `.ended`.
    public func run() async {
        let playbackID = display.beginSession(audioEnabled: request.audioEnabled)
        display.setKeyframeRequester(sessionID: playbackID) { [weak self] in self?.send(.requestKeyframe) }
        defer { display.endSession(playbackID) }
        do {
            var local = request.endpoint
            if local == nil, let find = request.findLocal { local = await find() }
            try Task.checkCancellation()
            try await PathFinder.connect(local: local, relay: request.relay, identity: identity, host: request.hostFingerprint, keepAliveWhileIdle: request.invite != nil, onPath: { [onEvent] in onEvent(.path($0)) }) { session in
                try await self.drive(session, playbackID: playbackID)
            }
            Self.log.info("Session ended normally")
            onEvent(.ended(reason: nil))
        } catch is CancellationError {
            Self.log.info("Session cancelled")
            onEvent(.ended(reason: nil))
        } catch {
            Self.log.error("Session ended: \(String(describing: error), privacy: .public)")
            onEvent(.ended(reason: Self.describe(error)))
        }
        inputs.continuation.finish()
        outbox.continuation.finish()
    }

    private func drive(_ session: QUICPeerSession, playbackID: UUID) async throws {
        guard display.isCurrentSession(playbackID) else { throw CancellationError() }
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .moviePlayback)
        try audioSession.setActive(true)
        defer {
            if display.isCurrentSession(playbackID) {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
        #endif
        if let invite = request.invite {
            try await pair(session, invite: invite)
        }
        try await session.send(.hello(Hello(deviceName: request.deviceName, viewport: request.viewport, audioEnabled: request.audioEnabled, preferredDisplayID: request.preferredDisplayID,
                                             clipboardEnabled: request.clipboardEnabled, quality: request.quality,
                                             nowPlayingPush: request.nowPlayingPush)))

        let display = display
        let inputs = inputs.stream
        let outbox = outbox.stream
        let onEvent = onEvent
        // The host says why before it hangs up, but its close also fails the video channel;
        // keep the stated reason so it wins over "connection reset".
        let hostReason = HostReason()
        do {
            try await stream(session, display: display, inputs: inputs, outbox: outbox, onEvent: onEvent, hostReason: hostReason, playbackID: playbackID)
        } catch {
            if let reason = hostReason.value { throw ClientError.hostEnded(reason) }
            throw error
        }
    }

    private nonisolated func stream(_ session: QUICPeerSession, display: VideoDisplay,
                                    inputs: AsyncStream<InputEvent>, outbox: AsyncStream<ControlMessage>,
                                    onEvent: @escaping @Sendable (ClientEvent) -> Void,
                                    hostReason: HostReason, playbackID: UUID) async throws {
        let sourceEpoch = sourceEpoch
        let files = MacFiles(send: { try await session.send($0) }, sendChunk: { try await session.send(chunk: $0) })
        onEvent(.files(files))
        defer {
            onEvent(.files(nil))
            Task { await files.end() }
        }
        // Whichever channel ends first ends the session.
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for try await message in session.controlMessages {
                    switch message {
                    case .fileAccepted, .fileOffer, .fileProgress, .fileSaved, .fileFailed, .fileList, .fileMutationResult:
                        await files.receive(message)
                    case .helloAck(let ack):
                        onEvent(.displays(ack.displays))
                        if let wake = ack.wake { onEvent(.wake(wake)) }
                        if let wallpaper = ack.wallpaper.flatMap({ Data(base64Encoded: $0) }) { onEvent(.wallpaper(wallpaper)) }
                    case .displays(let displays): onEvent(.displays(displays))
                    case .virtualDisplay(let report): onEvent(.virtualDisplay(report))
                    case .streamConfig(let config):
                        guard sourceEpoch.state.withLock({ $0.configure(config.sourceGeneration) }) else { continue }
                        display.expectGeneration(config.sourceGeneration, sessionID: playbackID)
                        onEvent(.streamConfig(config))
                        try await session.send(.requestKeyframe)
                    case .linkQuality(let quality):
#if DEBUG && os(iOS)
                        self.traceCounters.withLock { $0.roundTripMillis = Double(quality.roundTripMillis ?? 0) }
#endif
                        onEvent(.linkQuality(quality))
                    case .clipboard(let item): onEvent(.clipboard(item))
                    case .macStatus(let status): onEvent(.macStatus(status))
                    case .windows(let windows): onEvent(.windows(windows))
                    case .menuBar(let bar): onEvent(.menuBar(bar))
                    case .caret(let caret): onEvent(.caret(caret))
                    case .actionFailed(let reason): onEvent(.notice(reason))
                    case .actionDone: continue
                    case .bye(let reason):
                        hostReason.value = reason
                        throw ClientError.hostEnded(reason)
                    case .ping(let value): try await session.send(.pong(value))
                    case .hostUpdate, .hostUpdateStatus, .setViewport, .configureVirtualDisplay, .sourceReady, .sourceKey, .sourceText, .watchVirtualDisplay, .createVirtualDisplay, .endVirtualDisplay, .listDisplays, .selectDisplay, .setAudioEnabled, .setClipboardEnabled, .getClipboard, .pong, .hello, .pairRequest, .pairResult, .listWindows, .selectSource,
                         .requestKeyframe, .insertText, .key, .run, .listApps, .apps, .requestAppIcons, .appIcon,
                         .listMacShortcuts, .macShortcuts, .watchStatus, .watchMenus, .pressMenuItem, .setQuality,
                         .sendFile, .getFile, .fileData, .listFiles, .mutateFile:
                        continue
                    }
                }
                return "control"
            }
            group.addTask {
                for try await chunk in session.fileChunks { await files.receive(chunk) }
                return "files"
            }
            group.addTask {
                for try await (header, payload) in session.videoFrames {
#if DEBUG && os(iOS)
                    if sourceEpoch.state.withLock({ $0.generation == header.sourceGeneration }) {
                        self.traceCounters.withLock { $0.frames += 1; $0.bytes += payload.count }
                    }
#endif
                    if display.enqueue(header: header, payload: payload, sessionID: playbackID) {
                        try await session.send(.requestKeyframe)
                    }
                    if header.flags.contains(.keyframe), display.hasDecodedGeneration(header.sourceGeneration),
                       sourceEpoch.state.withLock({ $0.decodedKeyframe(header.sourceGeneration) }) {
                        try await session.send(.sourceReady(header.sourceGeneration))
                    }
                }
                return "video"
            }
            group.addTask {
                for try await (header, payload) in session.audioFrames {
                    try display.enqueueAudio(header: header, payload: payload, sessionID: playbackID)
                }
                return "audio"
            }
            group.addTask {
                for await event in inputs { try await session.send(event) }
                return "input"
            }
            group.addTask {
                for await message in outbox { try await session.send(message) }
                return "outbox"
            }
            defer { group.cancelAll() }
            do {
                if let channel = try await group.next() {
                    Self.log.info("The \(channel, privacy: .public) channel ended")
                }
            } catch {
                Self.log.error("A channel failed: \(String(describing: error), privacy: .public)")
                throw error
            }
        }
    }

    /// Presents the invite token; the code shown here must match the one on the Mac.
    private func pair(_ session: QUICPeerSession, invite: PairingInvite) async throws {
        onEvent(.awaitingApproval(code: Pairing.verificationCode(
            host: invite.hostFingerprint, client: identity.fingerprint, token: invite.token)))
        try await session.send(.pairRequest(PairRequest(token: [UInt8](invite.token), deviceName: request.deviceName)))
        var control = session.controlMessages.makeAsyncIterator()
        switch try await control.next() {
        case .pairResult(accepted: true):
            onEvent(.paired(PairedPeer(fingerprint: invite.hostFingerprint, name: invite.hostName, hostID: invite.hostID)))
        case .pairResult(accepted: false):
            throw ClientError.pairingDeclined
        case .bye(let reason):
            throw ClientError.hostEnded(reason)
        default:
            throw ClientError.unexpectedMessage
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as ClientError: error.description
        case TransportError.timedOut: "Couldn't reach the Mac. Is PocketDesk running on it?"
        // The Mac's TLS gate turned this phone away: it isn't (or is no longer) paired.
        case TransportError.connectionFailed(.posix(.EINVAL)), TransportError.connectionFailed(.tls):
            "This Mac didn't recognize this iPhone. Pair again: on the Mac, choose Pair a Phone… from the PocketDesk menu."
        case TransportError.connectionFailed(let error): "Connection failed: \(error.localizedDescription)"
        case TransportError.closed: "The Mac closed the connection."
        default: error.localizedDescription
        }
    }
}

/// What a catalog connection reports, as it arrives.
public enum CatalogUpdate: Sendable, Equatable {
    case apps([MacApp])
    /// `png == nil`: the Mac has no icon for it (or no such app).
    case icon(bundleID: String, png: Data?)
    case macShortcuts([MacShortcut])
}

extension ClientConnection {
    /// A short connection with no video: lists the Mac's apps, then fetches icons for the
    /// bundle IDs `iconsWanted` picks from that list. Doesn't need Screen Recording on the Mac.
    public static func catalog(endpoint: NWEndpoint?, hostFingerprint: Fingerprint, identity: DeviceIdentity,
                               deviceName: String, relay: RelayServer? = nil,
                               iconsWanted: @escaping @Sendable ([MacApp]) -> [String]) -> AsyncThrowingStream<CatalogUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await PathFinder.connect(local: endpoint, relay: relay, identity: identity, host: hostFingerprint, onPath: { _ in }) { session in
                        var control = session.controlMessages.makeAsyncIterator()
                        /// The next message that isn't housekeeping; a `bye` ends the fetch with its reason.
                        func next() async throws -> ControlMessage {
                            while let message = try await control.next() {
                                switch message {
                                case .bye(let reason): throw ClientError.hostEnded(reason)
                                case .ping(let value): try await session.send(.pong(value))
                                default: return message
                                }
                            }
                            throw TransportError.closed
                        }

                        try await session.send(.hello(Hello(deviceName: deviceName, viewport: Viewport(width: 0, height: 0, scale: 1),
                                                            mode: .catalog)))
                        guard case .helloAck = try await next() else { throw ClientError.unexpectedMessage }
                        try await session.send(.listApps)
                        guard case .apps(let apps) = try await next() else { throw ClientError.unexpectedMessage }
                        continuation.yield(.apps(apps))

                        let wanted = iconsWanted(apps)
                        if !wanted.isEmpty {
                            try await session.send(.requestAppIcons(wanted))
                            for _ in wanted {
                                guard case .appIcon(let icon) = try await next() else { throw ClientError.unexpectedMessage }
                                continuation.yield(.icon(bundleID: icon.bundleID, png: icon.png.flatMap { Data(base64Encoded: $0) }))
                            }
                        }
                        try await session.send(.listMacShortcuts)
                        guard case .macShortcuts(let shortcuts) = try await next() else { throw ClientError.unexpectedMessage }
                        continuation.yield(.macShortcuts(shortcuts))
                        try await session.send(.bye(reason: "done"))
                        // Let the Mac hang up first; closing now could discard the bye unsent.
                        while (try? await control.next()) != nil {}
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ClientConnection {
    /// A connection with no video that just listens: the Mac's status now and on every
    /// change, for live tiles. Runs until cancelled or the Mac goes away.
    public enum StatusUpdate: Sendable, Equatable {
        case status(MacStatus)
        /// A round trip to the Mac and back.
        case latency(Duration)
        /// Its desktop picture, JPEG.
        case wallpaper(Data)
    }

    /// The Mac's status as it changes, and a round-trip time every `pingInterval` (a Mac too
    /// old to answer pings just never sends one).
    public static func watchStatus(endpoint: NWEndpoint?, hostFingerprint: Fingerprint, identity: DeviceIdentity,
                                   deviceName: String, pingInterval: Duration = .seconds(2), relay: RelayServer? = nil,
                                   nowPlayingPush: NowPlayingPush? = nil)
        -> AsyncThrowingStream<StatusUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await PathFinder.connect(local: endpoint, relay: relay, identity: identity, host: hostFingerprint, onPath: { _ in }) { session in
                        var control = session.controlMessages.makeAsyncIterator()
                        try await session.send(.hello(Hello(deviceName: deviceName, viewport: Viewport(width: 0, height: 0, scale: 1),
                                                            mode: .catalog, nowPlayingPush: nowPlayingPush)))
                        try await session.send(.watchStatus)
                        let clock = ContinuousClock()
                        let start = clock.now
                        let pinger = Task {
                            while !Task.isCancelled {
                                try? await session.send(.ping(UInt64((clock.now - start) / .microseconds(1))))
                                try? await Task.sleep(for: pingInterval)
                            }
                        }
                        defer { pinger.cancel() }
                        // Cancelling ends this wait and closes the connection, which stops the Mac's polling.
                        while let message = try await control.next() {
                            switch message {
                            case .macStatus(let status): continuation.yield(.status(status))
                            case .helloAck(let ack):
                                if let wallpaper = ack.wallpaper.flatMap({ Data(base64Encoded: $0) }) {
                                    continuation.yield(.wallpaper(wallpaper))
                                }
                            case .pong(let sent):
                                continuation.yield(.latency(clock.now - start - .microseconds(Int64(sent))))
                            case .ping(let value): try await session.send(.pong(value))
                            case .bye(let reason): throw ClientError.hostEnded(reason)
                            default: continue
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ClientConnection {
    /// Runs one action without streaming (Siri, the Shortcuts app, widgets). Throws with the
    /// Mac's reason if it couldn't.
    public static func perform(_ action: MacAction, endpoint: NWEndpoint?, hostFingerprint: Fingerprint,
                               identity: DeviceIdentity, deviceName: String, relay: RelayServer? = nil) async throws {
        try await PathFinder.connect(local: endpoint, relay: relay, identity: identity, host: hostFingerprint, onPath: { _ in }) { session in
            var control = session.controlMessages.makeAsyncIterator()
            try await session.send(.hello(Hello(deviceName: deviceName, viewport: Viewport(width: 0, height: 0, scale: 1),
                                                mode: .catalog)))
            switch try await control.next() {
            case .helloAck: break
            case .bye(let reason): throw ClientError.hostEnded(reason)
            default: throw ClientError.unexpectedMessage
            }
            try await session.send(.run(action))
            try await awaitDone(&control, on: session)
        }
    }
}

extension ClientConnection {
    /// Puts `item` on the Mac's clipboard without streaming. Throws with the Mac's reason if it
    /// couldn't.
    public static func paste(_ item: ClipboardItem, endpoint: NWEndpoint?, hostFingerprint: Fingerprint,
                             identity: DeviceIdentity, deviceName: String, relay: RelayServer? = nil) async throws {
        try await PathFinder.connect(local: endpoint, relay: relay, identity: identity, host: hostFingerprint, onPath: { _ in }) { session in
            var control = try await openQuietly(session, deviceName: deviceName)
            try await session.send(.clipboard(item))
            try await awaitDone(&control, on: session)
        }
    }

    /// What's copied on the Mac, without streaming.
    public static func copy(endpoint: NWEndpoint?, hostFingerprint: Fingerprint, identity: DeviceIdentity,
                            deviceName: String, relay: RelayServer? = nil) async throws -> ClipboardItem {
        let answer = Answer()
        try await PathFinder.connect(local: endpoint, relay: relay, identity: identity, host: hostFingerprint, onPath: { _ in }) { session in
            var control = try await openQuietly(session, deviceName: deviceName)
            try await session.send(.getClipboard)
            while let message = try await control.next() {
                switch message {
                case .clipboard(let item):
                    answer.item.withLock { $0 = item }
                    try? await session.send(.bye(reason: "done"))
                    return
                case .actionFailed(let reason), .bye(let reason): throw ClientError.hostEnded(reason)
                case .ping(let value): try await session.send(.pong(value))
                default: continue
                }
            }
        }
        guard let item = answer.item.withLock({ $0 }) else { throw ClientError.hostEnded("The Mac went away.") }
        return item
    }

    /// The Mac's clipboard, out of the connection's closure.
    private final class Answer: Sendable {
        let item = Mutex<ClipboardItem?>(nil)
    }

    /// Waits for the Mac to say the action is done (or why not), then says goodbye: the
    /// answer comes before anyone hangs up, so it can't be lost as the connection closes.
    private static func awaitDone(_ control: inout AsyncThrowingStream<ControlMessage, any Error>.Iterator,
                                  on session: some PeerSession) async throws {
        var failure: String? = "The Mac went away before it was done."
        answer: while let message = try await control.next() {
            switch message {
            case .actionDone:
                failure = nil
                break answer
            case .actionFailed(let reason), .bye(let reason):
                failure = reason
                break answer
            case .ping(let value): try await session.send(.pong(value))
            default: continue
            }
        }
        try? await session.send(.bye(reason: "done"))
        if let failure { throw ClientError.hostEnded(failure) }
    }

    /// Says hello for a connection with no picture; returns once the Mac has answered.
    private static func openQuietly(_ session: some PeerSession, deviceName: String) async throws
        -> AsyncThrowingStream<ControlMessage, any Error>.Iterator {
        var control = session.controlMessages.makeAsyncIterator()
        try await session.send(.hello(Hello(deviceName: deviceName, viewport: Viewport(width: 0, height: 0, scale: 1),
                                            mode: .catalog)))
        switch try await control.next() {
        case .helloAck: return control
        case .bye(let reason): throw ClientError.hostEnded(reason)
        default: throw ClientError.unexpectedMessage
        }
    }
}

/// A connection with no picture for browsing and transferring files; it stays open until
/// `close()` or the Mac goes away.
public final class FilesConnection: Sendable {
    public let files: MacFiles
    private let closing: AsyncStream<Void>.Continuation
    private let opening: OpeningFiles

    fileprivate init(files: MacFiles, closing: AsyncStream<Void>.Continuation, opening: OpeningFiles) {
        self.files = files
        self.closing = closing
        self.opening = opening
    }

    /// Says goodbye, and hangs up if the Mac doesn't within a few seconds.
    public func close() {
        closing.finish()
        let opening = opening
        Task {
            try? await Task.sleep(for: .seconds(3))
            opening.task.withLock { $0 }?.cancel()
        }
    }
}

extension ClientConnection {
    /// Opens a connection with no picture for files (`FilesConnection`). Returns once the Mac
    /// has said hello.
    public static func openFiles(endpoint: NWEndpoint?, hostFingerprint: Fingerprint, identity: DeviceIdentity,
                                 deviceName: String, relay: RelayServer? = nil) async throws -> FilesConnection {
        let (closed, closing) = AsyncStream<Void>.makeStream()
        let ready = OpeningFiles()
        return try await withCheckedThrowingContinuation { continuation in
            ready.continuation.withLock { $0 = continuation }
            let task = Task {
                do {
                    try await PathFinder.connect(local: endpoint, relay: relay, identity: identity, host: hostFingerprint, onPath: { _ in }) { session in
                        let files = MacFiles(send: { try await session.send($0) }, sendChunk: { try await session.send(chunk: $0) })
                        try await session.send(.hello(Hello(deviceName: deviceName, viewport: Viewport(width: 0, height: 0, scale: 1),
                                                            mode: .catalog)))
                        try await withThrowingTaskGroup(of: String.self) { group in
                            group.addTask {
                                for try await message in session.controlMessages {
                                    switch message {
                                    case .helloAck:
                                        ready.resume(.success(FilesConnection(files: files, closing: closing, opening: ready)))
                                    case .bye(let reason): throw ClientError.hostEnded(reason)
                                    case .ping(let value): try await session.send(.pong(value))
                                    case _ where MacFiles.handles(message): await files.receive(message)
                                    default: continue
                                    }
                                }
                                return "control"
                            }
                            group.addTask {
                                for try await chunk in session.fileChunks { await files.receive(chunk) }
                                return "files"
                            }
                            group.addTask {
                                for await _ in closed {}
                                try await session.send(.bye(reason: "done"))
                                return "bye"
                            }
                            defer { group.cancelAll() }
                            // The Mac hangs up after the bye (or on its own); then it's over.
                            while let channel = try await group.next(), channel != "control" {}
                        }
                        await files.end()
                    }
                    ready.resume(.failure(TransportError.closed))
                } catch {
                    ready.resume(.failure(error))
                }
            }
            ready.task.withLock { $0 = task }
        }
    }
}

/// `openFiles` resumes its caller once, when the Mac says hello or the connection fails.
private final class OpeningFiles: Sendable {
    let continuation = Mutex<CheckedContinuation<FilesConnection, any Error>?>(nil)
    /// The connection's task, for `FilesConnection.close` to cancel.
    let task = Mutex<Task<Void, Never>?>(nil)

    func resume(_ result: Result<FilesConnection, any Error>) {
        continuation.withLock { continuation in
            continuation?.resume(with: result)
            continuation = nil
        }
    }
}

/// The reason from the host's `bye`, shared between the session's channel tasks.
private final class HostReason: Sendable {
    private let storage = Mutex<String?>(nil)
    var value: String? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

/// Reference ownership lets concurrent channel tasks share the noncopyable mutex safely.
private final class SourceEpochBox: Sendable {
    let state = Mutex(SourceInputEpoch())
}
