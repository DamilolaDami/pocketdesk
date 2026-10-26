import Foundation

/// What the Lock Screen and Dynamic Island show while a Mac plays something: the Live
/// Activity's content. ActivityKit refuses content over 4 KB, so the cover travels as a file
/// in the App Group (`NowPlayingArtwork`), named by `artworkID`.
public struct NowPlayingCard: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String?
    /// The Mac app playing it ("Spotify", "Safari").
    public var appName: String?
    public var macName: String
    public var isPlaying: Bool
    /// Stable playback origin, not an elapsed counter. Nil for live/unknown media.
    public var startedAt: Date?
    public var duration: Double?
    /// Frozen position while paused.
    public var pausedElapsed: Double?
    /// `nil` when there's no cover, or Settings hides it.
    public var artworkID: String?
    /// The cover's average color (else the site icon's), which the album style paints the
    /// background with.
    public var tint: CardColor?
    public var style: NowPlayingStyle
    public var showsSkipButtons: Bool
    /// The site a browser plays it from, as people say it: "netflix.com".
    public var site: String?
    /// Names the site's icon in the App Group, like `artworkID`.
    public var siteIconID: String?

    public init(title: String, artist: String? = nil, appName: String? = nil, macName: String, isPlaying: Bool,
                artworkID: String? = nil, tint: CardColor? = nil, style: NowPlayingStyle = .album,
                showsSkipButtons: Bool = true, site: String? = nil, siteIconID: String? = nil,
                startedAt: Date? = nil, duration: Double? = nil, pausedElapsed: Double? = nil) {
        self.title = title
        self.artist = artist
        self.appName = appName
        self.macName = macName
        self.isPlaying = isPlaying
        self.startedAt = startedAt
        self.duration = duration
        self.pausedElapsed = pausedElapsed
        self.artworkID = artworkID
        self.tint = tint
        self.style = style
        self.showsSkipButtons = showsSkipButtons
        self.site = site
        self.siteIconID = siteIconID
    }
}

/// sRGB, 0–1.
public struct CardColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// How the Live Activity is painted.
public enum NowPlayingStyle: String, Codable, CaseIterable, Sendable {
    /// A dark wash of the cover's own color.
    case album
    /// PocketDesk blue.
    case brand
    /// The system's Lock Screen material.
    case system
}

/// Settings › Now Playing. Saved on the phone; the activity's content carries what the widget
/// needs, so a change shows on the Lock Screen straight away. The phone also sends them to the
/// Mac (`NowPlayingPush`) so a card it pushes looks the same.
public struct NowPlayingActivityPreferences: Codable, Equatable, Sendable {
    public var isEnabled = true
    public var showsArtwork = true
    public var showsDetailsInPushes = true
    public var showsSkipButtons = true
    /// End the activity when playback pauses, instead of keeping a paused card.
    public var endsWhenPaused = false
    public var style = NowPlayingStyle.album

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, showsArtwork, showsDetailsInPushes, showsSkipButtons, endsWhenPaused, style
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        showsArtwork = try c.decodeIfPresent(Bool.self, forKey: .showsArtwork) ?? true
        showsDetailsInPushes = try c.decodeIfPresent(Bool.self, forKey: .showsDetailsInPushes) ?? true
        showsSkipButtons = try c.decodeIfPresent(Bool.self, forKey: .showsSkipButtons) ?? true
        endsWhenPaused = try c.decodeIfPresent(Bool.self, forKey: .endsWhenPaused) ?? false
        style = try c.decodeIfPresent(NowPlayingStyle.self, forKey: .style) ?? .album
    }
}

/// What to do with the Live Activity.
public enum NowPlayingActivityStep: Equatable, Sendable {
    case none
    case start(hostID: UUID, NowPlayingCard)
    case update(NowPlayingCard)
    /// Another Mac is the one watched now: end the old activity and start one for it.
    case replace(hostID: UUID, NowPlayingCard)
    case end
}

/// Decides when the Live Activity starts, changes and ends, from the watched Mac's status and
/// the preferences. Pure: the phone's `SessionController` applies the steps to its Live
/// Activity, and the Mac's `NowPlayingPushes` turns them into pushes.
public struct NowPlayingActivityModel: Equatable, Sendable {
    /// What the Mac last said, before preferences: kept so a change in Settings can redraw.
    struct Playing: Equatable, Sendable {
        var hostID: UUID
        var macName: String
        var title: String
        var artist: String?
        var appName: String?
        var isPlaying: Bool
        var artworkID: String?
        var tint: CardColor?
        var site: String?
        var siteIconID: String?
        var siteTint: CardColor?
        var startedAt: Date?
        var duration: Double?
        var pausedElapsed: Double?
    }

    public private(set) var hostID: UUID?
    /// What the activity shows now, `nil` when there isn't one.
    public private(set) var card: NowPlayingCard?
    public private(set) var preferences: NowPlayingActivityPreferences
    private var playing: Playing?

    public init(preferences: NowPlayingActivityPreferences = .init()) {
        self.preferences = preferences
    }

    /// An activity left over from an earlier launch, so it's updated rather than doubled.
    public mutating func adopt(hostID: UUID, card: NowPlayingCard) {
        self.hostID = hostID
        self.card = card
        playing = Playing(hostID: hostID, macName: card.macName, title: card.title, artist: card.artist,
                          appName: card.appName, isPlaying: card.isPlaying, artworkID: card.artworkID, tint: card.tint,
                          site: card.site, siteIconID: card.siteIconID,
                          startedAt: card.startedAt, duration: card.duration, pausedElapsed: card.pausedElapsed)
    }

