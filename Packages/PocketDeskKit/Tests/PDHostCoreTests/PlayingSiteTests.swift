import Testing
@testable import PDHostCore

struct PlayingSiteTests {
    @Test func picksTheTabPlayingIt() {
        let tabs = [("Inbox (3) - Gmail", "https://mail.google.com/mail/u/0/"),
                    ("Stranger Things | Netflix", "https://www.netflix.com/watch/80057281"),
                    ("Never Gonna Give You Up - YouTube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ")]
        #expect(PlayingSite.match("Stranger Things", in: tabs.map { ($0.0, $0.1) }) == "www.netflix.com")
        #expect(PlayingSite.match("never gonna give you up", in: tabs.map { ($0.0, $0.1) }) == "www.youtube.com")
        // The tab title can be the shorter one.
        #expect(PlayingSite.match("Twitch Live: Speedrun Marathon", in: [("Twitch", "https://www.twitch.tv/gdq")]) == "www.twitch.tv")
    }

    @Test func onlyWebPagesAndOnlyAMatch() {
        #expect(PlayingSite.match("Song", in: [("Song", "file:///Users/me/song.mp3")]) == nil)
        #expect(PlayingSite.match("Song", in: [("Something else", "https://example.com")]) == nil)
        #expect(PlayingSite.match(" ", in: [("", "https://example.com")]) == nil)
    }
}
