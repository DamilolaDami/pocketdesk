import PDClientCore
import PDProtocol
import SwiftUI

/// One-tap actions on the Mac, as colorful tiles like the Shortcuts app. Tapping connects if
/// needed and runs the action as soon as the picture is up.
struct ShortcutsView: View {
    let controller: SessionController
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @State private var draft: ShortcutDraft?

    private var shortcuts: [Shortcut] { controller.store.shortcuts }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TargetMacPill(mac: targetMac)
                    if shortcuts.isEmpty {
                        EmptyShortcuts { draft = .new() }
                    } else {
                        ShortcutGrid(controller: controller, shortcuts: shortcuts, edit: { draft = .editing($0) }) {
                            controller.run($0, preferredHostID: UUID(uuidString: defaultMacID))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .background { AppBackground() }
            .navigationTitle("Shortcuts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Shortcut", systemImage: "plus") { draft = .new() }
                }
            }
            // Real icons for app tiles; also warms the editor's app list.
            .task { controller.loadApps(preferredHostID: UUID(uuidString: defaultMacID)) }
            .sheet(item: $draft) { draft in
                ShortcutEditor(controller: controller, draft: draft, save: controller.save,
                               delete: draft.isNew ? nil : { controller.delete(draft.shortcut) })
            }
        }
    }

    private var targetMac: DiscoveredHost? {
        controller.shortcutTarget(preferredHostID: UUID(uuidString: defaultMacID))
    }
}

/// The two-column grid, shared with the in-stream sheet. Drag a tile onto another to reorder.
struct ShortcutGrid: View {
    let controller: SessionController
    let shortcuts: [Shortcut]
    var edit: ((Shortcut) -> Void)?
    let run: (Shortcut) -> Void
    @State private var tapped = 0

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(shortcuts) { shortcut in
                ShortcutTile(shortcut: shortcut, appIcon: shortcut.appBundleID.flatMap { controller.store.appIcons[$0] },
                             edit: edit.map { edit in { edit(shortcut) } }) {
                    tapped += 1
                    run(shortcut)
                }
                .contextMenu {
                    if let edit {
                        Button("Edit", systemImage: "slider.horizontal.3") { edit(shortcut) }
                    }
                    Button("Duplicate", systemImage: "plus.square.on.square") { controller.duplicate(shortcut) }
                    Button("Delete", systemImage: "trash", role: .destructive) { controller.delete(shortcut) }
                }
                .draggable(shortcut.id.uuidString)
                .dropDestination(for: String.self) { items, _ in
                    guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                    withAnimation(.smooth) { controller.move(id, to: shortcut.id) }
                    return true
                }
            }
        }
        .animation(.smooth, value: shortcuts)
        .sensoryFeedback(.impact(weight: .medium), trigger: tapped)
    }
}

struct ShortcutTile: View {
    let shortcut: Shortcut
    /// The Mac app's own icon (PNG), for app shortcuts.
    var appIcon: Data?
    var edit: (() -> Void)?
    var run: () -> Void = {}
    @State private var favicon: UIImage?

    private var website: String? {
        if case .openURL(let url) = shortcut.action { url } else { nil }
    }

    var body: some View {
        Button(action: run) {
            VStack(alignment: .leading, spacing: 2) {
                icon.frame(height: 38, alignment: .leading)
                Spacer(minLength: 10)
                Text(shortcut.name.isEmpty ? "Shortcut" : shortcut.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(shortcut.action.summary)
                    .font(.caption.weight(.medium))
                    .opacity(0.75)
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .background(shortcut.color.tint.gradient, in: .rect(cornerRadius: 22, style: .continuous))
            .shadow(color: shortcut.color.tint.opacity(0.3), radius: 10, y: 4)
        }
        .buttonStyle(PressableStyle())
        .task(id: website) {
            favicon = nil
            guard let website, let data = await FaviconLoader.shared.icon(for: website) else { return }
            withAnimation(.smooth) { favicon = UIImage(data: data) }
        }
        .overlay(alignment: .topTrailing) {
            if let edit {
                Button(action: edit) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.22), in: .circle)
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Edit \(shortcut.name)")
            }
        }
    }
}

extension ShortcutTile {
    /// The app's or site's own icon (sites on a white chip, like a home screen icon);
    /// otherwise the symbol.
    @ViewBuilder fileprivate var icon: some View {
        if let bundleID = shortcut.appBundleID, let appIcon,
           let image = AppIconCache.image(for: bundleID, png: appIcon) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 44, height: 44)
                .padding(-3) // macOS icons carry a transparent margin
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                .transition(.scale.combined(with: .opacity))
        } else if let favicon {
            Image(uiImage: favicon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 28, height: 28)
                .frame(width: 38, height: 38)
                .background(.white, in: .rect(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .transition(.scale.combined(with: .opacity))
        } else {
            Image(systemName: shortcut.symbol)
                .font(.system(size: 24, weight: .semibold))
        }
    }
}

/// Springs down under the finger, like a home screen icon.
private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

private struct TargetMacPill: View {
    let mac: DiscoveredHost?

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(mac == nil ? Color.gray : Brand.online).frame(width: 8, height: 8)
            if let mac {
                Text("Runs on **\(mac.name)**")
            } else {
                Text("No paired Mac online")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

private struct EmptyShortcuts: View {
    let create: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 44))
                .foregroundStyle(Brand.accent.gradient)
            Text("No shortcuts yet").font(.title3.weight(.semibold))
            Text("Open Netflix, launch an app or press a key combo on your Mac with one tap.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Shortcut", systemImage: "plus", action: create)
                .buttonStyle(.glassProminent)
                .tint(Brand.accent)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .card()
    }
}

/// The shortcuts, from the stream's control bar.
struct ShortcutsSheet: View {
    let controller: SessionController
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                ShortcutGrid(controller: controller, shortcuts: controller.store.shortcuts) { shortcut in
                    controller.run(shortcut)
                    dismiss()
                }
                .padding(20)
            }
            .navigationTitle("Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: dismiss)
                }
            }
        }
    }
}
