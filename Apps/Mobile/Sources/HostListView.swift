import PDClientCore
import PDProtocol
import SwiftUI

/// Home: your Macs as big cards (connect in one tap), then Macs nearby that can be paired.
struct HostListView: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @AppStorage(SettingsKey.trackpad) private var trackpad = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingLinkEntry = false
    @State private var renaming: DiscoveredHost?
    /// The Mac the file pickers and browser are for.
    @State private var filesHost: DiscoveredHost?
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var browsingFiles = false
    @State private var newName = ""

    private var paired: [DiscoveredHost] { hosts.filter(\.isPaired) }
    private var nearby: [DiscoveredHost] { hosts.filter { !$0.isPaired } }
    /// The Mac whose volume and now playing the store is watching (the one shortcuts run on).
    private var statusHostID: UUID? {
        controller.shortcutTarget(preferredHostID: UUID(uuidString: defaultMacID))?.hostID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if hosts.isEmpty {
                        SearchingCard { showingLinkEntry = true }
                    }
                    if !paired.isEmpty {
                        section("Your Macs") {
                            ForEach(paired) { host in
                                PairedMacCard(host: host,
                                              status: host.hostID != nil && host.hostID == statusHostID ? controller.store.macStatus : nil,
                                              control: { control($0, on: host) }) {
                                    if host.isOnline { controller.select(host) } else { controller.wake(host) }
                                }
                                // Lift the whole card, not just its button.
                                .contentShape(.contextMenuPreview, .rect(cornerRadius: Brand.cornerRadius))
                                .contextMenu { menu(for: host) }
                            }
                        }
                    }
                    if !nearby.isEmpty {
                        section("Nearby") {
                            ForEach(nearby) { host in
                                NearbyMacRow(host: host) { controller.select(host) }
                            }
                        }
                    }
                    SetupHint()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .animation(.smooth, value: hosts)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { AppBackground() }
            .navigationTitle("PocketDesk")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair with Link", systemImage: "link") { showingLinkEntry = true }
                }
            }
            .sendToMac(controller, hostID: filesHost?.hostID, photos: $choosingPhotos, files: $choosingFiles)
            .sheet(isPresented: $browsingFiles) {
                MacFilesBrowser(controller: controller, hostID: filesHost?.hostID) { browsingFiles = false }
            }
            .sheet(isPresented: $showingLinkEntry) {
                PairWithLinkSheet(controller: controller) { showingLinkEntry = false }
            }
            .alert("Rename Mac", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if let renaming { controller.rename(renaming, to: newName) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The name this iPhone shows. Leave it empty to use the Mac's own.")
            }
            // Live status on the card of the Mac shortcuts run on, while this tab is up and the
            // app is in front.
            .task(id: scenePhase) {
                guard scenePhase == .active else { return controller.stopWatchingStatus(watcher: "macs") }
                controller.watchStatus(preferredHostID: UUID(uuidString: defaultMacID), watcher: "macs")
            }
            .onDisappear { controller.stopWatchingStatus(watcher: "macs") }
        }
    }

    @ViewBuilder private func menu(for host: DiscoveredHost) -> some View {
        if host.isOnline, host.needsUpdate == nil {
            Button("Use in Touch Mode", systemImage: "hand.point.up.left") {
                trackpad = false
                controller.select(host)
            }
            Button("Use in Trackpad Mode", systemImage: "cursorarrow") {
                trackpad = true
                controller.select(host)
            }
        }
        if host.isOnline, host.needsUpdate == nil {
            Section {
                Button("Send Photos…", systemImage: "photo.on.rectangle") {
                    filesHost = host
                    choosingPhotos = true
                }
                Button("Send Files…", systemImage: "doc.badge.arrow.up") {
                    filesHost = host
                    choosingFiles = true
                }
                Button("Mac Files…", systemImage: "folder") {
                    filesHost = host
                    browsingFiles = true
                }
            }
        }
        Button("Rename…", systemImage: "pencil") {
            newName = host.name
            renaming = host
        }
        Button("Forget This Mac", systemImage: "trash", role: .destructive) {
            controller.forget(host)
        }
    }

    /// Play / Pause and volume from the card, without opening the stream.
    private func control(_ key: MediaKey, on host: DiscoveredHost) {
        let shortcut = Shortcut(name: key.title, symbol: key.symbol, color: .gray, action: .media(key), showsMac: false)
        controller.run(shortcut, preferredHostID: host.hostID)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            content()
        }
    }
}

private extension MediaKey {
    var title: String {
        switch self {
        case .playPause: "Play / Pause"
        case .next: "Next"
        case .previous: "Previous"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .mute: "Mute"
        }
    }

    var symbol: String {
        switch self {
        case .playPause: "playpause.fill"
        case .next: "forward.fill"
        case .previous: "backward.fill"
        case .volumeUp: "speaker.plus.fill"
        case .volumeDown: "speaker.minus.fill"
        case .mute: "speaker.slash.fill"
        }
    }
}

