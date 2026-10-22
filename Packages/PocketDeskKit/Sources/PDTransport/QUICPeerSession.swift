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

    private let control: ControlStream
    private let datagrams: QUIC.Datagrams<QUICDatagram>
    /// Host only.
    private let videoOut: QUIC.Stream<QUICStream>?
    private let readers: Mutex<[Task<Void, Never>]>
    private let finishAll: @Sendable () -> Void

    private init(peer: Fingerprint, control: ControlStream, datagrams: QUIC.Datagrams<QUICDatagram>,
                 videoOut: QUIC.Stream<QUICStream>?, channels: Channels, readers: [Task<Void, Never>]) {
        self.peer = peer
        self.control = control
        self.datagrams = datagrams
        self.videoOut = videoOut
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
            controlReader.cancel()
            throw TransportError.closed
        }
        guard let peer = Fingerprint(peerOf: connection.securityProtocolMetadata) else {
            controlReader.cancel()
            throw TransportError.unauthenticatedPeer
        }

        let datagrams = try await connection.datagrams
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
        let videoOut = try await connection.openStream(directionality: .unidirectional)

        return QUICPeerSession(peer: peer, control: control, datagrams: datagrams, videoOut: videoOut,
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
                    while true {
                        let headerBytes = try await stream.receive(exactly: VideoFrameHeader.encodedSize).content
                        let header = try VideoFrameHeader(decoding: headerBytes)
                        let payload = try await stream.receive(exactly: Int(header.payloadLength)).content
                        channels.video.continuation.yield((header, [UInt8](payload)))
                    }
                }
                channels.video.continuation.finish()
            } catch {
                channels.video.continuation.finish(throwing: error)
            }
        }
        let datagrams = try await connection.datagrams

        return QUICPeerSession(peer: host, control: control, datagrams: datagrams, videoOut: nil,
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
        guard let videoOut else { throw TransportError.wrongRole }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(VideoFrameHeader.encodedSize + payload.count)
        header.encode(into: &bytes)
        bytes.append(contentsOf: payload)
        try await videoOut.send(bytes)
    }

    public func close() async {
        let tasks = readers.withLock { tasks in
            defer { tasks = [] }
            return tasks
        }
        for task in tasks { task.cancel() }
        finishAll()
    }
}

/// The three inbound channels, created before the readers that feed them.
private struct Channels: Sendable {
    let control = AsyncThrowingStream<ControlMessage, any Error>.makeStream()
    let input = AsyncThrowingStream<InputEvent, any Error>.makeStream(bufferingPolicy: .bufferingNewest(64))
    // Unbounded on purpose: every delta frame references the one before it, so dropping any
    // encoded frame here corrupts everything until the next keyframe (smeared, ghosted video).
    // Pacing is the host's job: it drops frames before encoding when the network is behind.
    let video = AsyncThrowingStream<(VideoFrameHeader, [UInt8]), any Error>.makeStream(bufferingPolicy: .unbounded)

    var finish: @Sendable () -> Void {
        { [control, input, video] in
            control.continuation.finish()
            input.continuation.finish()
            video.continuation.finish()
        }
    }
}
