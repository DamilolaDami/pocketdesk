import Foundation
import PDClientCore
import PDProtocol
import Testing

@Suite struct ShortcutPowerTests {
    @Test func textAsksThenTypesTheWordsAsSaid() {
        let type = MacAction.typeText("Dear \(MacAction.textPlaceholder),\n")
        #expect(type.asksForText)
        // Typed text isn't a link: no percent-encoding.
        #expect(type.filling("  Sam & Alex ") == .typeText("Dear Sam & Alex,\n"))
        #expect(MacAction.copyText(MacAction.textPlaceholder).filling("hi") == .copyText("hi"))
        #expect(MacAction.steps([.system(.lockScreen), .typeText("{text}")]).asksForText)
        #expect(!MacAction.typeText("plain").asksForText)
    }

    @Test func clockPlaceholdersFillWhenItRuns() throws {
        let now = try Date("2026-10-26T11:45:00Z", strategy: .iso8601)
        let filled = MacAction.steps([.typeText("Today is {date}, {time}"),
                                      .openURL("https://example.com/?d={date}")]).fillingClock(now)
        guard case .steps(let steps) = filled, case .typeText(let text) = steps[0], case .openURL(let url) = steps[1] else {
            Issue.record("Expected two steps")
            return
        }
        #expect(text == "Today is \(now.formatted(date: .long, time: .omitted)), \(now.formatted(date: .omitted, time: .shortened))")
        #expect(!url.contains("{date}") && !url.contains(" "))
        // Nothing to fill: the same action.
        #expect(MacAction.media(.mute).fillingClock(now) == .media(.mute))
    }

    @Test func newActionsDescribeThemselves() {
        #expect(MacAction.typeText("{text}").summary == "Types what you say")
        #expect(MacAction.typeText("{date}").summary == "Types today's date")
        #expect(MacAction.copyText("A very long line that keeps on going\nsecond").summary == "Copies “A very long line that ke…”")
        #expect(MacAction.quitApp(bundleID: nil, name: "Slack").summary == "Quits Slack")
        #expect(MacAction.system(.sleepDisplay).summary == "Sleep display")
        #expect(MacAction.typeText("x").needsPicture)
        #expect(!MacAction.copyText("x").needsPicture && !MacAction.system(.sleep).needsPicture)
        #expect(!MacAction.quitApp(bundleID: nil, name: "Music").needsPicture)
    }

    @Test func sharedLinksCarryTheShortcutButNotItsIdentity() throws {
        let mac = UUID()
        let original = Shortcut(name: "Movie Night", symbol: "film.fill", color: .purple,
                                action: .steps([.openURL("https://www.netflix.com"), .wait(milliseconds: 1500),
                                                .keystroke(code: 0x03, modifiers: 0x14_0000)]),
                                showsMac: true, asksFirst: true, macID: mac)
        let url = original.sharingURL
        #expect(url.scheme == "pocketdesk" && url.host() == "add")
        // Safe in a message: no characters that need escaping.
        #expect(!url.absoluteString.contains("+") && !url.absoluteString.contains("/add?shortcut=="))
        let received = try #require(Shortcut(sharingURL: url))
        #expect(received.id != original.id && received.macID == nil)
        #expect(received.name == original.name && received.action == original.action)
        #expect(received.confirms && received.showsMac == true && received.color == .purple)
    }

    @Test func sharedLinksTheMacWouldRefuseAreIgnored() throws {
        #expect(Shortcut(sharingURL: URL(string: "pocketdesk://add?shortcut=bm90IGpzb24")!) == nil)
        #expect(Shortcut(sharingURL: URL(string: "pocketdesk://run?id=x")!) == nil)
        #expect(Shortcut(sharingURL: URL(string: "https://add?shortcut=x")!) == nil)
        let tooManySteps = Shortcut(name: "Spam", symbol: "bolt.fill", color: .red,
                                    action: .steps(Array(repeating: .media(.mute), count: MacAction.maxSteps + 1)))
        #expect(Shortcut(sharingURL: tooManySteps.sharingURL) == nil)
        let unnamed = Shortcut(name: " ", symbol: "bolt.fill", color: .red, action: .media(.mute))
        #expect(Shortcut(sharingURL: unnamed.sharingURL) == nil)
    }

    @Test func shortcutsSavedBeforeTheseOptionsDontAskAndFollowSettings() throws {
        let json = #"{"id":"11111111-0000-4000-8000-000000000001","name":"Netflix","symbol":"play.tv.fill","color":"red","action":{"openURL":{"_0":"https://www.netflix.com"}}}"#
        let shortcut = try JSONDecoder().decode(Shortcut.self, from: Data(json.utf8))
        #expect(!shortcut.confirms && shortcut.macID == nil)
        // A copy keeps them.
        let pinned = Shortcut(name: "Sleep", symbol: "moon.zzz.fill", color: .indigo, action: .system(.sleep),
                              asksFirst: true, macID: UUID())
        #expect(pinned.copy().confirms && pinned.copy().macID == pinned.macID)
    }

    @Test func newPicksAreThere() {
        let names = Set(ShortcutPreset.all.map(\.shortcut.name))
        #expect(names.isSuperset(of: ["Type on Mac", "Copy to Mac", "Sleep Display", "Dark Mode", "Screenshot", "Quit Music"]))
        #expect(ShortcutPreset.all.filter { $0.category == .text }.allSatisfy { $0.shortcut.action.isValid })
        #expect(ShortcutPreset.all.first { $0.shortcut.name == "Sleep Mac" }?.shortcut.confirms == true)
    }
}
