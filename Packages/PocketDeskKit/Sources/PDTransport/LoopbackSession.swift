import PDProtocol

/// In-memory `PeerSession` pair for tests and SwiftUI previews.
public final class LoopbackSession: PeerSession {
    private typealias Video = (VideoFrameHeader, [UInt8])

    public let controlMessages: AsyncThrowingStream<ControlMessage, any Error>
    public let inputEvents: AsyncThrowingStream<InputEvent, any Error>
    public let videoFrames: AsyncThrowingStream<(VideoFrameHeader, [UInt8]), any Error>

    private let peerControl: AsyncThrowingStream<ControlMessage, any Error>.Continuation
    private let peerInput: AsyncThrowingStream<InputEvent, any Error>.Continuation
    private let peerVideo: AsyncThrowingStream<Video, any Error>.Continuation

    private init(
        receiving streams: (AsyncThrowingStream<ControlMessage, any Error>,
                            AsyncThrowingStream<InputEvent, any Error>,
                            AsyncThrowingStream<Video, any Error>),
        sendingTo peer: (AsyncThrowingStream<ControlMessage, any Error>.Continuation,
                         AsyncThrowingStream<InputEvent, any Error>.Continuation,
                         AsyncThrowingStream<Video, any Error>.Continuation)
    ) {
        (controlMessages, inputEvents, videoFrames) = streams
        (peerControl, peerInput, peerVideo) = peer
    }

    /// Returns two connected ends: whatever one sends, the other receives.
    public static func pair() -> (host: LoopbackSession, client: LoopbackSession) {
        let toClientControl = AsyncThrowingStream<ControlMessage, any Error>.makeStream()
        let toClientInput = AsyncThrowingStream<InputEvent, any Error>.makeStream()
        let toClientVideo = AsyncThrowingStream<Video, any Error>.makeStream()
        let toHostControl = AsyncThrowingStream<ControlMessage, any Error>.makeStream()
        let toHostInput = AsyncThrowingStream<InputEvent, any Error>.makeStream()
        let toHostVideo = AsyncThrowingStream<Video, any Error>.makeStream()

        let host = LoopbackSession(
            receiving: (toHostControl.stream, toHostInput.stream, toHostVideo.stream),
            sendingTo: (toClientControl.continuation, toClientInput.continuation, toClientVideo.continuation))
        let client = LoopbackSession(
            receiving: (toClientControl.stream, toClientInput.stream, toClientVideo.stream),
            sendingTo: (toHostControl.continuation, toHostInput.continuation, toHostVideo.continuation))
        return (host, client)
    }

    public func send(_ message: ControlMessage) async throws { try yield(message, to: peerControl) }
    public func send(_ input: InputEvent) async throws { try yield(input, to: peerInput) }
    public func send(frame header: VideoFrameHeader, payload: [UInt8]) async throws {
        try yield((header, payload), to: peerVideo)
    }

    public func close() async {
        peerControl.finish()
        peerInput.finish()
        peerVideo.finish()
    }

    private func yield<T: Sendable>(_ value: T, to continuation: AsyncThrowingStream<T, any Error>.Continuation) throws {
        if case .terminated = continuation.yield(value) { throw TransportError.closed }
    }
}