    /// The watched Mac's status. `artworkID` and `tint` describe `nowPlaying.artwork`;
    /// `siteIconID` and `siteTint` the icon of `nowPlaying.site`, once it's been fetched.
    public mutating func receive(_ nowPlaying: NowPlaying?, from hostID: UUID, macName: String,
                                 artworkID: String? = nil, tint: CardColor? = nil,
                                 siteIconID: String? = nil, siteTint: CardColor? = nil) -> NowPlayingActivityStep {
        playing = nowPlaying.map {
            Playing(hostID: hostID, macName: macName, title: $0.title, artist: $0.artist, appName: $0.app?.name,
                    isPlaying: $0.isPlaying, artworkID: artworkID, tint: tint,
                    site: $0.site.map(Self.spoken), siteIconID: $0.site == nil ? nil : siteIconID, siteTint: siteTint,
                    startedAt: $0.startedAt, duration: $0.duration, pausedElapsed: $0.pausedElapsed)
        }
        return reconcile()
    }

    /// "www.netflix.com" → "netflix.com".
    static func spoken(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The Mac can't be reached any more.
    public mutating func macWentAway() -> NowPlayingActivityStep {
        playing = nil
        return reconcile()
    }

    public mutating func setPreferences(_ preferences: NowPlayingActivityPreferences) -> NowPlayingActivityStep {
        self.preferences = preferences
        return reconcile()
    }

    /// A button on the Lock Screen was pressed: show the result before the Mac confirms it.
    public mutating func press(_ key: MediaKey) -> NowPlayingActivityStep {
        guard key == .playPause, card != nil else { return .none }
        playing?.isPlaying.toggle()
        return reconcile()
    }

    private mutating func reconcile() -> NowPlayingActivityStep {
        var wanted = playing.flatMap(render)
        if let old = card, var next = wanted, old.isPlaying == next.isPlaying,
           old.title == next.title, old.artist == next.artist {
            if PlaybackTimeline.matches(old.startedAt, next.startedAt) { next.startedAt = old.startedAt }
            if PlaybackTimeline.matches(old.duration, next.duration) { next.duration = old.duration }
            if PlaybackTimeline.matches(old.pausedElapsed, next.pausedElapsed) { next.pausedElapsed = old.pausedElapsed }
            wanted = next
        }
        guard let wanted, let playing else {
            guard card != nil else { return .none }
            card = nil
            hostID = nil
            return .end
        }
        guard card != nil else {
            // Opening the app on a paused song shouldn't put it on the Lock Screen.
            guard wanted.isPlaying else { return .none }
            card = wanted
            hostID = playing.hostID
            return .start(hostID: playing.hostID, wanted)
        }
        if hostID != playing.hostID {
            card = wanted
            hostID = playing.hostID
            return .replace(hostID: playing.hostID, wanted)
        }
        guard card != wanted else { return .none }
        card = wanted
        return .update(wanted)
    }

    private func render(_ playing: Playing) -> NowPlayingCard? {
        guard preferences.isEnabled, playing.isPlaying || !preferences.endsWhenPaused else { return nil }
        return NowPlayingCard(title: playing.title, artist: playing.artist, appName: playing.appName,
                              macName: playing.macName, isPlaying: playing.isPlaying,
                              artworkID: preferences.showsArtwork ? playing.artworkID : nil,
                              // A Netflix card takes Netflix's red when there's no cover to take a color from.
                              tint: (preferences.showsArtwork ? playing.tint : nil) ?? playing.siteTint ?? playing.tint,
                              style: preferences.style, showsSkipButtons: preferences.showsSkipButtons,
                              site: playing.site, siteIconID: playing.siteIconID,
                              startedAt: playing.startedAt, duration: playing.duration, pausedElapsed: playing.pausedElapsed)
    }
}

extension NowPlayingCard {
    /// The site icon's name in the phone's App Group: by site, so a card the Mac pushes names
    /// an icon the phone may already have.
    public static func siteIconID(for host: String) -> String {
        "site-" + String(host.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
}

/// Phone → Mac (in `Hello`): what the Mac needs to start the phone's Now Playing Live
/// Activity by push while PocketDesk isn't open, and to keep it current. Sent only inside the
/// encrypted session. The Mac hands pushes to Apple through the relay.
public struct NowPlayingPush: Codable, Sendable, Equatable {
    public enum Environment: String, Codable, Sendable {
        /// Builds from Xcode.
        case sandbox
        /// TestFlight and the App Store.
        case production
    }

    /// The APNs push-to-start token for the activity, hex. `nil`: stop pushing to this phone.
    public var startToken: String?
    /// The running activity's own APNs token, hex, to update and end it.
    public var activityToken: String?
    /// What the phone shows now, so the Mac carries on from it instead of starting another.
    public var showing: NowPlayingCard?
    public var environment: Environment
    /// The app's bundle ID: pushes go to `<bundleID>.push-type.liveactivity`.
    public var bundleID: String
    /// How the phone draws the card, so a pushed one looks the same.
    public var preferences: NowPlayingActivityPreferences
    /// Colors of site icons the phone has saved, by host, for cards without a cover. At most
    /// `maxSiteTints`.
    public var siteTints: [String: CardColor]

    public static let maxSiteTints = 40

    public init(startToken: String?, activityToken: String? = nil, showing: NowPlayingCard? = nil,
                environment: Environment, bundleID: String, preferences: NowPlayingActivityPreferences,
                siteTints: [String: CardColor] = [:]) {
        self.startToken = startToken
        self.activityToken = activityToken
        self.showing = showing
        self.environment = environment
        self.bundleID = bundleID
        self.preferences = preferences
        self.siteTints = siteTints
    }
}
