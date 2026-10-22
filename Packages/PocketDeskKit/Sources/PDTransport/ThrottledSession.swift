import Foundation
import PDProtocol
import Synchronization

/// Wraps a host-side session so its video takes as long to send as it would over a link of
/// `bitsPerSecond` (0 = unlimited). For tests, and for trying link adaptation on a fast LAN:
/// launch the Mac app with `POCKETDESK_SIMULATE_KBPS=2000`.
public final class ThrottledSession: PeerSession {
    public let inner: any PeerSession
    public let bitsPerSecond: Atomic<Int>

    public init(_ inner: any PeerSession, bitsPerSecond: Int) {
        self.inner = inner
        self.bitsPerSecond = Atomic(bitsPerSecond)
    }

    /// `session` throttled as `POCKETDESK_SIMULATE_KBPS` says, or unchanged if it isn't set.
    public static func fromEnvironment(_ session: any PeerSession) -> any PeerSession {
        guard let value = ProcessInfo.processInfo.environment["POCKETDESK_SIMULATE_KBPS"],
              let kbps = Int(value), kbps > 0 else { return session }
        return ThrottledSession(session, bitsPerSecond: kbps * 1_000)
    }

    public var controlMessages: AsyncThrowingStream<ControlMessage, any Error> { inner.controlMessages }
    public var inputEvents: AsyncThrowingStream<InputEvent, any Error> { inner.inputEvents }
    public var videoFrames: AsyncThrowingStream<(VideoFrameHeader, [UInt8]), any Error> { inner.videoFrames }
    public var audioFrames: AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error> { inner.audioFrames }

    public func send(_ message: ControlMessage) async throws { try await inner.send(message) }
    public func send(_ input: InputEvent) async throws { try await inner.send(input) }
    public func send(audio header: AudioFrameHeader, payload: [UInt8]) async throws {
        try await inner.send(audio: header, payload: payload)
    }

    public func send(frame header: VideoFrameHeader, payload: [UInt8]) async throws {
        let bitsPerSecond = bitsPerSecond.load(ordering: .relaxed)
        if bitsPerSecond > 0 {
            try? await Task.sleep(for: .seconds(Double(payload.count * 8) / Double(bitsPerSecond)))
        }
        try await inner.send(frame: header, payload: payload)
    }

    public func close() async { await inner.close() }
}
