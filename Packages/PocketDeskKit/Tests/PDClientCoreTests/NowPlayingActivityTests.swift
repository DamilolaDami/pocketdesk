import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PDClientCore
import PDProtocol

struct NowPlayingActivityTests {
    private let studio = UUID(), air = UUID()
    private let song = NowPlaying(title: "Midnight City", artist: "M83", isPlaying: true,
                                  app: PlayerApp(bundleID: "com.spotify.client", name: "Spotify"))

    private func paused(_ playing: NowPlaying) -> NowPlaying {
        var playing = playing
        playing.isPlaying = false
        return playing
    }

    @Test func startsWhenSomethingPlaysAndEndsWhenItStops() {
        var model = NowPlayingActivityModel()
        let step = model.receive(song, from: studio, macName: "Studio", artworkID: "cover", tint: CardColor(red: 1, green: 0, blue: 0))
        let card = NowPlayingCard(title: "Midnight City", artist: "M83", appName: "Spotify", macName: "Studio", isPlaying: true,
                                  artworkID: "cover", tint: CardColor(red: 1, green: 0, blue: 0))
        #expect(step == .start(hostID: studio, card))
        #expect(model.hostID == studio)
        // The Mac reports every second, but only changes reach the activity.
        #expect(model.receive(song, from: studio, macName: "Studio", artworkID: "cover", tint: CardColor(red: 1, green: 0, blue: 0)) == .none)
        #expect(model.receive(nil, from: studio, macName: "Studio") == .end)
        #expect(model.card == nil && model.hostID == nil)
        #expect(model.receive(nil, from: studio, macName: "Studio") == .none)
    }

    @Test func aPausedSongDoesNotStartOneButKeepsARunningOne() {
        var model = NowPlayingActivityModel()
        #expect(model.receive(paused(song), from: studio, macName: "Studio") == .none)
        _ = model.receive(song, from: studio, macName: "Studio")
        guard case .update(let card) = model.receive(paused(song), from: studio, macName: "Studio") else {
            Issue.record("Expected an update")
            return
        }
        #expect(!card.isPlaying)
    }

    @Test func endsWhenPausedIfSetSo() {
        var preferences = NowPlayingActivityPreferences()
        preferences.endsWhenPaused = true
        var model = NowPlayingActivityModel(preferences: preferences)
        _ = model.receive(song, from: studio, macName: "Studio")
        #expect(model.receive(paused(song), from: studio, macName: "Studio") == .end)
    }

    @Test func anotherMacReplacesTheActivity() {
        var model = NowPlayingActivityModel()
        _ = model.receive(song, from: studio, macName: "Studio")
        guard case .replace(let hostID, let card) = model.receive(song, from: air, macName: "Air") else {
            Issue.record("Expected a replace")
            return
        }
        #expect(hostID == air && card.macName == "Air")
    }

