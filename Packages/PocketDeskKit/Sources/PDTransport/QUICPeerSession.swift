import Foundation
import Network
import PDProtocol
import PDSecurity
import Synchronization

/// `PeerSession` over one QUIC connection (see `Channels.swift` for the channel layout).
///
/// - control: bidirectional stream opened by the client, `ControlMessage` as JSON via `Coder`
/// - input:   QUIC datagrams, `InputEvent` binary
/// - video:   unidirectional stream opened by the host, `VideoFrameHeader` + payload
/// - audio:   separate unidirectional stream, `AudioFrameHeader` + raw AAC-LC
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

    private let control: ControlStream
    private let datagrams: QUIC.Datagrams<QUICDatagram>
    /// Host only: video (tag 0) and audio (tag 1), opened on first use.
    private let outbound: OutboundStreams?
    private let readers: Mutex<[Task<Void, Never>]>
    private let finishAll: @Sendable () -> Void

    private init(peer: Fingerprint, control: ControlStream, datagrams: QUIC.Datagrams<QUICDatagram>,
                 outbound: OutboundStreams?, channels: Channels, readers: [Task<Void, Never>]) {
        self.peer = peer
        self.control = control
        self.datagrams = datagrams
        self.audioFrames = channels.audio.stream
        self.outbound = outbound
        self.controlMessages = channels.control.stream
        self.inputEvents = channels.input.stream
        self.videoFrames = channels.video.stream
        self.readers = Mutex(readers)
        self.finishAll = channels.finish
    }

    // MARK: Host side

    /// Wraps a connection from `QUICHostListener`. Returns once the client has opened its
    /// control stream (i.e. sent its first message).
    static func accept(_ connection: NetworkConnection<QUIC>) async throws -> QUICPeerSession {
        let channels = Channels()
        let firstStream = AsyncStream<ControlStream>.makeStream()

        let controlReader = Task {
            do {
                try await connection.inboundStreams(prepending: { stream in Coder(ControlMessage.self, using: .json) { stream } }) { stream in
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
        let outbound = OutboundStreams { tag in
            let stream = try await connection.openStream(directionality: .unidirectional)
            try await stream.send([tag])
            return stream
        }

        return QUICPeerSession(peer: peer, control: control, datagrams: datagrams, outbound: outbound,
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
                    let tag = try await stream.receive(exactly: 1).content
                    guard let kind = tag.first, kind <= 1 else { throw WireError.unknownTag }
                    while true {
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
            } catch {
                channels.audio.continuation.finish(throwing: error)
                channels.video.continuation.finish(throwing: error)
            }
        }
        // The host may hang up while we're still setting up (e.g. it can't capture the
        // screen); the readers above must not outlive the connection.
        let datagrams: QUIC.Datagrams<QUICDatagram>
        do { datagrams = try await connection.datagrams } catch {
            await stop([controlReader, videoReader])
            throw error
        }

        return QUICPeerSession(peer: host, control: control, datagrams: datagrams, outbound: nil,
                               channels: channels, readers: [controlReader, videoReader])
    }

    // MARK: PeerSession

    public func send(_ message: ControlMessage) async throws {
        try await control.send(message)
    }

    public func send(_ input: InputEvent) async throws {
        try await datagrams.send(Data(input.encoded()))
    }

    /// Completes when QUIC has accepted the frame, which is the backpressure signal the
    /// host uses to drop frames instead of queueing them.
    public func send(frame header: VideoFrameHeader, payload: [UInt8]) async throws {
        guard let outbound else { throw TransportError.wrongRole }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(VideoFrameHeader.encodedSize + payload.count)
        header.encode(into: &bytes)
        bytes.append(contentsOf: payload)
        try await outbound.stream(tag: 0).send(bytes)
    }

    public func send(audio header: AudioFrameHeader, payload: [UInt8]) async throws {
        guard let outbound else { throw TransportError.wrongRole }
        guard payload.count == Int(header.payloadLength), payload.count <= AudioFrameHeader.maxPayloadLength else {
            throw WireError.invalidValue
        }
        var bytes: [UInt8] = []
        header.encode(into: &bytes)
        bytes.append(contentsOf: payload)
        try await outbound.stream(tag: 1).send(bytes)
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
        await outbound?.close()
    }
}

/// The host's unidirectional media streams, each opened (and tagged) the first time it's
/// sent on. Concurrent first sends share one open.
private final class OutboundStreams: Sendable {
    typealias Stream = QUIC.Stream<QUICStream>
    private let open: @Sendable (UInt8) async throws -> Stream
    private let streams = Mutex<[UInt8: Task<Stream, any Error>]>([:])

    init(open: @escaping @Sendable (UInt8) async throws -> Stream) {
        self.open = open
    }

    func stream(tag: UInt8) async throws -> Stream {
        let open = open
        let opening = streams.withLock { streams in
            if let opening = streams[tag] { return opening }
            let opening = Task { try await open(tag) }
            streams[tag] = opening
            return opening
        }
        return try await opening.value
    }

    /// Drops the streams so none outlives the connection's scope.
    func close() async {
        let openings = streams.withLock { streams in
            defer { streams = [:] }
            return Array(streams.values)
        }
        for opening in openings { _ = await opening.result }
    }
}

/// The four inbound channels, created before the readers that feed them.
private struct Channels: Sendable {
    let audio = AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let control = AsyncThrowingStream<ControlMessage, any Error>.makeStream()
    let input = AsyncThrowingStream<InputEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
    // Unbounded on purpose: every delta frame references the one before it, so dropping any
    // encoded frame here corrupts everything until the next keyframe (smeared, ghosted video).
    // Pacing is the host's job: it drops frames before encoding when the network is behind.
    let video = AsyncThrowingStream<(VideoFrameHeader, [UInt8]), any Error>.makeStream(bufferingPolicy: .unbounded)

    var finish: @Sendable () -> Void {
        { [control, input, video, audio] in
            audio.continuation.finish()
            control.continuation.finish()
            input.continuation.finish()
            video.continuation.finish()
        }
    }
}
