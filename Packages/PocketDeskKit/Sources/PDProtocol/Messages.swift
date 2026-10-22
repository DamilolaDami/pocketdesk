/// Wire protocol version. Bump on any incompatible change to messages or framing.
public let protocolVersion: UInt16 = 1

/// ALPN token negotiated over QUIC. Encodes the major protocol version.
public let alpn = "pocketdesk/1"

/// Bonjour service type advertised by the host on the local network.
public let bonjourServiceType = "_pocketdesk._udp"

/// Reliable, ordered messages on the control stream (Codable, framed by TLV).
public enum ControlMessage: Codable, Sendable, Equatable {
    case hello(Hello)
    case helloAck(HelloAck)
    /// First message from an unpaired phone: the token from the scanned QR invite.
    case pairRequest(PairRequest)
    /// Host's answer once the person at the Mac accepts or rejects the verification code.
    case pairResult(accepted: Bool)
    case listWindows
    case windows([WindowInfo])
    /// `nil` streams the whole display.
    case selectSource(windowID: UInt32?)
    case streamConfig(StreamConfig)
    case requestKeyframe
    /// Committed text (IME, dictation, paste). Single keystrokes go over the input channel.
    case insertText(String)
    case ping(UInt64)
    case pong(UInt64)
    case bye(reason: String)
}

public struct Hello: Codable, Sendable, Equatable {
    public var version: UInt16
    public var deviceName: String
    /// Client screen in points + scale, so the host can pick a matching stream size.
    public var viewport: Viewport

    public init(version: UInt16 = protocolVersion, deviceName: String, viewport: Viewport) {
        self.version = version
        self.deviceName = deviceName
        self.viewport = viewport
    }
}

public struct PairRequest: Codable, Sendable, Equatable {
    public var token: [UInt8]
    public var deviceName: String

    public init(token: [UInt8], deviceName: String) {
        self.token = token
        self.deviceName = deviceName
    }
}

public struct HelloAck: Codable, Sendable, Equatable {
    public var version: UInt16
    public var hostName: String
    public var displays: [DisplayInfo]

    public init(version: UInt16 = protocolVersion, hostName: String, displays: [DisplayInfo]) {
        self.version = version
        self.hostName = hostName
        self.displays = displays
    }
}

public struct Viewport: Codable, Sendable, Equatable {
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(width: Double, height: Double, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

public struct DisplayInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var width: Int
    public var height: Int

    public init(id: UInt32, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }
}

public struct WindowInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: UInt32
    public var appName: String
    public var bundleID: String?
    public var title: String
    public var width: Int
    public var height: Int

    public init(id: UInt32, appName: String, bundleID: String?, title: String, width: Int, height: Int) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.width = width
        self.height = height
    }
}

public struct StreamConfig: Codable, Sendable, Equatable {
    public enum Codec: String, Codable, Sendable { case h264, hevc }

    public var codec: Codec
    public var width: Int
    public var height: Int
    public var fps: Int
    public var bitrateKbps: Int

    public init(codec: Codec, width: Int, height: Int, fps: Int, bitrateKbps: Int) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrateKbps = bitrateKbps
    }
}
