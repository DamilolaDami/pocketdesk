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
                                let watched = host.hostID != nil && host.hostID == statusHostID
                                PairedMacCard(host: host,
                                              status: watched ? controller.store.macStatus : nil,
                                              latency: watched ? controller.store.macLatency : nil,
                                              wallpaper: host.hostID.flatMap { controller.store.wallpapers[$0] },
                                              openOnMac: { open($0, on: host) },
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

    /// The playing app, brought forward on the Mac without opening the stream.
    private func open(_ app: PlayerApp, on host: DiscoveredHost) {
        let shortcut = Shortcut(name: app.name, symbol: "play.square.stack", color: .gray,
                                action: .openApp(bundleID: app.bundleID, name: app.name), showsMac: false)
        controller.run(shortcut, preferredHostID: host.hostID)
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
    /// The Mac's volume, battery and now playing, when the app is watching this one.
    let status: MacStatus?
    /// The last round trip to it, likewise.
    let latency: Duration?
    /// Its desktop picture, as last seen.
    let wallpaper: Data?
    let openOnMac: (PlayerApp) -> Void
    let control: (MediaKey) -> Void
    let connect: () -> Void
    @AppStorage("macCardPlayerExpanded") private var playerExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                MacPreview(kind: host.kind, wallpaper: wallpaper, status: host.glyphStatus, height: 48)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if host.isOnline, host.needsUpdate == nil {
                            Circle().fill(Brand.online).frame(width: 9, height: 9)
                        }
                        Text(host.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 0) {
                        if host.needsUpdate == nil, !host.isOnline, host.canWake, !host.isWaking {
                            Image(systemName: "moon.zzz.fill").padding(.trailing, 4)
                        }
                        Text(state.text)
                        if let lastUsed = host.lastUsed, host.needsUpdate == nil {
                            Text(" · Used \(lastUsed, format: .relative(presentation: .named))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(state.color)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 0)
            }
            if live {
                MacVitals(latency: latency, battery: status?.battery)
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
            if live, let status {
                LiveStatusRow(status: status, expanded: $playerExpanded, openOnMac: openOnMac, control: control)
            }
        }
        .card()
        .animation(.smooth, value: playerExpanded)
        .animation(.smooth, value: status == nil)
    }

    /// Online, current, and the one being watched.
    private var live: Bool { host.isOnline && host.needsUpdate == nil && status != nil }

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
        else if host.canWake { ("Asleep", .indigo) }
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

/// The link and the battery, at a glance.
private struct MacVitals: View {
    let latency: Duration?
    let battery: MacBattery?

    var body: some View {
        HStack(spacing: 8) {
            if let latency {
                let grade = ConnectionGrade(latency: latency)
                vital(Image(systemName: "wifi", variableValue: grade.bars),
                      "\(grade.title) · \(latency.latencyText)",
                      color: grade == .poor ? .orange : .primary)
                    .accessibilityLabel("Connection \(grade.title), \(latency.latencyText) round trip")
            } else {
                vital(Image(systemName: "wifi"), "Measuring…", color: .secondary)
            }
            if let battery {
                vital(Image(systemName: battery.symbol), "\(battery.level)%",
                      color: battery.isLow ? .red : battery.isCharging ? .green : .primary)
                    .accessibilityLabel("Battery \(battery.text)")
            }
            Spacer(minLength: 0)
        }
    }

    private func vital(_ icon: Image, _ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            icon.foregroundStyle(color)
            Text(text).foregroundStyle(.secondary).contentTransition(.numericText())
        }
        .font(.footnote.weight(.medium).monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// What's playing (with its cover when the player has one): play / pause at hand, and the
/// rest of the controls a tap away so the card's main button stays the main thing.
private struct LiveStatusRow: View {
    let status: MacStatus
    @Binding var expanded: Bool
    let openOnMac: (PlayerApp) -> Void
    let control: (MediaKey) -> Void
    @Environment(\.openURL) private var openURL
    @State private var choosingWhere = false

    var body: some View {
        VStack(spacing: 12) {
            if let app = status.nowPlaying?.app {
                PlayerSource(app: app) { choosingWhere = true }
                    .confirmationDialog("Open \(app.name)", isPresented: $choosingWhere, titleVisibility: .visible) {
                        if let url = app.phoneURL.flatMap(URL.init(string:)) {
                            Button("On This iPhone") {
                                openURL(url) { opened in
                                    if !opened { openOnMac(app) }
                                }
                            }
                        }
                        Button("On Your Mac") { openOnMac(app) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(app.phoneURL == nil ? "Bring \(app.name) to the front on your Mac."
                                                 : "Carry on in \(app.name) here, or bring it to the front on your Mac.")
                    }
            }
            HStack(spacing: 12) {
                Artwork(nowPlaying: status.nowPlaying)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.nowPlaying?.title ?? "Nothing playing")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                if status.nowPlaying != nil {
                    button(.playPause, symbol: status.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill")
                }
                Button { expanded.toggle() } label: {
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .frame(width: 32, height: 40)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Fewer Controls" : "More Controls")
            }
            if expanded {
                HStack {
                    button(.volumeDown)
                    Spacer(minLength: 0)
                    button(.mute, symbol: status.muted == true ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    Spacer(minLength: 0)
                    if status.nowPlaying != nil {
                        button(.previous)
                        Spacer(minLength: 0)
                        button(.next)
                        Spacer(minLength: 0)
                    }
                    button(.volumeUp)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
    }

    private var detail: String {
        let volume = status.muted == true ? "Muted" : status.volume.map { "Volume \($0)%" }
        return [status.nowPlaying?.artist, volume].compactMap(\.self).joined(separator: " · ")
    }

    private func button(_ key: MediaKey, symbol: String? = nil) -> some View {
        Button { control(key) } label: {
            Image(systemName: symbol ?? key.symbol)
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(key.title)
    }
}

/// "Playing in Spotify", with the app's icon: tap to open it.
private struct PlayerSource: View {
    let app: PlayerApp
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                if let icon = app.icon.flatMap({ Data(base64Encoded: $0) }).flatMap(UIImage.init(data:)) {
                    Image(uiImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.fill").foregroundStyle(.secondary).frame(width: 20, height: 20)
                }
                (Text("Playing in ").foregroundStyle(.secondary) + Text(app.name).fontWeight(.semibold))
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.app")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.accent)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Playing in \(app.name)")
        .accessibilityHint("Opens \(app.name) on this iPhone or on your Mac.")
    }
}

/// The cover the Mac sent, else a quiet note tile.
private struct Artwork: View {
    let nowPlaying: NowPlaying?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: nowPlaying == nil ? "speaker.wave.2.fill" : "music.note")
                    .font(.title3)
                    .foregroundStyle(Brand.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.accent.opacity(0.12))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(.rect(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }

    private var image: UIImage? {
        nowPlaying?.artwork.flatMap { Data(base64Encoded: $0) }.flatMap(UIImage.init(data:))
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
