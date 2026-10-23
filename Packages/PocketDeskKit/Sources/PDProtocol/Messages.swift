/// Wire protocol version. Bump on any incompatible change to messages or framing.
public let protocolVersion: UInt16 = 15

/// ALPN token negotiated over QUIC. Encodes the major protocol version.
public let alpn = "pocketdesk/\(protocolVersion)"

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
    /// Host → phone: the stream was fitted to the link (sent whenever that changes).
    case linkQuality(LinkQuality)
    case setAudioEnabled(Bool)
    /// Phone → host: the most the stream may use from now on (restarts it at the new size).
    case setQuality(StreamQuality)
    /// Copied on one side, for the other's clipboard (either direction, while streaming).
    case clipboard(ClipboardItem)
    case setClipboardEnabled(Bool)
    case requestKeyframe
    /// Committed text (IME, dictation, paste).
    case insertText(String)
    /// One key going down or up. Keys ride the control stream, not datagrams: a lost key-up
    /// would leave ⌘ held down on the Mac.
    case key(KeyPress)
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
    /// The shortcuts in the Mac's Shortcuts app, for a "Run Mac Shortcut" tile.
    case listMacShortcuts
    case macShortcuts([MacShortcut])
    /// Phone → host: send `macStatus` now and whenever it changes, until the session ends.
    case watchStatus
    case macStatus(MacStatus)
    /// Phone → host: `true` sends the frontmost app's `menuBar` now and again whenever the
    /// frontmost app changes; `false` stops.
    case watchMenus(Bool)
    /// Host → phone: the frontmost app's menus, or `nil` when they can't be read.
    case menuBar(MenuBar?)
    /// Phone → host: choose a menu item. A fresh `menuBar` follows.
    case pressMenuItem(MenuPress)
    case ping(UInt64)
    case pong(UInt64)
    case bye(reason: String)
}

/// Something a phone shortcut asks the Mac to do. A paired phone can already click and type
/// anything, so these grant nothing new; they just save the taps. (Mac Shortcuts are ones the
/// person at the Mac made, and could already be run from the Mac's menu bar.)
public indirect enum MacAction: Codable, Sendable, Equatable, Hashable {
    /// Any URL the Mac can open (`https:`, or an app's own scheme like `spotify:`).
    case openURL(String)
    /// Launches or brings forward an app. `name` is the fallback when no app has that bundle ID.
    case openApp(bundleID: String?, name: String)
    /// One key press with modifiers held: a macOS virtual key code and `CGEventFlags` bits.
    case keystroke(code: UInt16, modifiers: UInt32)
    /// A keyboard media key. Play/Pause controls whatever is playing (Netflix in Safari,
    /// Music, YouTube), whichever app is in front.
    case media(MediaKey)
    /// Play / Pause, Next or Previous in one player, whatever else is playing. Volume and
    /// mute are the Mac's, not a player's, so they stay `media`.
    case mediaIn(MediaKey, player: MediaPlayer)
    /// A shortcut from the Mac's Shortcuts app: by identifier, falling back to the name.
    case runShortcut(id: String?, name: String)
    /// Output volume, 0–100.
    case setVolume(Int)
    /// A pause between steps.
    case wait(milliseconds: Int)
    /// Several actions in order, one level deep; the Mac stops at the first that fails.
    case steps([MacAction])
}

extension MacAction {
    public static let maxSteps = 20
    public static let maxWaitMilliseconds = 30_000

    /// Within what the Mac will run: no nested steps, short waits, a sane volume.
    public var isValid: Bool {
        switch self {
        case .steps(let steps):
            !steps.isEmpty && steps.count <= Self.maxSteps
                && steps.allSatisfy { if case .steps = $0 { false } else { $0.isValid } }
        case .wait(let milliseconds): (0...Self.maxWaitMilliseconds).contains(milliseconds)
        case .setVolume(let level): (0...100).contains(level)
        case .mediaIn(let key, _): key.isTransport
        default: true
        }
    }
}

public struct MacShortcut: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum MediaKey: String, Codable, Sendable, Hashable, CaseIterable {
    case playPause, next, previous, volumeUp, volumeDown, mute

