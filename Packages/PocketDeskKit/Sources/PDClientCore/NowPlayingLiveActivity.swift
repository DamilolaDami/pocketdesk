import Foundation
import PDProtocol

/// Shows `NowPlayingActivityModel`'s steps somewhere: the Live Activity on iOS, a fake in tests.
public protocol NowPlayingPresenter: Sendable {
    /// The activity still running from an earlier launch, if any. Any others are ended.
    func adopt() async -> (hostID: UUID, card: NowPlayingCard)?
    /// `images` holds the covers the step's card names (`artworkID`), by ID. Site icons are
    /// saved when they're fetched.
    func apply(_ step: NowPlayingActivityStep, images: [String: Data]) async
    /// Calls `handler` with the APNs tokens a Mac needs to push to the activity, now and
    /// whenever Apple issues new ones.
    func watchPushTokens(_ handler: @escaping @Sendable (NowPlayingPushTokens) -> Void) async
}

extension NowPlayingPresenter {
    public func watchPushTokens(_ handler: @escaping @Sendable (NowPlayingPushTokens) -> Void) async {}
}

/// Hex APNs tokens: one to start the activity, and the running activity's own, with what
/// that activity shows (it may be one a Mac started by push).
public struct NowPlayingPushTokens: Sendable, Equatable {
    public var start: String?
    public var activity: String?
    public var showing: (hostID: UUID, card: NowPlayingCard)?

    public init(start: String? = nil, activity: String? = nil, showing: (hostID: UUID, card: NowPlayingCard)? = nil) {
        self.start = start
        self.activity = activity
        self.showing = showing
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.start == rhs.start && lhs.activity == rhs.activity
            && lhs.showing?.hostID == rhs.showing?.hostID && lhs.showing?.card == rhs.showing?.card
    }
}

#if os(iOS)
// `Activity` isn't marked Sendable yet; this actor is the only thing that touches it.
@preconcurrency import ActivityKit

/// The Live Activity's fixed part. Shared with the widget extension, which draws it.
public struct NowPlayingAttributes: ActivityAttributes {
    public typealias ContentState = NowPlayingCard
    public var hostID: UUID

    public init(hostID: UUID) {
        self.hostID = hostID
    }
}

/// Starts, updates and ends the Now Playing Live Activity. Updates come only from the app
/// (there's no push server), so content goes stale after `staleAfter` and the widget says so.
public actor LiveActivityPresenter: NowPlayingPresenter {
    public static let staleAfter: TimeInterval = 15 * 60
    private var activity: Activity<NowPlayingAttributes>?
    private var tokens = NowPlayingPushTokens()
    private var onTokens: (@Sendable (NowPlayingPushTokens) -> Void)?
    private var startTokens: Task<Void, Never>?
    private var activityTokens: Task<Void, Never>?
    private var pushedActivities: Task<Void, Never>?

    public init() {}

    public func adopt() async -> (hostID: UUID, card: NowPlayingCard)? {
        var running = Activity<NowPlayingAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        guard !running.isEmpty else { return nil }
        let kept = running.removeFirst()
        for extra in running { await extra.end(nil, dismissalPolicy: .immediate) }
        activity = kept
        follow(kept)
        return (kept.attributes.hostID, kept.content.state)
    }

    public func watchPushTokens(_ handler: @escaping @Sendable (NowPlayingPushTokens) -> Void) {
        onTokens = handler
        handler(tokens)
        guard startTokens == nil else { return }
        startTokens = Task {
            for await token in Activity<NowPlayingAttributes>.pushToStartTokenUpdates {
                tokens.start = Self.hex(token)
                onTokens?(tokens)
            }
        }
        // One a Mac started by push: carry it on rather than start another.
        pushedActivities = Task {
            for await started in Activity<NowPlayingAttributes>.activityUpdates where started.id != activity?.id {
                activity = started
                follow(started)
            }
        }
    }

    /// The running activity's own token, which a Mac uses to update and end it.
    private func follow(_ activity: Activity<NowPlayingAttributes>?) {
        activityTokens?.cancel()
        tokens.activity = nil
        tokens.showing = activity.map { ($0.attributes.hostID, $0.content.state) }
        onTokens?(tokens)
        guard let activity else { return }
        activityTokens = Task {
            for await token in activity.pushTokenUpdates {
                tokens.activity = Self.hex(token)
                onTokens?(tokens)
            }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public func apply(_ step: NowPlayingActivityStep, images: [String: Data]) async {
        switch step {
        case .none:
            break
        case .start(let hostID, let card):
            save(images)
            await start(hostID: hostID, card)
        case .update(let card):
            save(images)
            guard let activity else { return }
            await activity.update(content(card))
        case .replace(let hostID, let card):
            save(images)
            await start(hostID: hostID, card)
        case .end:
            await activity?.end(nil, dismissalPolicy: .immediate)
            activity = nil
            follow(nil)
        }
    }

    /// Ends the one showing first: there's only ever one.
    private func start(hostID: UUID, _ card: NowPlayingCard) async {
        await activity?.end(nil, dismissalPolicy: .immediate)
        activity = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // With a push token, so the Mac can carry it on once the app has left the screen.
        activity = (try? Activity.request(attributes: NowPlayingAttributes(hostID: hostID), content: content(card), pushType: .token))
            ?? (try? Activity.request(attributes: NowPlayingAttributes(hostID: hostID), content: content(card)))
        follow(activity)
    }

    private func content(_ card: NowPlayingCard) -> ActivityContent<NowPlayingCard> {
        // Playing ranks above paused when the system has several activities to choose from.
        ActivityContent(state: card, staleDate: .now + Self.staleAfter, relevanceScore: card.isPlaying ? 100 : 50)
    }

    private func save(_ images: [String: Data]) {
        try? NowPlayingArtwork.save(images)
    }
}
#endif