private struct PairedMacCard: View {
    let host: DiscoveredHost
    /// The Mac's volume and now playing, when the app is watching this one.
    let status: MacStatus?
    let control: (MediaKey) -> Void
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                MacGlyph(kind: host.kind, size: 56, status: host.glyphStatus)
                VStack(alignment: .leading, spacing: 6) {
                    Text(host.name).font(.title3.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 0) {
                        Text(state.text).foregroundStyle(state.color)
                        if let lastUsed = host.lastUsed, host.needsUpdate == nil {
                            Text(" · Used \(lastUsed, format: .relative(presentation: .named))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if host.isOnline, host.needsUpdate == nil, let status {
                LiveStatusRow(status: status, control: control)
            }
            Button(action: connect) {
                HStack(spacing: 8) {
                    if host.isWaking { ProgressView().tint(.white) }
                    Label(action.title, systemImage: action.symbol)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.accent)
            .disabled(host.needsUpdate != nil || (!host.isOnline && (!host.canWake || host.isWaking)))
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var hint: String? {
        switch host.needsUpdate {
        case .mac: return "This Mac has an older PocketDesk. Update it on the Mac to connect."
        case .phone: return "This Mac has a newer PocketDesk. Update this app to connect."
        case nil: return !host.isOnline && !host.canWake ? "Open PocketDesk on this Mac once; then you can wake it from here." : nil
        }
    }

    private var state: (text: String, color: Color) {
        if host.needsUpdate != nil { ("Needs Update", .orange) }
        else if host.isOnline { ("Online", .secondary) }
        else if host.isWaking { ("Waking…", .orange) }
        else if host.canWake { ("Asleep", .secondary) }
        else { ("Offline", .secondary) }
    }

    private var action: (title: String, symbol: String) {
        if host.needsUpdate != nil { ("Update Needed", "arrow.down.circle") }
        else if host.isOnline { ("Use This Mac", "play.fill") }
        else if host.isWaking { ("Waking…", "power") }
        else if host.canWake { ("Wake & Use", "power") }
        else { ("Not Available", "moon.zzz") }
    }
}

/// What's playing and the volume, with play/pause and volume buttons.
private struct LiveStatusRow: View {
    let status: MacStatus
    let control: (MediaKey) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.nowPlaying == nil ? "speaker.wave.2.fill" : "music.note")
                .font(.title3)
                .foregroundStyle(Brand.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.nowPlaying?.title ?? "Nothing playing")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            button(.volumeDown)
            button(.volumeUp)
            if status.nowPlaying != nil {
                button(.playPause, symbol: status.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 14))
    }

    private var detail: String {
        // Room for one: who's playing, else the volume (the buttons already say it's volume).
        let volume = status.muted == true ? "Muted" : status.volume.map { "Volume \($0)%" }
        return status.nowPlaying?.artist ?? volume ?? ""
    }

    private func button(_ key: MediaKey, symbol: String? = nil) -> some View {
        Button { control(key) } label: {
            Image(systemName: symbol ?? key.symbol)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(key.title)
    }
}

private struct NearbyMacRow: View {
    let host: DiscoveredHost
    let pair: () -> Void

    var body: some View {
        Button(action: pair) {
            HStack(spacing: 14) {
                MacGlyph(kind: host.kind, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(host.needsUpdate == nil ? "Ready to pair" : "Needs an update to pair")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("Pair")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.tint(Brand.accent.opacity(0.25)), in: .capsule)
            }
        }
        .buttonStyle(.plain)
        .disabled(host.needsUpdate != nil)
        .card(interactive: true)
    }
}

/// Shown until the first Mac appears; after a while, what usually fixes it.
private struct SearchingCard: View {
    let pairWithLink: () -> Void
    @State private var showsHelp = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Brand.accent)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
            Text("Looking for your Mac").font(.title3.weight(.semibold))
            Text("Make sure PocketDesk is open on your Mac and both are on the same Wi-Fi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsHelp {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Still nothing?").font(.subheadline.weight(.semibold))
                    tip("lock.shield", "Allow Local Network for PocketDesk in Settings › Privacy & Security on this iPhone.")
                    tip("wifi", "Check both are on the same Wi-Fi network, not a guest network.")
                    tip("menubar.rectangle", "Look for the PocketDesk icon in the Mac's menu bar.")
                    Button("Pair with a Link Instead", systemImage: "link", action: pairWithLink)
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    Button("Open Settings", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .card()
        .task {
            try? await Task.sleep(for: .seconds(10))
            withAnimation(.smooth) { showsHelp = true }
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(.footnote).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Brand.accent)
        }
    }
}

private struct SetupHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.title3)
                .foregroundStyle(Brand.accent)
            Text("New Mac? Open PocketDesk from its menu bar icon and choose **Pair a Phone…**")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
