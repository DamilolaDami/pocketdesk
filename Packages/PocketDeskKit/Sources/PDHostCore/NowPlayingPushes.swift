#if os(macOS)
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDProtocol
import PDSecurity

/// One push for Apple to deliver to a phone's Now Playing Live Activity.
public struct LiveActivityPush: Sendable, Equatable {
    public enum Event: String, Sendable {
        case start, update, end
    }

    public var event: Event
    /// The phone it's for: the relay checks this Mac still allows it.
    public var phone: Fingerprint
    /// The device token it goes to, hex: the push-to-start token for `start`, the activity's
    /// own for the rest.
    public var token: String
    public var environment: NowPlayingPush.Environment
    /// `apns-topic`.
    public var topic: String
    /// The `aps` JSON, at most `maxPayload` bytes.
    public var payload: Data

    /// What Apple accepts for a Live Activity push.
    public static let maxPayload = 4096
}

/// Hands pushes to Apple. The relay will, since the push key can't ship in the Mac app; until
/// it does there's no sender, and the Mac doesn't watch for phones that aren't connected.
public protocol LiveActivityPushSender: Sendable {
    func send(_ push: LiveActivityPush) async throws
}

public enum LiveActivityPushError: Error, Equatable {
    case relayUnavailable
    /// Apple's status (or the relay's own, for a push it wouldn't send) and reason.
    case refused(status: Int, reason: String?)

    /// The token is dead: the phone deleted the app, or the activity it named has ended.
    public var tokenIsDead: Bool {
        guard case .refused(let status, let reason) = self else { return false }
        return status == 410 || ["BadDeviceToken", "Unregistered", "ExpiredToken"].contains(reason)
    }
}

