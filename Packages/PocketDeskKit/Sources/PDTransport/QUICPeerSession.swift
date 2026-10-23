import Foundation
import Network
import os
import PDProtocol
import PDSecurity
import Synchronization

/// `PeerSession` over one QUIC connection (see `Channels.swift` for the channel layout).
///
/// - control: bidirectional stream opened by the client, `ControlMessage` as JSON via `Coder`
/// - input:   QUIC datagrams, `InputEvent` binary
/// - video:   unidirectional stream opened by the host, `VideoFrameHeader` + payload
/// - audio:   separate unidirectional stream, `AudioFrameHeader` + raw AAC-LC
/// - files:   host → client, a unidirectional stream of binary `FileChunk`s; client → host, a
///            second bidirectional stream of `ControlMessage.fileData` (the host reads every
///            stream the phone opens as JSON messages)
///
/// The connection's lifetime is structured: it lives while the listener's or
/// `QUICClient.connect`'s handler runs. `close()` stops this session's readers.
public final class QUICPeerSession: PeerSession {
    typealias ControlStream = QUIC.Stream<Coder<ControlMessage, ControlMessage, NetworkJSONCoder>>

    /// The peer's certificate fingerprint (already checked by the TLS validator).
    public let peer: Fingerprint
    public let controlMessages: AsyncThrowingStream<ControlMessage, any Error>
    public let inputEvents: AsyncThrowingStream<InputEvent, any Error>
    public let videoFrames: AsyncThrowingStream<(VideoFrameHeader, [UInt8]), any Error>

    public let audioFrames: AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error>
    public let fileChunks: AsyncThrowingStream<FileChunk, any Error>

    private let control: ControlStream
    private let datagrams: OnFirstUse<QUIC.Datagrams<QUICDatagram>>
    /// Host only, opened on first use (see `accept`).
    private let video: OnFirstUse<QUIC.Stream<QUICStream>>?
    private let audio: OnFirstUse<QUIC.Stream<QUICStream>>?
    /// Host: its files stream. Client: its second stream for file data.
    private let hostFiles: OnFirstUse<QUIC.Stream<QUICStream>>?
    private let clientFiles: OnFirstUse<ControlStream>?
    private let readers: Mutex<[Task<Void, Never>]>
    private let finishAll: @Sendable () -> Void

    private init(peer: Fingerprint, control: ControlStream, datagrams: OnFirstUse<QUIC.Datagrams<QUICDatagram>>,
                 video: OnFirstUse<QUIC.Stream<QUICStream>>?, audio: OnFirstUse<QUIC.Stream<QUICStream>>?,
                 hostFiles: OnFirstUse<QUIC.Stream<QUICStream>>?, clientFiles: OnFirstUse<ControlStream>?,
                 channels: Channels, readers: [Task<Void, Never>]) {
        self.peer = peer
        self.hostFiles = hostFiles
        self.clientFiles = clientFiles
        self.fileChunks = channels.files.stream
        self.control = control
        self.datagrams = datagrams
        self.audioFrames = channels.audio.stream
        self.video = video
        self.audio = audio
        self.controlMessages = channels.control.stream
        self.inputEvents = channels.input.stream
        self.videoFrames = channels.video.stream
        self.readers = Mutex(readers)
        self.finishAll = channels.finish
    }

    deinit {
        // On iOS, releasing a stream after the host has already torn the connection down
        // (it turned this phone away at the TLS gate, or the Mac quit) traps inside
        // Network.framework ("nw_connection_set_queue called after nw_connection_start").
        // The phone can't make the host wait, so its streams are kept instead: a few bytes
        // per session.
        if video == nil {
            Retired.keep(control)
            Retired.keep(datagrams)
            if let clientFiles { Retired.keep(clientFiles) }
        }
    }

    // MARK: Host side

