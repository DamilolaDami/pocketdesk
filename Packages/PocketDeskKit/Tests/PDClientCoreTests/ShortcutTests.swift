import Foundation
import PDClientCore
import PDProtocol
import Testing

@Suite struct ShortcutLibraryTests {
    private let netflix = Shortcut(name: "Netflix", symbol: "play.tv.fill", color: .red,
                                   action: .openURL("https://www.netflix.com"))
    private let music = Shortcut(name: "Music", symbol: "music.note", color: .pink,
                                 action: .openApp(bundleID: "com.apple.Music", name: "Music"))
    private let spotlight = Shortcut(name: "Spotlight", symbol: "magnifyingglass", color: .gray,
                                     action: .keystroke(code: 0x31, modifiers: ShortcutPreset.command))

    @Test func mediaKeysRunWithoutThePicture() {
        #expect(!MacAction.media(.playPause).needsPicture)
        #expect(netflix.action.needsPicture)
        #expect(spotlight.action.needsPicture)
        var quiet = netflix
        quiet.showsMac = false
        #expect(!quiet.opensStream && quiet.copy().showsMac == false)
        var watched = Shortcut(name: "Pause", symbol: "pause", color: .red, action: .media(.playPause))
        #expect(!watched.opensStream)
        watched.showsMac = true
        #expect(watched.opensStream)
    }

    @Test func stepsAndMacShortcutsDescribeThemselves() {
        #expect(MacAction.runShortcut(id: nil, name: "Focus").summary == "Runs “Focus”")
        #expect(MacAction.setVolume(60).summary == "Volume 60%")
        #expect(MacAction.mediaIn(.playPause, player: .spotify).summary == "Play / Pause · Spotify")
        #expect(!MacAction.mediaIn(.next, player: .tv).needsPicture)
        #expect(MacAction.wait(milliseconds: 1500).summary == "Wait 1.5 s")
        #expect(MacAction.steps([.media(.playPause), .setVolume(30)]).summary == "2 steps")
        #expect(!MacAction.steps([.media(.playPause), .setVolume(30)]).needsPicture)
        #expect(MacAction.steps([.openURL("https://netflix.com"), .setVolume(30)]).needsPicture)
    }

    @Test func searchesAskThenFillTheLink() {
        let search = MacAction.openURL("https://www.youtube.com/results?search_query={text}")
        #expect(search.asksForText)
        #expect(!MacAction.openURL("https://www.youtube.com").asksForText)
        #expect(search.filling(" lo-fi beats & chill ") == .openURL("https://www.youtube.com/results?search_query=lo-fi%20beats%20%26%20chill"))
        #expect(search.filling("café") == .openURL("https://www.youtube.com/results?search_query=caf%C3%A9"))
        #expect(search.summary == "youtube.com · asks first")
        #expect(search.website == "https://www.youtube.com/results?search_query=")
        let routine = MacAction.steps([.openURL("https://maps.apple.com/?q={text}"), .wait(milliseconds: 500)])
        #expect(routine.asksForText)
        #expect(routine.filling("Soho") == .steps([.openURL("https://maps.apple.com/?q=Soho"), .wait(milliseconds: 500)]))
    }

    @Test func shortcutsSavedBeforeShowsMacStillLoad() throws {
        let json = #"{"id":"11111111-0000-4000-8000-000000000001","name":"Netflix","symbol":"play.tv.fill","color":"red","action":{"openURL":{"_0":"https://www.netflix.com"}}}"#
        let shortcut = try JSONDecoder().decode(Shortcut.self, from: Data(json.utf8))
        #expect(shortcut.showsMac == nil && shortcut.opensStream)
    }

    @Test func startsWithNetflixAndFriends() {
        let names = ShortcutLibrary().shortcuts.map(\.name)
        #expect(names.first == "Netflix")
        #expect(names.count == 6)
        #expect(Set(ShortcutLibrary().shortcuts.map(\.id)).count == 6)
    }

    @Test func saveAddsThenReplaces() {
        var library = ShortcutLibrary(shortcuts: [netflix])
        library.save(music)
        var renamed = netflix
        renamed.name = "Movies"
        library.save(renamed)
        #expect(library.shortcuts.map(\.name) == ["Movies", "Music"])
    }

    @Test func duplicateGoesRightAfterTheOriginal() {
        var library = ShortcutLibrary(shortcuts: [netflix, music])
        library.duplicate(netflix.id)
        #expect(library.shortcuts.map(\.name) == ["Netflix", "Netflix", "Music"])
        #expect(library.shortcuts[1].id != netflix.id)
        #expect(library.shortcuts[1].action == netflix.action)
    }

    @Test func moveAndDelete() {
        var library = ShortcutLibrary(shortcuts: [netflix, music, spotlight])
        library.move(spotlight.id, to: netflix.id)
        #expect(library.shortcuts.map(\.name) == ["Spotlight", "Netflix", "Music"])
        library.move(spotlight.id, to: music.id)
        #expect(library.shortcuts.map(\.name) == ["Netflix", "Music", "Spotlight"])
        library.delete(music.id)
        #expect(library.shortcuts.map(\.name) == ["Netflix", "Spotlight"])
    }

    @Test func persists() throws {
        let url = URL.temporaryDirectory.appending(path: "pocketdesk-\(UUID())/shortcuts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let library = ShortcutLibrary(shortcuts: [netflix, music, spotlight])
        try library.save(to: url)
        #expect(try ShortcutLibrary.load(from: url) == library)
    }

    @Test func summaries() {
        #expect(netflix.action.summary == "netflix.com")
        #expect(music.action.summary == "Opens Music")
        #expect(spotlight.action.summary == "⌘Space")
        #expect(MacAction.keystroke(code: 0x0C, modifiers: ShortcutPreset.command | ShortcutPreset.control).summary == "⌃⌘Q")
        #expect(MacAction.media(.playPause).summary == "Play / Pause")
        // Media keys are Mac controls in the editor.
        #expect(ShortcutPreset.all.contains { $0.category == .controls && $0.shortcut.action == .media(.playPause) })
    }

    @Test func presetNamesAreUnique() {
        #expect(Set(ShortcutPreset.all.map(\.id)).count == ShortcutPreset.all.count)
    }
}

@Suite struct FaviconTests {
    @Test func prefersTouchIconsThenLargestIcon() {
        let html = """
        <head>
          <link rel="icon" href="/favicon-16.png" sizes="16x16">
          <link rel='shortcut icon' href='https://cdn.example.com/fav.ico'>
          <link href="/icon-192.png" rel="icon" sizes="192x192" />
          <link rel="mask-icon" href="/safari.svg">
          <link rel="icon" type="image/svg+xml" href="/icon">
          <LINK REL="apple-touch-icon" HREF="touch.png">
          <link rel="stylesheet" href="/app.css">
        </head>
        """
        let urls = FaviconLoader.candidates(inHTML: html, baseURL: URL(string: "https://www.example.com/en/")!)
        #expect(urls.map(\.absoluteString) == [
            "https://www.example.com/en/touch.png",
            "https://www.example.com/icon-192.png",
            "https://www.example.com/favicon-16.png",
            "https://cdn.example.com/fav.ico",
        ])
    }
}
