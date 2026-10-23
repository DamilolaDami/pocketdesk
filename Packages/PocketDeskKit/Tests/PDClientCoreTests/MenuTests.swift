import Testing
import PDProtocol
@testable import PDClientCore

struct MenuTests {
    @Test func separatorsSplitSections() {
        let menu = MenuItem(path: [2], title: "File", children: [
            .separator(path: [2, 0]),
            MenuItem(path: [2, 1], title: "New Window"),
            MenuItem(path: [2, 2], title: "New Tab"),
            .separator(path: [2, 3]),
            .separator(path: [2, 4]),
            MenuItem(path: [2, 5], title: "Close"),
            .separator(path: [2, 6]),
        ])
        #expect(menu.sections.map { $0.map(\.title) } == [["New Window", "New Tab"], ["Close"]])
        #expect(MenuItem(path: [3], title: "Empty", children: []).sections.isEmpty)
    }

    @Test func startsOnFile() {
        let titles = ["Apple", "Safari", "File", "Edit"]
        let bar = MenuBar(appName: "Safari", menus: titles.enumerated().map { MenuItem(path: [$0], title: $1, children: []) })
        #expect(bar.startingMenu?.title == "File")
        #expect(bar.menus[0].isAppleMenu)
        let noFile = MenuBar(appName: "Calculator", menus: ["Apple", "Calculator", "Edit", "View"].enumerated()
            .map { MenuItem(path: [$0], title: $1, children: []) })
        #expect(noFile.startingMenu?.title == "Edit")
    }
}
