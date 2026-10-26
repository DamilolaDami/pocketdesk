import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PDClientCore
@testable import PDHostCore
import PDProtocol
import PDSecurity

struct NowPlayingPushesTests {
    private let mac = UUID()
    private let phone = Fingerprint(bytes: Data(repeating: 7, count: 32))
    private let song = NowPlaying(title: "Midnight City", artist: "M83", isPlaying: true,
                                  app: PlayerApp(bundleID: "com.spotify.client", name: "Spotify"))

    private func registration(activity: String? = nil, showing: NowPlayingCard? = nil) -> NowPlayingPush {
        NowPlayingPush(startToken: "aabb", activityToken: activity, showing: showing, environment: .sandbox,
                       bundleID: "app.pocketdesk.app", preferences: NowPlayingActivityPreferences(),
                       siteTints: ["www.netflix.com": CardColor(red: 0.9, green: 0, blue: 0)])
    }

    private func aps(_ push: LiveActivityPush) throws -> [String: Any] {
        let json = try #require(try JSONSerialization.jsonObject(with: push.payload) as? [String: Any])
        return try #require(json["aps"] as? [String: Any])
    }

    @Test func startsWithTheStartTokenAndAContentStateThePhoneCanRead() async throws {
        let pushes = NowPlayingPushes(url: nil)
        await pushes.register(registration(), from: phone, hostID: mac)
        let sent = await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: [])
        let push = try #require(sent.first)
        #expect(sent.count == 1 && push.event == .start && push.token == "aabb")
        #expect(push.topic == "app.pocketdesk.app.push-type.liveactivity" && push.environment == .sandbox)
        let aps = try aps(push)
        #expect(aps["event"] as? String == "start")
        #expect(aps["attributes-type"] as? String == "NowPlayingAttributes")
        #expect((aps["attributes"] as? [String: String])?["hostID"] == mac.uuidString)
        #expect((aps["alert"] as? [String: String])?["body"] == "Playing on Studio")
        // ActivityKit decodes content-state as the phone's card.
        let state = try JSONSerialization.data(withJSONObject: try #require(aps["content-state"]))
        let card = try JSONDecoder().decode(NowPlayingCard.self, from: state)
        #expect(card.title == "Midnight City" && card.macName == "Studio" && card.isPlaying)
        #expect(push.payload.count <= LiveActivityPush.maxPayload)
    }

    @Test func updatesAndEndsNeedTheActivitysToken() async throws {
        let pushes = NowPlayingPushes(url: nil)
        await pushes.register(registration(), from: phone, hostID: mac)
        _ = await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: [])
        var paused = song
        paused.isPlaying = false
        // Apple hasn't given the phone one yet: nothing can be sent.
        #expect(await pushes.pushes(for: paused, hostID: mac, macName: "Studio", connected: []).isEmpty)

