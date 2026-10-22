import Foundation
import Observation
import PDProtocol

/// The one observable the SwiftUI layer reads. Views call `send(_:)` (or the
/// `SessionController`, which also starts the side effects); engines report back the same way.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var state: SessionState = .idle
    /// The Mac's windows, from the last `listWindows`. Not part of the state machine.
    public private(set) var windows: [WindowInfo] = []
    public private(set) var displaySelection = DisplaySelection()
    /// Latest round-trip and decode stats, updated off the hot path at most a few times a second.
    public private(set) var stats = StreamStats()
    /// How the Mac has fitted the stream to the network; nil until it first adapts.
    public private(set) var link: LinkQuality?
    /// Saved shortcuts, in display order. Persisted by `SessionController`.
    public private(set) var shortcuts: [Shortcut] = []
    /// A message to show briefly over whatever screen is up (e.g. a shortcut that failed).
    public private(set) var notice: Notice?
    /// The apps on the Mac shortcuts run on, for the editor. Cached per Mac.
    public private(set) var macApps: [MacApp] = []
    /// PNG app icons by bundle ID: the editor's list and app shortcut tiles.
    public private(set) var appIcons: [String: Data] = [:]
    public private(set) var catalogStatus = CatalogStatus.idle

    public init() {}

    public func send(_ event: SessionEvent) {
        state = state.reduce(event)
        switch event {
        case .connected(let config): displaySelection = displaySelection.reduce(.streaming(config.displayID))
        case .cancel, .disconnected, .select:
            displaySelection = displaySelection.reduce(.reset)
            link = nil
        default: break
        }
    }

    public func update(displays: [DisplayInfo]) {
        displaySelection = displaySelection.reduce(.available(displays))
    }

    public func update(windows: [WindowInfo]) {
        self.windows = windows
    }

    public func update(stats: StreamStats) {
        self.stats = stats
    }

    public func update(link: LinkQuality) {
        self.link = link
    }

    public func update(shortcuts: [Shortcut]) {
        self.shortcuts = shortcuts
    }

    /// A shortcut waiting for the words it needs (a search, say); the app shows a prompt.
    public private(set) var textRequest: TextRequest?

    public func ask(forTextFor shortcut: Shortcut, preferredHostID: UUID?) {
        textRequest = TextRequest(shortcut: shortcut, preferredHostID: preferredHostID)
    }

    public func clearTextRequest() {
        textRequest = nil
    }

    /// The target Mac's volume and now playing while live tiles are on screen.
    public private(set) var macStatus: MacStatus?

    public func update(macStatus: MacStatus?) {
        if self.macStatus != macStatus { self.macStatus = macStatus }
    }

    /// The target Mac's Shortcuts-app shortcuts, for "Run Mac Shortcut".
    public private(set) var macShortcuts: [MacShortcut] = []

    public func update(macShortcuts: [MacShortcut]) {
        self.macShortcuts = macShortcuts
    }

    public func update(macApps: [MacApp]) {
        self.macApps = macApps
    }

    public func add(icon png: Data, for bundleID: String) {
        appIcons[bundleID] = png
    }

    public func update(catalogStatus: CatalogStatus) {
        self.catalogStatus = catalogStatus
    }

    public func post(notice text: String, kind: Notice.Kind = .problem) {
        notice = Notice(text: text, kind: kind)
    }

    public func dismiss(_ notice: Notice) {
        if self.notice == notice { self.notice = nil }
    }
}

public struct TextRequest: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var shortcut: Shortcut
    public var preferredHostID: UUID?
}

public struct Notice: Sendable, Equatable, Identifiable {
    /// Something went wrong, or something went right (a shortcut ran, a copy arrived).
    public enum Kind: Sendable { case problem, done }

    public var id = UUID()
    public var text: String
    public var kind: Kind = .problem
}

public struct StreamStats: Sendable, Equatable {
    public var roundTripMillis: Double = 0
    public var framesPerSecond: Double = 0
    public var bitrateKbps: Double = 0

    public init() {}
}

public enum CatalogStatus: Sendable, Equatable {
    case idle
    case loading
    case loaded
    /// No paired Mac is online to ask.
    case unavailable
    case failed(String)
}
