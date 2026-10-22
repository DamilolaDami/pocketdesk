import Foundation
import PDProtocol
import Testing
@testable import PDClientCore

struct DisplaySelectionTests {
    let main = DisplayInfo(id: 1, width: 1920, height: 1080, name: "Built-in", isMain: true, persistentID: "builtin")
    let external = DisplayInfo(id: 2, width: 2560, height: 1440, name: "External", persistentID: "external")

    @Test func onlyConfirmedSelectionChangesTheCheckmark() {
        let state = DisplaySelection().reduce(.available([main, external]))
        #expect(state.selectedID == nil)
        let selected = state.reduce(.streaming(2))
        #expect(selected.selectedID == 2)
        #expect(selected.reduce(.streaming(nil)).selectedID == 2)
        #expect(selected.reduce(.available([main])).selectedID == nil)
        #expect(selected.reduce(.reset) == DisplaySelection())
    }

    @Test func savesSelectionsSeparatelyPerMacAndForgetsThem() throws {
        let first = UUID(), second = UUID()
        let directory = FileManager.default.temporaryDirectory.appending(path: "display-prefs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "displays.json")
        var preferences = DisplayPreferences()
        preferences.remember(external.persistentID, for: first)
        preferences.remember(main.persistentID, for: second)
        try preferences.save(to: url)
        var loaded = try DisplayPreferences.load(from: url)
        #expect(loaded.displayID(for: first) == "external")
        #expect(loaded.displayID(for: second) == "builtin")
        #expect(loaded.displayID(for: nil) == nil)
        loaded.forget(first)
        #expect(loaded.displayID(for: first) == nil)
        #expect(loaded.displayID(for: second) == "builtin")
    }

    @Test @MainActor func storeTracksConfirmedDisplayAndClearsBetweenMacs() {
        let store = SessionStore()
        store.update(displays: [main, external])
        let config = StreamConfig(codec: .hevc, width: 1920, height: 1080, fps: 60, bitrateKbps: 10_000, displayID: 2)
        store.send(.connected(config))
        #expect(store.displaySelection.selectedID == 2)
        store.send(.cancel)
        #expect(store.displaySelection == DisplaySelection())
    }
}