/// Phones that asked for Now Playing pushes (in `Hello.nowPlayingPush`) and what each one's
/// Live Activity shows, so the Mac can start, update and end it while PocketDesk isn't open
/// on the phone. The decisions are `NowPlayingActivityModel`'s, the same as the app's own.
public actor NowPlayingPushes {
    private var phones: [Fingerprint: NowPlayingPush]
    private var models: [Fingerprint: NowPlayingActivityModel] = [:]
    /// Each phone's model before the push in flight, to go back to if it fails.
    private var beforePush: [Fingerprint: NowPlayingActivityModel] = [:]
    /// Since when each phone's card has shown something paused.
    private var pausedSince: [Fingerprint: Date] = [:]
    /// When the Mac last started a card on each phone.
    private var lastStart: [Fingerprint: Date] = [:]

    /// Resuming after this long starts a fresh card: the old one may have been swiped away,
    /// and nothing tells the Mac when it is.
    static let restartAfterPause: TimeInterval = 20
    /// A card the Mac started gets a new update token only once the phone's app has run; until
    /// then it isn't started again sooner than this.
    static let startCooldown: TimeInterval = 60
    private let url: URL?
    /// The last cover, decoded once.
    private var artwork: (base64: String, id: String, tint: CardColor?)?

    /// Kept at `url` between launches (tokens only: what each phone shows starts over).
    public init(url: URL?) {
        self.url = url
        phones = url.flatMap { try? JSONDecoder().decode([Fingerprint: NowPlayingPush].self, from: Data(contentsOf: $0)) } ?? [:]
    }

    public var isEmpty: Bool { phones.isEmpty }

    /// A phone said how to reach its activity, or (`startToken: nil`) that it no longer wants it.
    /// `hostID` is this Mac's: the activity the phone says it shows is this Mac's.
    public func register(_ push: NowPlayingPush, from peer: Fingerprint, hostID: UUID) {
        guard push.startToken != nil else {
            phones[peer] = nil
            models[peer] = nil
            save()
            return
        }
        var trimmed = push
        if trimmed.siteTints.count > NowPlayingPush.maxSiteTints {
            trimmed.siteTints = Dictionary(uniqueKeysWithValues: trimmed.siteTints.sorted { $0.key < $1.key }
                .prefix(NowPlayingPush.maxSiteTints).map { ($0.key, $0.value) })
        }
        phones[peer] = trimmed
        var model = NowPlayingActivityModel(preferences: trimmed.preferences)
        if let showing = trimmed.showing { model.adopt(hostID: hostID, card: showing) }
        models[peer] = model
        save()
    }

    /// Apple said a token is dead. A dead start token means the app's gone: stop until the
    /// phone registers again. A dead activity token means that card was closed: forget it, so
    /// the next song can start a new one.
    public func tokenRejected(_ push: LiveActivityPush) {
        guard var phone = phones[push.phone] else { return }
        if push.event == .start {
            forget(push.phone)
            return
        }
        phone.activityToken = nil
        phones[push.phone] = phone
        models[push.phone] = NowPlayingActivityModel(preferences: phone.preferences)
        save()
    }

    /// A phone was forgotten on this Mac.
    public func forget(_ peer: Fingerprint) {
        phones[peer] = nil
        models[peer] = nil
        save()
    }

    /// The pushes this status calls for. Phones in `connected` are followed but not pushed to:
    /// PocketDesk is open there and draws its own card.
    public func pushes(for playing: NowPlaying?, hostID: UUID, macName: String, connected: Set<Fingerprint>,
                       now: Date = .now) -> [LiveActivityPush] {
        if let base64 = playing?.artwork, artwork?.base64 != base64, let jpeg = Data(base64Encoded: base64) {
            artwork = (base64, Self.artworkID(for: jpeg), Self.averageColor(of: jpeg))
        }
        let cover = playing?.artwork != nil && artwork?.base64 == playing?.artwork ? artwork : nil
        var pushes: [LiveActivityPush] = []
        for (peer, phone) in phones.sorted(by: { $0.key.description < $1.key.description }) {
            // After a restart: carry on from what the phone last said it shows, not start another.
            var model = models[peer] ?? {
                var model = NowPlayingActivityModel(preferences: phone.preferences)
                if let showing = phone.showing { model.adopt(hostID: hostID, card: showing) }
                return model
            }()
            let shown = model.card
            let before = model
            let siteTint = playing?.site.flatMap { phone.siteTints[$0] }
            var step = model.receive(playing, from: hostID, macName: macName, artworkID: cover?.id, tint: cover?.tint,
                                     siteIconID: siteTint == nil ? nil : playing?.site.map(NowPlayingCard.siteIconID(for:)),
                                     siteTint: siteTint)
            let paused = pausedSince[peer]
            pausedSince[peer] = model.card?.isPlaying == false ? (paused ?? now) : nil
            models[peer] = model
            guard !connected.contains(peer) else { continue }
            var ending: LiveActivityPush?
            if case .update(let card) = step, card.isPlaying, Self.shouldRestart(
                resumedAfter: shown?.isPlaying == false ? paused.map { now.timeIntervalSince($0) } : nil,
                hasToken: phone.activityToken != nil, lastStart: lastStart[peer].map { now.timeIntervalSince($0) }) {
                // A fresh card, after ending the old one (if it's still there).
                ending = Self.push(for: .end, shown: shown, to: phone, from: peer, hostID: hostID, macName: macName, now: now)
                step = .start(hostID: hostID, card)
            }
            guard let push = Self.push(for: step, shown: shown, to: phone, from: peer, hostID: hostID, macName: macName, now: now)
            else { continue }
            beforePush[peer] = before
            if let ending { pushes.append(ending) }
            pushes.append(push)
            if push.event == .start {
                // Its update token comes from the phone once the app has run.
                lastStart[peer] = now
                phones[peer]?.activityToken = nil
                save()
            }
        }
        return pushes
    }

    /// Whether an update should be a fresh card instead: after a long pause (the card may
    /// have been swiped away), or when there's no token to update with, but not again right
    /// after starting one.
    static func shouldRestart(resumedAfter pause: TimeInterval?, hasToken: Bool, lastStart: TimeInterval?) -> Bool {
        if let lastStart, lastStart < startCooldown { return false }
        return !hasToken || (pause ?? 0) >= restartAfterPause
    }

    /// A push didn't get through (the relay was away, say): forget it happened, so the next
    /// check sends it again.
    public func pushFailed(_ push: LiveActivityPush) {
        guard let before = beforePush.removeValue(forKey: push.phone), phones[push.phone] != nil else { return }
        models[push.phone] = before
        if push.event == .start { lastStart[push.phone] = nil }
    }

    /// Apple's Live Activity payload for a step. `nil` when there's nothing to send, or no
    /// token to send it to (an activity the Mac started has no update token until the phone's
    /// app has run and sent it).
    static func push(for step: NowPlayingActivityStep, shown: NowPlayingCard?, to phone: NowPlayingPush, from peer: Fingerprint,
                     hostID: UUID, macName: String, now: Date) -> LiveActivityPush? {
        let timestamp = Int(now.timeIntervalSince1970)
        var aps: [String: Any] = ["timestamp": timestamp]
        let event: LiveActivityPush.Event
        let token: String?
        switch step {
        case .none:
            return nil
        case .start(_, let card), .replace(_, let card):
            event = .start
            token = phone.startToken
            aps["content-state"] = json(card)
            aps["attributes-type"] = "NowPlayingAttributes"
            aps["attributes"] = ["hostID": hostID.uuidString]
            aps["alert"] = ["title": card.title, "body": "Playing on \(macName)"]
            aps["stale-date"] = timestamp + 15 * 60
            aps["relevance-score"] = card.isPlaying ? 100 : 50
        case .update(let card):
            event = .update
            token = phone.activityToken
            aps["content-state"] = json(card)
            aps["stale-date"] = timestamp + 15 * 60
            aps["relevance-score"] = card.isPlaying ? 100 : 50
        case .end:
            event = .end
            token = phone.activityToken
            if let shown { aps["content-state"] = json(shown) }
            aps["dismissal-date"] = timestamp
        }
        aps["event"] = event.rawValue
        guard let token, let payload = try? JSONSerialization.data(withJSONObject: ["aps": aps], options: [.sortedKeys]),
              payload.count <= LiveActivityPush.maxPayload else { return nil }
        return LiveActivityPush(event: event, phone: peer, token: token, environment: phone.environment,
                                topic: "\(phone.bundleID).push-type.liveactivity", payload: payload)
    }

    private static func json(_ card: NowPlayingCard) -> Any {
        (try? JSONEncoder().encode(card)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
    }

    // The phone names and colors covers the same way (`NowPlayingArtwork` in PDClientCore),
    // so a pushed card names a cover the phone may already have and is painted the same.

    static func artworkID(for jpeg: Data) -> String {
        SHA256.hash(data: jpeg).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func averageColor(of imageData: Data) -> CardColor? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sums = [0.0, 0.0, 0.0]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { sums[channel] += Double(pixels[index + channel]) }
        }
        let count = Double(side * side) * 255
        return CardColor(red: sums[0] / count, green: sums[1] / count, blue: sums[2] / count)
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(phones) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Device tokens: readable by this account only.
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: data,
                                       attributes: [.posixPermissions: 0o600])
    }
}
#endif
