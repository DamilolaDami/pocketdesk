import PDClientCore
import PDProtocol
import SwiftUI

/// One-tap actions on the Mac, as colorful tiles like the Shortcuts app. Tapping connects if
/// needed and runs the action as soon as the picture is up.
struct ShortcutsView: View {
    let controller: SessionController
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @Environment(\.scenePhase) private var scenePhase
    /// One sheet for both steps: swapping its item moves from the picks to the editor
    /// (presenting a second sheet as the first closes is unreliable).
    @State private var sheet: EditorSheet?

    private var shortcuts: [Shortcut] { controller.store.shortcuts }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TargetMacPill(mac: targetMac)
                    if shortcuts.isEmpty {
                        EmptyShortcuts { sheet = .picks }
                    } else {
                        ShortcutGrid(controller: controller, shortcuts: shortcuts, edit: { sheet = .editor(.editing($0)) }) {
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
                    Button("New Shortcut", systemImage: "plus") { sheet = .picks }
                }
            }
            // Real icons for app tiles; also warms the editor's app list.
            .task { controller.loadApps(preferredHostID: UUID(uuidString: defaultMacID)) }
            // Live tiles: only while this screen is up and the app is in front.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return controller.stopWatchingStatus() }
                controller.watchStatus(preferredHostID: UUID(uuidString: defaultMacID))
            }
            .onDisappear { controller.stopWatchingStatus() }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .picks:
                    QuickPicksSheet(controller: controller, pick: { self.sheet = .editor(.from($0)) },
                                    pickMacShortcut: { self.sheet = .editor(.from($0)) },
                                    startFromScratch: { self.sheet = .editor(.new()) })
                case .editor(let draft):
                    ShortcutEditor(controller: controller, draft: draft, save: controller.save,
                                   delete: draft.isNew ? nil : { controller.delete(draft.shortcut) })
                }
            }
        }
    }

    private var targetMac: DiscoveredHost? {
        controller.shortcutTarget(preferredHostID: UUID(uuidString: defaultMacID))
    }
}

private enum EditorSheet: Identifiable {
    case picks
    case editor(ShortcutDraft)

    var id: String {
        switch self {
        case .picks: "picks"
        case .editor(let draft): draft.id.uuidString
        }
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
                             status: controller.store.macStatus,
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
    /// The Mac's volume and now playing, for tiles that show it live.
    var status: MacStatus?
    var edit: (() -> Void)?
    var run: () -> Void = {}
    @State private var favicon: UIImage?

    private var website: String? {
        shortcut.action.website
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
                Text(live?.line ?? shortcut.action.summary)
                    .font(.caption.weight(.medium))
                    .opacity(0.75)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.smooth, value: live?.line)
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
            Image(systemName: live?.symbol ?? shortcut.symbol)
                .font(.system(size: 24, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    /// What the Mac is doing, for tiles where that's the point: what's playing on Play / Pause,
    /// the level on volume tiles.
    var live: (line: String, symbol: String?)? {
        guard let status else { return nil }
        switch shortcut.action {
        case .media(.playPause):
            guard let playing = status.nowPlaying else { return nil }
            let line = [playing.title, playing.artist].compactMap(\.self).joined(separator: " · ")
            return (line, playing.isPlaying ? "pause.fill" : "play.fill")
        case .media(.volumeUp), .media(.volumeDown), .media(.mute), .setVolume:
            if status.muted == true { return ("Muted", nil) }
            return status.volume.map { ("Volume \($0)%", nil) }
        default:
            return nil
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
            // While streaming this asks over the stream itself; the Mac keeps it up to date.
            .task { controller.watchStatus(preferredHostID: nil) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: dismiss)
                }
            }
        }
    }
}
