import PDProtocol

extension MenuItem {
    /// A menu's items in groups, split where the Mac draws a separator line.
    public var sections: [[MenuItem]] {
        var sections: [[MenuItem]] = [[]]
        for item in children ?? [] {
            if item.isSeparator {
                if !(sections.last?.isEmpty ?? true) { sections.append([]) }
            } else {
                sections[sections.count - 1].append(item)
            }
        }
        return sections.filter { !$0.isEmpty }
    }

    /// The Apple menu, first on every menu bar.
    public var isAppleMenu: Bool { path == [0] && title == "Apple" }
}

extension MenuBar {
    /// The menu to open on first: File if the app has one, else the first after the app's own.
    public var startingMenu: MenuItem? {
        menus.first { $0.title == "File" } ?? menus.dropFirst(2).first ?? menus.last
    }
}
