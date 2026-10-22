/// Wire protocol version. Bump on any incompatible change to messages or framing.
public let protocolVersion: UInt16 = 4

/// ALPN token negotiated over QUIC. Encodes the major protocol version.
public let alpn = "pocketdesk/4"

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
    case listDisplays
    case displays([DisplayInfo])
    case selectDisplay(UInt32)
    case listWindows
    case windows([WindowInfo])
    /// `nil` streams the whole display.
    case selectSource(windowID: UInt32?)
    case streamConfig(StreamConfig)
    case setAudioEnabled(Bool)
    case requestKeyframe
    /// Committed text (IME, dictation, paste). Single keystrokes go over the input channel.
    case insertText(String)
    /// A shortcut from the phone: open a website or app, or press a key combination.
    case run(MacAction)
    /// Host → phone: a `run` that couldn't be done, in words for the person.
    case actionFailed(String)
    /// The Mac's installed apps, for picking one in the shortcut editor.
    case listApps
    case apps([MacApp])
    /// Icons for these bundle IDs; the host answers with one `appIcon` per ID, in order.
    case requestAppIcons([String])
    case appIcon(AppIcon)
    case ping(UInt64)
    case pong(UInt64)
    case bye(reason: String)
}

/// Something a phone shortcut asks the Mac to do. A paired phone can already click and type
/// anything, so these grant nothing new; they just save the taps.
public enum MacAction: Codable, Sendable, Equatable, Hashable {
    /// Any URL the Mac can open (`https:`, or an app's own scheme like `spotify:`).
    case openURL(String)
    /// Launches or brings forward an app. `name` is the fallback when no app has that bundle ID.
    case openApp(bundleID: String?, name: String)
    /// One key press with modifiers held: a macOS virtual key code and `CGEventFlags` bits.
    case keystroke(code: UInt16, modifiers: UInt32)
}

public struct Hello: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        /// Video, input and everything else.
        case stream
        /// No video or input: just questions like `listApps`, then `bye`.
        case catalog
    }

    public var version: UInt16
    public var deviceName: String
    /// Client screen in points + scale, so the host can pick a matching stream size.
    public var viewport: Viewport
    /// Restored per Mac; the host falls back to its main display if unavailable.
    public var preferredDisplayID: String?
    public var audioEnabled: Bool
    public var mode: Mode

    public init(version: UInt16 = protocolVersion, deviceName: String, viewport: Viewport, mode: Mode = .stream, audioEnabled: Bool = true, preferredDisplayID: String? = nil) {
        self.version = version
        self.deviceName = deviceName
        self.viewport = viewport
        self.preferredDisplayID = preferredDisplayID
        self.audioEnabled = audioEnabled
        self.mode = mode
    }
}

public struct MacApp: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var name: String
    public var bundleID: String
    public var id: String { bundleID }

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }
}

public struct AppIcon: Codable, Sendable, Equatable {
    public var bundleID: String
    /// Base64 PNG (compact in JSON), or `nil` if the Mac has no such app.
    public var png: String?

    public init(bundleID: String, png: String?) {
        self.bundleID = bundleID
        self.png = png
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
    /// Stable monitor identity; the numeric capture ID can change after a reboot.
    public var persistentID: String
    public var name: String
    public var isMain: Bool
    public var width: Int
    public var height: Int

    public init(id: UInt32, width: Int, height: Int, name: String = "Display", isMain: Bool = false, persistentID: String? = nil) {
        self.id = id
        self.name = name
        self.isMain = isMain
        self.persistentID = persistentID ?? String(id)
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
    /// The actual whole-display source; nil while streaming a window.
    public var displayID: UInt32?
    public var bitrateKbps: Int

    public init(codec: Codec, width: Int, height: Int, fps: Int, bitrateKbps: Int, displayID: UInt32? = nil) {
        self.codec = codec
        self.width = width
        self.height = height
        self.fps = fps
        self.displayID = displayID
        self.bitrateKbps = bitrateKbps
    }
}