        let showing = NowPlayingCard(title: "Midnight City", artist: "M83", appName: "Spotify", macName: "Studio", isPlaying: false)
        await pushes.register(registration(activity: "ccdd", showing: showing), from: phone, hostID: mac)
        let update = try #require(await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: []).first)
        #expect(update.event == .update && update.token == "ccdd")
        let end = try #require(await pushes.pushes(for: nil, hostID: mac, macName: "Studio", connected: []).first)
        #expect(end.event == .end && end.token == "ccdd")
        #expect(try aps(end)["dismissal-date"] != nil)
    }

    @Test func aConnectedPhoneDrawsItsOwnAndAWithdrawnOneGetsNothing() async {
        let pushes = NowPlayingPushes(url: nil)
        await pushes.register(registration(), from: phone, hostID: mac)
        #expect(await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: [phone]).isEmpty)
        // It saw that start happen on the phone, so it doesn't start another once the app closes.
        #expect(await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: []).isEmpty)
        var off = registration()
        off.startToken = nil
        await pushes.register(off, from: phone, hostID: mac)
        #expect(await pushes.isEmpty)
    }

    @Test func aSiteThePhoneHasAnIconForUsesItAndItsColor() async throws {
        let pushes = NowPlayingPushes(url: nil)
        await pushes.register(registration(), from: phone, hostID: mac)
        let show = NowPlaying(title: "Netflix", isPlaying: true, app: PlayerApp(bundleID: "com.apple.Safari", name: "Safari"),
                              site: "www.netflix.com")
        let push = try #require(await pushes.pushes(for: show, hostID: mac, macName: "Studio", connected: []).first)
        let state = try JSONSerialization.data(withJSONObject: try #require(try aps(push)["content-state"]))
        let card = try JSONDecoder().decode(NowPlayingCard.self, from: state)
        #expect(card.site == "netflix.com" && card.siteIconID == NowPlayingCard.siteIconID(for: "www.netflix.com"))
        #expect(card.tint == CardColor(red: 0.9, green: 0, blue: 0))
    }

    @Test func resumingAfterALongPauseStartsAFreshCard() async throws {
        let pushes = NowPlayingPushes(url: nil)
        let showing = NowPlayingCard(title: "Midnight City", artist: "M83", appName: "Spotify", macName: "Studio", isPlaying: true)
        await pushes.register(registration(activity: "ccdd", showing: showing), from: phone, hostID: mac)
        var paused = song
        paused.isPlaying = false
        let start = Date(timeIntervalSince1970: 1_000_000)
        #expect(await pushes.pushes(for: paused, hostID: mac, macName: "Studio", connected: [], now: start).first?.event == .update)
        // A quick resume is just an update.
        #expect(await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: [], now: start + 5).first?.event == .update)
        _ = await pushes.pushes(for: paused, hostID: mac, macName: "Studio", connected: [], now: start + 10)
        // Back after a while: the card may have been swiped away, so end it and start another.
        let sent = await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: [], now: start + 40)
        #expect(sent.map(\.event) == [.end, .start])
        #expect(sent.last?.token == "aabb")
        // The new card's update token isn't known yet, and it isn't started twice in a row.
        var next = song
        next.title = "Wait"
        #expect(await pushes.pushes(for: next, hostID: mac, macName: "Studio", connected: [], now: start + 50).isEmpty)
        #expect(await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: [], now: start + 120).first?.event == .start)
    }

    @Test func aFailedPushIsSentAgain() async throws {
        let pushes = NowPlayingPushes(url: nil)
        await pushes.register(registration(), from: phone, hostID: mac)
        let start = try #require(await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: []).first)
        await pushes.pushFailed(start)
        #expect(await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: []).first?.event == .start)
    }

    @Test func deadTokensStopPushesOrLetTheNextSongStartAgain() async throws {
        let pushes = NowPlayingPushes(url: nil)
        let showing = NowPlayingCard(title: "Midnight City", artist: "M83", appName: "Spotify", macName: "Studio", isPlaying: true)
        await pushes.register(registration(activity: "ccdd", showing: showing), from: phone, hostID: mac)
        var paused = song
        paused.isPlaying = false
        let update = try #require(await pushes.pushes(for: paused, hostID: mac, macName: "Studio", connected: []).first)
        // Swiped away on the phone: that card's token is dead, so the next song starts a new one.
        await pushes.tokenRejected(update)
        let start = try #require(await pushes.pushes(for: song, hostID: mac, macName: "Studio", connected: []).first)
        #expect(start.event == .start)
        // The app's been deleted: no more pushes at all.
        await pushes.tokenRejected(start)
        #expect(await pushes.isEmpty)
        #expect(LiveActivityPushError.refused(status: 410, reason: "Unregistered").tokenIsDead)
        #expect(!LiveActivityPushError.refused(status: 429, reason: "TooManyRequests").tokenIsDead)
    }

    @Test func registrationsSurviveARestartAndForgettingDropsThem() async throws {
        let url = URL.temporaryDirectory.appending(path: "pushes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let showing = NowPlayingCard(title: "Midnight City", artist: "M83", appName: "Spotify", macName: "Studio", isPlaying: true)
        await NowPlayingPushes(url: url).register(registration(activity: "ccdd", showing: showing), from: phone, hostID: mac)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let reloaded = NowPlayingPushes(url: url)
        #expect(await !reloaded.isEmpty)
        // It picks up the card the phone shows rather than starting a second one.
        #expect(await reloaded.pushes(for: song, hostID: mac, macName: "Studio", connected: []).isEmpty)
        await reloaded.forget(phone)
        #expect(await NowPlayingPushes(url: url).isEmpty)
    }

    @Test func coversAreNamedAndColoredAsThePhoneDoes() throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let jpeg = data as Data
        #expect(NowPlayingPushes.artworkID(for: jpeg) == NowPlayingArtwork.id(for: jpeg))
        #expect(NowPlayingPushes.averageColor(of: jpeg) == NowPlayingArtwork.averageColor(of: jpeg))
    }
}