    /// Wraps a connection from `QUICHostListener`. Returns once the client has opened its
    /// control stream (i.e. sent its first message).
    static func accept(_ connection: NetworkConnection<QUIC>) async throws -> QUICPeerSession {
        let channels = Channels()
        let firstStream = AsyncStream<ControlStream>.makeStream()

        // The phone's first stream is its control stream; a later one carries file data.
        let controlOpened = Mutex(false)
        let controlReader = Task {
            do {
                try await connection.inboundStreams(prepending: { stream in Coder(ControlMessage.self, using: .json) { stream } }) { stream in
                    let isControl = controlOpened.withLock { opened in
                        defer { opened = true }
                        return !opened
                    }
                    guard isControl else {
                        for try await message in stream.messages {
                            guard case .fileData(let text) = message.content, let data = Data(base64Encoded: text),
                                  let chunk = try? FileChunk(decoding: data) else { continue }
                            channels.files.continuation.yield(chunk)
                        }
                        return
                    }
                    firstStream.continuation.yield(stream)
                    firstStream.continuation.finish()
                    for try await message in stream.messages {
                        channels.control.continuation.yield(message.content)
                    }
                    channels.control.continuation.finish()
                }
            } catch {
                channels.control.continuation.finish(throwing: error)
            }
            channels.files.continuation.finish()
            firstStream.continuation.finish()
        }

        var iterator = firstStream.stream.makeAsyncIterator()
        guard let control = await iterator.next() else {
            await stop([controlReader])
            throw TransportError.closed
        }
        guard let peer = Fingerprint(peerOf: connection.securityProtocolMetadata) else {
            await stop([controlReader])
            throw TransportError.unauthenticatedPeer
        }

        let datagrams: QUIC.Datagrams<QUICDatagram>
        do { datagrams = try await connection.datagrams } catch {
            await stop([controlReader])
            throw error
        }
        let inputReader = Task {
            do {
                for try await datagram in datagrams.messages {
                    // Garbage datagrams are dropped, not fatal: they're unreliable by design.
                    if let event = try? InputEvent(decoding: datagram.content) {
                        channels.input.continuation.yield(event)
                    }
                }
                channels.input.continuation.finish()
            } catch {
                channels.input.continuation.finish(throwing: error)
            }
        }
        // Not opened yet: a phone that's turned away, or only asks for the app list, never
        // gets media streams. Streams arriving at a phone as the host hangs up trip a
        // Network.framework trap there.
        let open: @Sendable (UInt8) async throws -> QUIC.Stream<QUICStream> = { tag in
            let stream = try await connection.openStream(directionality: .unidirectional)
            try await stream.send([tag])
            return stream
        }

        return QUICPeerSession(peer: peer, control: control, datagrams: OnFirstUse { datagrams },
                               video: OnFirstUse { try await open(0) }, audio: OnFirstUse { try await open(1) },
                               hostFiles: OnFirstUse { try await open(2) }, clientFiles: nil,
                               channels: channels, readers: [controlReader, inputReader])
    }

    // MARK: Client side

    static func open(_ connection: NetworkConnection<QUIC>, host: Fingerprint) async throws -> QUICPeerSession {
        let channels = Channels()
        let control = try await connection.openStream { stream in Coder(ControlMessage.self, using: .json) { stream } }

        let controlReader = Task {
            do {
                for try await message in control.messages {
                    channels.control.continuation.yield(message.content)
                }
                channels.control.continuation.finish()
            } catch {
                channels.control.continuation.finish(throwing: error)
            }
        }
        let videoReader = Task {
            do {
                try await connection.inboundStreams { stream in
                    defer { Retired.keep(stream) } // see `deinit`
                    let tag = try await stream.receive(exactly: 1).content
                    guard let kind = tag.first, kind <= 2 else { throw WireError.unknownTag }
                    while true {
                        if kind == 2 {
                            let header = try await stream.receive(exactly: FileChunk.headerSize).content
                            // Length is bytes 16..<20, little-endian.
                            let length = header.dropFirst(16).prefix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
                            guard length <= FileChunk.size else { throw WireError.invalidValue }
                            let payload = length == 0 ? Data() : try await stream.receive(exactly: length).content
                            channels.files.continuation.yield(try FileChunk(decoding: header + payload))
                            continue
                        }
                        if kind == 1 {
                            let bytes = try await stream.receive(exactly: AudioFrameHeader.encodedSize).content
                            let header = try AudioFrameHeader(decoding: bytes)
                            let payload = try await stream.receive(exactly: Int(header.payloadLength)).content
                            channels.audio.continuation.yield((header, [UInt8](payload)))
                            continue
                        }
                        let headerBytes = try await stream.receive(exactly: VideoFrameHeader.encodedSize).content
                        let header = try VideoFrameHeader(decoding: headerBytes)
                        let payload = try await stream.receive(exactly: Int(header.payloadLength)).content
                        channels.video.continuation.yield((header, [UInt8](payload)))
                    }
                }
                channels.audio.continuation.finish()
                channels.video.continuation.finish()
                channels.files.continuation.finish()
            } catch {
                Logger(subsystem: "com.pocketdesk", category: "transport")
                    .error("Media streams ended: \(String(describing: error), privacy: .public)")
                channels.audio.continuation.finish(throwing: error)
                channels.video.continuation.finish(throwing: error)
                channels.files.continuation.finish(throwing: error)
            }
        }
        // The host may hang up while we're still setting up (e.g. it can't capture the
        // screen); the readers above must not outlive the connection.
        let datagrams: QUIC.Datagrams<QUICDatagram>
        do { datagrams = try await connection.datagrams } catch {
            await stop([controlReader, videoReader])
            throw error
        }

        let files = OnFirstUse(keptAfterClose: true) {
            try await connection.openStream { stream in Coder(ControlMessage.self, using: .json) { stream } }
        }
        return QUICPeerSession(peer: host, control: control, datagrams: OnFirstUse(keptAfterClose: true) { datagrams },
                               video: nil, audio: nil, hostFiles: nil, clientFiles: files,
                               channels: channels, readers: [controlReader, videoReader])
    }

