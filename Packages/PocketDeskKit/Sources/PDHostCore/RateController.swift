import PDProtocol

/// What a `StreamQuality` allows, before link adaptation takes anything off.
public struct QualityCeiling: Sendable, Equatable {
    /// Resolution beyond the phone's screen, per side (see `StreamSizing`).
    public var zoomHeadroom: Double
    public var fps: Int
    /// Fraction of the bitrate the size and frame rate would otherwise get.
    public var bitrate: Double

    public init(_ quality: StreamQuality) {
        switch quality {
        case .best: (zoomHeadroom, fps, bitrate) = (StreamSizing.defaultZoomHeadroom, 60, 1)
        case .balanced: (zoomHeadroom, fps, bitrate) = (1, 60, 0.8)
        // Under the phone's own pixels: text is softer, but there's half as much to decode.
        case .batterySaver: (zoomHeadroom, fps, bitrate) = (0.75, 30, 0.6)
        }
    }
}

/// Fits the stream to the link. Every half second `HostSession` reports what happened (frames
/// dropped because the network was behind, how long sends took, the latest round trip) and
/// this walks a ladder: bitrate first, then frame rate, then resolution. It steps down at once
/// when the link struggles and back up only after a quiet stretch, which doubles each time a
/// step up fails straight away, so a link at its limit doesn't flap.
///
/// Pure value; the session applies `step`, under the ceiling of the phone's `StreamQuality`.
public struct RateController: Sendable, Equatable {
    public struct Step: Sendable, Equatable {
        /// Fraction of the full-quality bitrate.
        public var bitrate: Double
        /// Frame rate cap.
        public var fps: Int
        /// Fraction of the full stream size, per side. Changing it restarts the stream.
        public var scale: Double
    }

    /// Text stays readable all the way down: the last rungs are about the phone's own
    /// resolution (the full size has 1.5× zoom headroom).
    public static let ladder: [Step] = [
        Step(bitrate: 1, fps: 60, scale: 1),
        Step(bitrate: 0.7, fps: 60, scale: 1),
        Step(bitrate: 0.5, fps: 60, scale: 1),
        Step(bitrate: 0.35, fps: 30, scale: 1),
        Step(bitrate: 0.25, fps: 30, scale: 1),
        Step(bitrate: 0.15, fps: 30, scale: 2.0 / 3),
        Step(bitrate: 0.1, fps: 20, scale: 2.0 / 3),
    ]

    /// One measurement window.
    public struct Sample: Sendable, Equatable {
        public var framesSent: Int
        public var framesDropped: Int
        /// Average time QUIC took to accept a frame.
        public var averageSendTime: Duration?
        public var roundTrip: Duration?

        public init(framesSent: Int, framesDropped: Int, averageSendTime: Duration? = nil, roundTrip: Duration? = nil) {
            self.framesSent = framesSent
            self.framesDropped = framesDropped
            self.averageSendTime = averageSendTime
            self.roundTrip = roundTrip
        }
    }

    public private(set) var level = 0
    public var step: Step { Self.ladder[level] }
    /// Worth telling the person: the picture is visibly reduced.
    public var isWeak: Bool { level >= 2 }

    /// Quiet windows needed before stepping up; doubles when a step up fails (backoff).
    public private(set) var recoveryWindows = RateController.baseRecoveryWindows
    static let baseRecoveryWindows = 6
    static let maxRecoveryWindows = 60
    /// Windows to wait after stepping down before stepping down again, so one burst of
    /// trouble doesn't fall through the whole ladder before the last step takes effect.
    static let holdWindows = 2

    private var quietWindows = 0
    private var hold = 0
    /// Windows since the last step up, while it's still on probation.
    private var sinceStepUp: Int?
    private var minRoundTrip: Duration?

    public init() {}

    /// Records one window. Returns true if `level` changed.
    public mutating func update(_ sample: Sample) -> Bool {
        if let roundTrip = sample.roundTrip { minRoundTrip = min(minRoundTrip ?? roundTrip, roundTrip) }
        if let since = sinceStepUp { sinceStepUp = since + 1 }
        hold = max(0, hold - 1)

        if isCongested(sample) {
            quietWindows = 0
            guard hold == 0, level < Self.ladder.count - 1 else { return false }
            if let since = sinceStepUp, since <= 10 {
                // The level we just left was too much after all: wait longer next time.
                recoveryWindows = min(recoveryWindows * 2, Self.maxRecoveryWindows)
            }
            sinceStepUp = nil
            level += 1
            hold = Self.holdWindows
            return true
        }

        if let since = sinceStepUp, since > 20 {
            // The step up held: forgive earlier failures gradually.
            recoveryWindows = max(Self.baseRecoveryWindows, recoveryWindows / 2)
            sinceStepUp = nil
        }
        // A still screen sends nothing, which says nothing about the link.
        guard sample.framesSent > 0 else { return false }
        quietWindows += 1
        guard level > 0, quietWindows >= recoveryWindows else { return false }
        level -= 1
        quietWindows = 0
        sinceStepUp = 0
        return true
    }

    func isCongested(_ sample: Sample) -> Bool {
        let attempted = sample.framesSent + sample.framesDropped
        // More than one frame in six dropped because the network hadn't taken the last ones.
        if attempted >= 4, sample.framesDropped * 6 > attempted { return true }
        if let sendTime = sample.averageSendTime, sendTime > .milliseconds(100) { return true }
        // Queues building up along the path show as round trips well above the best seen.
        if let roundTrip = sample.roundTrip, let minRoundTrip, roundTrip - minRoundTrip > .milliseconds(80) { return true }
        return false
    }
}
