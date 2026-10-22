import PDProtocol

/// In-memory `PeerSession` pair for tests and SwiftUI previews.
public final class LoopbackSession: PeerSession {
    private typealias Audio = (AudioFrameHeader, [UInt8])
    private typealias Video = (VideoFrameHeader, [UInt8])

    public let controlMessages: AsyncThrowingStream<ControlMessage, any Error>
    public let inputEvents: AsyncThrowingStream<InputEvent, any Error>
    public let videoFrames: AsyncThrowingStream<(VideoFrameHeader, [UInt8]), any Error>

    public let audioFrames: AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error>
    private let peerAudio: AsyncThrowingStream<Audio, any Error>.Continuation

    private let peerControl: AsyncThrowingStream<ControlMessage, any Error>.Continuation
    private let peerInput: AsyncThrowingStream<InputEvent, any Error>.Continuation
    private let peerVideo: AsyncThrowingStream<Video, any Error>.Continuation

    private init(
        receiving streams: (AsyncThrowingStream<ControlMessage, any Error>,
                            AsyncThrowingStream<InputEvent, any Error>,
                            AsyncThrowingStream<Video, any Error>, AsyncThrowingStream<Audio, any Error>),
        sendingTo peer: (AsyncThrowingStream<ControlMessage, any Error>.Continuation,
                         AsyncThrowingStream<InputEvent, any Error>.Continuation,
                         AsyncThrowingStream<Video, any Error>.Continuation, AsyncThrowingStream<Audio, any Error>.Continuation)
    ) {
        (controlMessages, inputEvents, videoFrames, audioFrames) = streams
        (peerControl, peerInput, peerVideo, peerAudio) = peer
    }

    /// Returns two connected ends: whatever one sends, the other receives.
    public static func pair() -> (host: LoopbackSession, client: LoopbackSession) {
        let toClientAudio = AsyncThrowingStream<Audio, any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let toHostAudio = AsyncThrowingStream<Audio, any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let toClientControl = AsyncThrowingStream<ControlMessage, any Error>.makeStream()
        let toClientInput = AsyncThrowingStream<InputEvent, any Error>.makeStream()
        let toClientVideo = AsyncThrowingStream<Video, any Error>.makeStream()
        let toHostControl = AsyncThrowingStream<ControlMessage, any Error>.makeStream()
        let toHostInput = AsyncThrowingStream<InputEvent, any Error>.makeStream()
        let toHostVideo = AsyncThrowingStream<Video, any Error>.makeStream()

        let host = LoopbackSession(
            receiving: (toHostControl.stream, toHostInput.stream, toHostVideo.stream, toHostAudio.stream),
            sendingTo: (toClientControl.continuation, toClientInput.continuation, toClientVideo.continuation, toClientAudio.continuation))
        let client = LoopbackSession(
            receiving: (toClientControl.stream, toClientInput.stream, toClientVideo.stream, toClientAudio.stream),
            sendingTo: (toHostControl.continuation, toHostInput.continuation, toHostVideo.continuation, toHostAudio.continuation))
        return (host, client)
    }

    public func send(_ message: ControlMessage) async throws { try yield(message, to: peerControl) }
    public func send(_ input: InputEvent) async throws { try yield(input, to: peerInput) }
    public func send(frame header: VideoFrameHeader, payload: [UInt8]) async throws {
        try yield((header, payload), to: peerVideo)
    }

    public func send(audio header: AudioFrameHeader, payload: [UInt8]) async throws {
        try yield((header, payload), to: peerAudio)
    }

    public func close() async {
        peerAudio.finish()
        peerControl.finish()
        peerInput.finish()
        peerVideo.finish()
    }

    private func yield<T: Sendable>(_ value: T, to continuation: AsyncThrowingStream<T, any Error>.Continuation) throws {
        if case .terminated = continuation.yield(value) { throw TransportError.closed }
    }
}