    // MARK: PeerSession

    public func send(_ message: ControlMessage) async throws {
        try await control.send(message)
    }

    public func send(_ input: InputEvent) async throws {
        try await datagrams.value.send(Data(input.encoded()))
    }

    /// Completes when QUIC has accepted the frame, which is the backpressure signal the
    /// host uses to drop frames instead of queueing them.
    public func send(frame header: VideoFrameHeader, payload: [UInt8]) async throws {
        guard let video else { throw TransportError.wrongRole }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(VideoFrameHeader.encodedSize + payload.count)
        header.encode(into: &bytes)
        bytes.append(contentsOf: payload)
        try await Self.sendWhole(bytes, on: try await video.value)
    }

    public func send(audio header: AudioFrameHeader, payload: [UInt8]) async throws {
        guard let audio else { throw TransportError.wrongRole }
        guard payload.count == Int(header.payloadLength), payload.count <= AudioFrameHeader.maxPayloadLength else {
            throw WireError.invalidValue
        }
        var bytes: [UInt8] = []
        header.encode(into: &bytes)
        bytes.append(contentsOf: payload)
        try await Self.sendWhole(bytes, on: try await audio.value)
    }

    public func send(chunk: FileChunk) async throws {
        if let hostFiles {
            try await Self.sendWhole(chunk.encoded(), on: try await hostFiles.value)
        } else if let clientFiles {
            try await clientFiles.value.send(.fileData(Data(chunk.encoded()).base64EncodedString()))
        } else {
            throw TransportError.wrongRole
        }
    }

    /// Sends one frame even if the caller is cancelled midway (the host restarts its pumps
    /// on every source or size change): half a frame would corrupt the stream's framing.
    private static func sendWhole(_ bytes: [UInt8], on stream: QUIC.Stream<QUICStream>) async throws {
        try await Task { try await stream.send(bytes) }.value
    }

    /// Cancels setup-time readers and waits for them, for when `accept`/`open` fails partway.
    private static func stop(_ readers: [Task<Void, Never>]) async {
        for reader in readers { reader.cancel() }
        for reader in readers { await reader.value }
    }

    /// Stops the readers and waits for them to finish, so every stream they hold is released
    /// while the connection still exists. Network.framework traps if a stream outlives the
    /// scope of its connection.
    public func close() async {
        let tasks = readers.withLock { tasks in
            defer { tasks = [] }
            return tasks
        }
        for task in tasks { task.cancel() }
        finishAll()
        for task in tasks { await task.value }
        await datagrams.close()
        await video?.close()
        await audio?.close()
        await hostFiles?.close()
        await clientFiles?.close()
    }
}

/// A stream or datagram flow made the first time it's used (concurrent first uses share
/// one), and dropped by `close()` so it can't outlive the connection's scope.
private final class OnFirstUse<Value: Sendable>: Sendable {
    private let make: @Sendable () async throws -> Value
    private let made = Mutex<Task<Value, any Error>?>(nil)
    /// Phone side: see `QUICPeerSession.deinit`.
    private let keptAfterClose: Bool

    init(keptAfterClose: Bool = false, _ make: @escaping @Sendable () async throws -> Value) {
        self.keptAfterClose = keptAfterClose
        self.make = make
    }

    var value: Value {
        get async throws {
            let make = make
            let task = made.withLock { made in
                if let made { return made }
                let task = Task { try await make() }
                made = task
                return task
            }
            return try await task.value
        }
    }

    func close() async {
        let task = made.withLock { made in
            defer { made = nil }
            return made
        }
        _ = await task?.result
        if keptAfterClose, let task { Retired.keep(task) }
    }
}

/// Phone-side streams that must never be released (see `QUICPeerSession.deinit`).
private enum Retired {
    private static let objects = Mutex<[any Sendable]>([])
    static func keep(_ object: any Sendable) { objects.withLock { $0.append(object) } }
}

/// The five inbound channels, created before the readers that feed them.
private struct Channels: Sendable {
    let audio = AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let control = AsyncThrowingStream<ControlMessage, any Error>.makeStream()
    let input = AsyncThrowingStream<InputEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
    // Unbounded on purpose: every delta frame references the one before it, so dropping any
    // encoded frame here corrupts everything until the next keyframe (smeared, ghosted video).
    // Pacing is the host's job: it drops frames before encoding when the network is behind.
    let video = AsyncThrowingStream<(VideoFrameHeader, [UInt8]), any Error>.makeStream(bufferingPolicy: .unbounded)
    // Bounded by the transfers themselves: a sender stays within `FileChunk.window`.
    let files = AsyncThrowingStream<FileChunk, any Error>.makeStream(bufferingPolicy: .unbounded)

    var finish: @Sendable () -> Void {
        { [control, input, video, audio, files] in
            files.continuation.finish()
            audio.continuation.finish()
            control.continuation.finish()
            input.continuation.finish()
            video.continuation.finish()
        }
    }
}
