import PDClientCore
import PDProtocol
import SwiftUI

/// The frontmost Mac app's menu bar as native phone menus: the menus along the top, the
/// chosen one's items below. Choosing an item chooses it on the Mac.
struct MenusSheet: View {
    let controller: SessionController
    let dismiss: () -> Void
    /// The menu showing, by title (indexes change when another app comes forward).
    @State private var selected: String?

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: dismiss)
                    }
                }
        }
        // The Mac sends the menus now and again whenever another app comes forward.
        .task { controller.watchMenus() }
        .onDisappear { controller.stopWatchingMenus() }
    }

    @ViewBuilder private var content: some View {
        switch controller.store.menus {
        case .ready(let bar):
            let menu = bar.menus.first { $0.title == selected } ?? bar.startingMenu
            VStack(spacing: 0) {
                MenuBarStrip(menus: bar.menus, selected: menu?.title) { selected = $0 }
                if let menu {
                    MenuList(controller: controller, menu: menu, dismiss: dismiss)
                } else {
                    Spacer()
                }
            }
            .navigationTitle(bar.appName)
        case .unavailable:
            ContentUnavailableView("No Menus", systemImage: "filemenu.and.selection",
                                   description: Text("The Mac couldn't read the menus of the app in front. Make sure PocketDesk has Accessibility access in the Mac's Privacy & Security settings."))
                .navigationTitle("Menus")
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Menus")
        }
    }
}

/// The menu titles along the top, like the Mac's menu bar, scrolling sideways.
private struct MenuBarStrip: View {
    let menus: [MenuItem]
    let selected: String?
    let select: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(menus) { menu in
                        let isSelected = menu.title == selected
                        Button { select(menu.title) } label: {
                            Group {
                                if menu.isAppleMenu {
                                    Image(systemName: "apple.logo").accessibilityLabel("Apple")
                                } else {
                                    Text(menu.title)
                                }
                            }
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(isSelected ? Brand.accent : Color.secondary.opacity(0.15), in: .capsule)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                        .id(menu.title)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .onAppear { if let selected { proxy.scrollTo(selected, anchor: .center) } }
            .onChange(of: selected) { if let selected { withAnimation { proxy.scrollTo(selected, anchor: .center) } } }
        }
    }
}

/// One menu's items, grouped as the Mac groups them; submenus open as their own page.
private struct MenuList: View {
    let controller: SessionController
    let menu: MenuItem
    let dismiss: () -> Void

    var body: some View {
        List {
            ForEach(Array(menu.sections.enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(section) { item in
                        if item.children != nil {
                            NavigationLink {
                                MenuList(controller: controller, menu: item, dismiss: dismiss)
                                    .navigationTitle(item.title)
                            } label: {
                                MenuRow(item: item)
                            }
                            .disabled(!item.isEnabled)
                        } else {
                            Button {
                                controller.press(item)
                                dismiss()
                            } label: {
                                MenuRow(item: item)
                            }
                            .foregroundStyle(.primary)
                            .disabled(!item.isEnabled)
                        }
                    }
                }
            }
        }
        .overlay {
            if menu.sections.isEmpty {
                ContentUnavailableView("Empty Menu", systemImage: "filemenu.and.selection",
                                       description: Text("Some menus fill in only when they're opened on the Mac."))
            }
        }
    }
}

private struct MenuRow: View {
    let item: MenuItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.accent)
                .opacity(item.isChecked ? 1 : 0)
                .accessibilityHidden(true)
            Text(item.title)
                .lineLimit(2)
            Spacer(minLength: 8)
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Shortcut \(shortcut)")
            }
        }
        .opacity(item.isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(item.isChecked ? .isSelected : [])
    }
}