    /// The keys a player can be told directly.
    public var isTransport: Bool { [.playPause, .next, .previous].contains(self) }
}

/// Players the Mac can address directly (they take AppleScript). Browsers can't: a Netflix
/// tab only answers the media keys, so it's "whatever's playing".
public enum MediaPlayer: String, Codable, Sendable, Hashable, CaseIterable {
    case music, spotify, tv

    public var name: String {
        switch self {
        case .music: "Music"
        case .spotify: "Spotify"
        case .tv: "TV"
        }
    }

    public var bundleID: String {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case .tv: "com.apple.TV"
        }
    }
}

public struct Hello: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        /// Video, input and everything else.
        case stream
        /// No video or input: just questions like `listApps`, or one `run` (Siri, widgets),
        /// then `bye`.
        case catalog
    }

    public var version: UInt16
    public var deviceName: String
    /// Client screen in points + scale, so the host can pick a matching stream size.
    public var viewport: Viewport
    /// Restored per Mac; the host falls back to its main display if unavailable.
    public var preferredDisplayID: String?
    public var audioEnabled: Bool
    /// Share copied text and images with the Mac during this session.
    public var clipboardEnabled: Bool
    public var mode: Mode
    public var quality: StreamQuality

    public init(version: UInt16 = protocolVersion, deviceName: String, viewport: Viewport, mode: Mode = .stream, audioEnabled: Bool = true, preferredDisplayID: String? = nil, clipboardEnabled: Bool = true,
                quality: StreamQuality = .best) {
        self.quality = quality
        self.clipboardEnabled = clipboardEnabled
        self.version = version
        self.deviceName = deviceName
        self.viewport = viewport
        self.preferredDisplayID = preferredDisplayID
        self.audioEnabled = audioEnabled
        self.mode = mode
    }
}

/// How much the stream may use: a ceiling over the Mac's link adaptation, which still steps
/// down from it when the network struggles.
public enum StreamQuality: String, Codable, Sendable, CaseIterable {
    /// Up to 60 fps, with resolution to spare for pinch-zooming.
    case best
    /// The phone's own resolution at up to 60 fps.
    case balanced
    /// Fewer pixels and up to 30 fps, for battery and data.
    case batterySaver

    public var name: String {
        switch self {
        case .best: "Best"
        case .balanced: "Balanced"
        case .batterySaver: "Battery Saver"
        }
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
    /// How to wake this Mac from sleep later. Sent only inside the encrypted session.
    public var wake: WakeInfo?

    public init(version: UInt16 = protocolVersion, hostName: String, displays: [DisplayInfo], wake: WakeInfo? = nil) {
        self.version = version
        self.hostName = hostName
        self.displays = displays
        self.wake = wake
    }
}

/// The Mac's network interfaces, for Wake-on-LAN once it's asleep.
public struct WakeInfo: Codable, Sendable, Equatable {
    public struct Interface: Codable, Sendable, Equatable {
        /// Hardware address, "aa:bb:cc:dd:ee:ff".
        public var mac: String
        /// Its IPv4 address and subnet broadcast address when the Mac was last seen.
        public var ipv4: String?
        public var broadcast: String?

        public init(mac: String, ipv4: String? = nil, broadcast: String? = nil) {
            self.mac = mac
            self.ipv4 = ipv4
            self.broadcast = broadcast
        }
    }

    public var interfaces: [Interface]
    /// The Mac's "Wake for network access" setting, when it could tell.
    public var wakeForNetworkAccess: Bool?

