import Network
import PDProtocol

/// One connected peer, as four logical channels over a single QUIC connection:
///
/// - control: reliable ordered stream of `ControlMessage` (JSON via Network's `Coder`)
/// - input:   QUIC datagrams of `InputEvent` (unreliable, latest-wins pointer moves)
/// - video:   reliable stream of `VideoFrameHeader` + payload, host → client
/// - audio:   independent reliable stream of timestamped AAC-LC packets, host → client
///
/// Engines depend on this protocol, not on Network.framework, so they can be tested against
/// `LoopbackSession` and a future relay transport can slot in without touching them.
public protocol PeerSession: Sendable {
    func send(_ message: ControlMessage) async throws
    var controlMessages: AsyncThrowingStream<ControlMessage, any Error> { get }

    func send(_ input: InputEvent) async throws
    var inputEvents: AsyncThrowingStream<InputEvent, any Error> { get }

    func send(frame header: VideoFrameHeader, payload: [UInt8]) async throws
    var videoFrames: AsyncThrowingStream<(VideoFrameHeader, [UInt8]), any Error> { get }

    func send(audio header: AudioFrameHeader, payload: [UInt8]) async throws
    var audioFrames: AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error> { get }

    func close() async
}

public enum TransportError: Error, Sendable {
    case closed
    case connectionFailed(NWError)
    /// The connection wasn't ready in time (unreachable host, or a rejected handshake).
    case timedOut
    /// The TLS handshake finished without a peer certificate we could fingerprint.
    case unauthenticatedPeer
    /// e.g. sending video from the client side.
    case wrongRole
}
