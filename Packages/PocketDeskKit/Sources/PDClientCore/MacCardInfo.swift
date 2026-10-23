import PDProtocol

/// How a Mac's connection feels, from its round trip, for the Mac cards.
public enum ConnectionGrade: Sendable, Equatable, CaseIterable {
    case excellent, good, fair, poor

    /// Same-room Wi-Fi is a few milliseconds; past ~150 ms typing and pointing lag.
    public init(latency: Duration) {
        switch latency {
        case ..<Duration.milliseconds(20): self = .excellent
        case ..<Duration.milliseconds(60): self = .good
        case ..<Duration.milliseconds(150): self = .fair
        default: self = .poor
        }
    }

    public var title: String {
        switch self {
        case .excellent: "Excellent"
        case .good: "Good"
        case .fair: "Fair"
        case .poor: "Poor"
        }
    }

    /// Bars out of three, like the Wi-Fi symbol's.
    public var bars: Double {
        switch self {
        case .excellent: 1
        case .good: 0.67
        case .fair: 0.34
        case .poor: 0
        }
    }
}

extension Duration {
    /// "4 ms", "120 ms"; under a millisecond reads "<1 ms".
    public var latencyText: String {
        let ms = Int((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15).rounded())
        return ms < 1 ? "<1 ms" : "\(ms) ms"
    }
}

extension MacBattery {
    /// The SF Symbol for the level, with a bolt while charging.
    public var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Worth drawing attention to: low and not plugged in.
    public var isLow: Bool { level <= 20 && !onPower }

    public var text: String {
        if isCharging { return "\(level)%, charging" }
        if onPower { return "\(level)%, on power" }
        return "\(level)%"
    }
}

extension PlayerApp {
    /// The same player on the iPhone, for "Open on This iPhone": its URL scheme, or `nil` when
    /// there's no iPhone counterpart (a browser playing a video, say).
    public var phoneURL: String? {
        switch bundleID {
        case "com.spotify.client": "spotify:"
        case "com.apple.Music", "com.apple.iTunes": "music:"
        case "com.apple.podcasts": "podcasts:"
        case "com.apple.TV": "videos:"
        case "com.apple.iBooksX": "ibooks:"
        case "com.tidal.desktop": "tidal:"
        case "com.amazon.music": "amznmp3:"
        case "com.deezer.deezer-desktop": "deezer:"
        case "com.soundcloud.desktop": "soundcloud:"
        default: nil
        }
    }
}

extension ClipboardItem {
    /// "Copied “Meeting at 3” from Studio", short enough for a banner.
    public static func copiedNotice(_ item: ClipboardItem, from mac: String) -> String {
        guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return "Copied an image from \(mac)"
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let preview = line.count > 40 ? line.prefix(40) + "…" : Substring(line)
        return "Copied “\(preview)” from \(mac)"
    }
}