    public init(interfaces: [Interface], wakeForNetworkAccess: Bool? = nil) {
        self.interfaces = interfaces
        self.wakeForNetworkAccess = wakeForNetworkAccess
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

/// How the host has fitted the stream to the network right now.
public struct LinkQuality: Codable, Sendable, Equatable {
    /// The picture is visibly reduced to keep up with a weak connection.
    public var isWeak: Bool
    public var bitrateKbps: Int
    public var fps: Int
    public var roundTripMillis: Int?

    public init(isWeak: Bool, bitrateKbps: Int, fps: Int, roundTripMillis: Int? = nil) {
        self.isWeak = isWeak
        self.bitrateKbps = bitrateKbps
        self.fps = fps
        self.roundTripMillis = roundTripMillis
    }
}

/// Clipboard contents: text, or an image as PNG. Big items are refused, not truncated: the
/// control stream also carries input-related messages.
public struct ClipboardItem: Codable, Sendable, Equatable {
    public var text: String?
    /// Base64 PNG (compact in JSON).
    public var png: String?

    public static let maxTextBytes = 1_000_000
    public static let maxImageBytes = 8_000_000

    public init(text: String? = nil, png: String? = nil) {
        self.text = text
        self.png = png
    }

    public var isEmpty: Bool { (text ?? "").isEmpty && (png ?? "").isEmpty }

    public var fitsLimits: Bool {
        (text?.utf8.count ?? 0) <= Self.maxTextBytes && (png?.utf8.count ?? 0) * 3 / 4 <= Self.maxImageBytes
    }
}

/// A macOS virtual key code (`kVK_*`) and the `CGEventFlags` modifier bits held with it.
public struct KeyPress: Codable, Sendable, Equatable {
    public var code: UInt16
    public var isDown: Bool
    public var modifiers: UInt32

    public init(code: UInt16, isDown: Bool, modifiers: UInt32 = 0) {
        self.code = code
        self.isDown = isDown
        self.modifiers = modifiers
    }
}

/// What live tiles show: the Mac's volume and what's playing.
public struct MacStatus: Codable, Sendable, Equatable {
    /// 0–100, or `nil` if the output device has no volume control.
    public var volume: Int?
    public var muted: Bool?
    /// `nil` when nothing is playing, or when macOS won't say.
    public var nowPlaying: NowPlaying?

    public init(volume: Int? = nil, muted: Bool? = nil, nowPlaying: NowPlaying? = nil) {
        self.volume = volume
        self.muted = muted
        self.nowPlaying = nowPlaying
    }
}

public struct NowPlaying: Codable, Sendable, Equatable {
    public var title: String
    public var artist: String?
    public var isPlaying: Bool

    public init(title: String, artist: String? = nil, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
    }
}

/// The frontmost Mac app's menu bar, for showing as native phone menus.
public struct MenuBar: Codable, Sendable, Equatable {
    public var appName: String
    public var bundleID: String?
    /// The menus along the bar (the Apple menu, the app menu, File, Edit…), each with items.
    public var menus: [MenuItem]

    /// Bounds on what the Mac reads (some apps list hundreds of bookmarks or recent files).
    public static let maxDepth = 3
    public static let maxItemsPerMenu = 150
    public static let maxItems = 3_000

    public init(appName: String, bundleID: String? = nil, menus: [MenuItem]) {
        self.appName = appName
        self.bundleID = bundleID
        self.menus = menus
    }
}

public struct MenuItem: Codable, Sendable, Equatable, Identifiable {
    /// Where the item is: child indexes from the menu bar down, as the Mac lists them.
    public var path: [Int]
    public var title: String
    public var isEnabled: Bool
    public var isChecked: Bool
    /// The key equivalent as the Mac shows it, like "⇧⌘N".
    public var shortcut: String?
    /// A submenu's items; `nil` for an item that does something. Separators are `isSeparator`.
    public var children: [MenuItem]?
    public var isSeparator: Bool
    public var id: [Int] { path }

    public init(path: [Int], title: String, isEnabled: Bool = true, isChecked: Bool = false,
                shortcut: String? = nil, children: [MenuItem]? = nil, isSeparator: Bool = false) {
        self.path = path
        self.title = title
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.shortcut = shortcut
        self.children = children
        self.isSeparator = isSeparator
    }

    public static func separator(path: [Int]) -> MenuItem {
        MenuItem(path: path, title: "", isEnabled: false, isSeparator: true)
    }
}

/// A menu item to choose. The title must still match: menus change, and a stale path must
/// not press something else.
public struct MenuPress: Codable, Sendable, Equatable {
    public var path: [Int]
    public var title: String

    public init(path: [Int], title: String) {
        self.path = path
        self.title = title
    }
}