    @Test func preferencesRedrawEndAndRestart() {
        var model = NowPlayingActivityModel()
        _ = model.receive(song, from: studio, macName: "Studio", artworkID: "cover")
        var preferences = NowPlayingActivityPreferences()
        preferences.showsArtwork = false
        preferences.showsSkipButtons = false
        preferences.style = .brand
        guard case .update(let card) = model.setPreferences(preferences) else {
            Issue.record("Expected an update")
            return
        }
        #expect(card.artworkID == nil && !card.showsSkipButtons && card.style == .brand)
        // Showing the cover again needs no word from the Mac.
        preferences.showsArtwork = true
        #expect(model.setPreferences(preferences) == .update(NowPlayingCard(
            title: "Midnight City", artist: "M83", appName: "Spotify", macName: "Studio", isPlaying: true,
            artworkID: "cover", style: .brand, showsSkipButtons: false)))
        preferences.isEnabled = false
        #expect(model.setPreferences(preferences) == .end)
        // Off means off, whatever plays.
        #expect(model.receive(song, from: studio, macName: "Studio") == .none)
        preferences.isEnabled = true
        guard case .start = model.setPreferences(preferences) else {
            Issue.record("Expected a start")
            return
        }
    }

    @Test func pressingPlayPauseShowsTheResultAtOnce() {
        var model = NowPlayingActivityModel()
        #expect(model.press(.playPause) == .none)
        _ = model.receive(song, from: studio, macName: "Studio")
        guard case .update(let card) = model.press(.playPause) else {
            Issue.record("Expected an update")
            return
        }
        #expect(!card.isPlaying)
        // Skipping changes the song, which only the Mac knows.
        #expect(model.press(.next) == .none)
        #expect(model.macWentAway() == .end)
    }

    @Test func adoptsAnActivityFromAnEarlierLaunch() {
        var model = NowPlayingActivityModel()
        let card = NowPlayingCard(title: "Midnight City", artist: "M83", appName: "Spotify", macName: "Studio", isPlaying: true)
        model.adopt(hostID: studio, card: card)
        // The same song: no second activity, no redraw.
        #expect(model.receive(song, from: studio, macName: "Studio") == .none)
    }

    @Test func preferencesReadTheirDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "com.pocketdesk.tests.nowplaying.\(UUID().uuidString)"))
        #expect(NowPlayingActivityPreferences(defaults: defaults) == NowPlayingActivityPreferences())
        defaults.set(false, forKey: NowPlayingActivityPreferences.Key.enabled)
        defaults.set("system", forKey: NowPlayingActivityPreferences.Key.style)
        let read = NowPlayingActivityPreferences(defaults: defaults)
        #expect(!read.isEnabled && read.style == .system && read.showsSkipButtons)
    }

    @Test func coversAreSavedOnceAndOnlyTheLatestKept() throws {
        let directory = URL.temporaryDirectory.appending(path: "nowplaying-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try jpeg(red: 1, green: 0, blue: 0), second = try jpeg(red: 0, green: 0, blue: 1)
        #expect(NowPlayingArtwork.id(for: first) == NowPlayingArtwork.id(for: first))
        #expect(NowPlayingArtwork.id(for: first) != NowPlayingArtwork.id(for: second))
        try NowPlayingArtwork.save(["a": first], in: directory)
        try NowPlayingArtwork.save(["b": second, "icon": first], in: directory)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) == ["b.image", "icon.image"])
    }

    @Test func aBrowserCardShowsTheSiteAndTakesItsColorWithoutACover() {
        var model = NowPlayingActivityModel()
        var show = NowPlaying(title: "Stranger Things", isPlaying: true,
                              app: PlayerApp(bundleID: "com.apple.Safari", name: "Safari"), site: "www.netflix.com")
        let red = CardColor(red: 0.9, green: 0.05, blue: 0.1)
        guard case .start(_, let card) = model.receive(show, from: studio, macName: "Studio", siteIconID: "n", siteTint: red) else {
            Issue.record("Expected a start")
            return
        }
        #expect(card.site == "netflix.com" && card.siteIconID == "n" && card.tint == red)
        // A cover's own color wins.
        let blue = CardColor(red: 0, green: 0, blue: 1)
        guard case .update(let covered) = model.receive(show, from: studio, macName: "Studio", artworkID: "c", tint: blue,
                                                         siteIconID: "n", siteTint: red) else {
            Issue.record("Expected an update")
            return
        }
        #expect(covered.tint == blue && covered.siteIconID == "n")
        // Not from a browser: no site, whatever icon was passed.
        show.site = nil
        guard case .update(let plain) = model.receive(show, from: studio, macName: "Studio", siteIconID: "n") else {
            Issue.record("Expected an update")
            return
        }
        #expect(plain.site == nil && plain.siteIconID == nil)
    }

    @Test func siteIconsStayWhenCoversChange() throws {
        let directory = URL.temporaryDirectory.appending(path: "nowplaying-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try jpeg(red: 1, green: 0, blue: 0)
        try NowPlayingArtwork.saveSiteIcon(png, tint: CardColor(red: 1, green: 0, blue: 0), for: "www.netflix.com", in: directory)
        try NowPlayingArtwork.save(["cover": png], in: directory)
        try NowPlayingArtwork.save(["next": png], in: directory)
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
        #expect(names == ["next.image", "site-www-netflix-com.image", "site-tints.json"])
        #expect(NowPlayingArtwork.siteTints(in: directory)["www.netflix.com"] == CardColor(red: 1, green: 0, blue: 0))
    }

    @Test func siteIconsAreShrunkToPNG() throws {
        let big = try jpeg(red: 0, green: 0.5, blue: 1)
        let icon = try #require(NowPlayingArtwork.icon(from: big, maxPixels: 16))
        let source = try #require(CGImageSourceCreateWithData(icon as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 16)
    }

    @Test func averageColorFollowsTheCover() throws {
        let red = try #require(NowPlayingArtwork.averageColor(of: jpeg(red: 0.9, green: 0.1, blue: 0.1)))
        #expect(red.red > 0.8 && red.green < 0.2 && red.blue < 0.2)
        #expect(NowPlayingArtwork.averageColor(of: Data("not an image".utf8)) == nil)
    }

    private func jpeg(red: Double, green: Double, blue: Double) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
