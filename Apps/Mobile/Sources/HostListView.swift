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
                            ForEach(paired, id: \.cardIdentity) { host in
                                let watched = host.hostID != nil && host.hostID == statusHostID
                                PairedMacCard(host: host,
                                              status: watched ? controller.store.macStatus : nil,
                                              latency: watched ? controller.store.macLatency : nil,
                                              wallpaper: host.hostID.flatMap { controller.store.wallpapers[$0] },
                                              openOnMac: { open($0, on: host) },
                                              menu: { menu(for: host) },
                                              control: { control($0, on: host) }) {
                                    // Unlocking only opens the card (player, vitals, menu); streaming is
                                    // the next tap.
                                    if host.isOnline, host.needsUnlock { Task { await controller.unlock(host) } }
                                    else if host.isOnline || host.canRelay { controller.select(host) } else { controller.wake(host) }
                                }
                                // Lift the whole card, not just its button.
                                .contentShape(.contextMenuPreview, .rect(cornerRadius: Brand.cornerRadius))
                                .contextMenu { StableMacMenuContent(host: host) { menu(for: host) }.equatable() }
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
                .animation(.smooth, value: hosts.map(\.cardIdentity))
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
            .sheet(item: Binding(get: { controller.store.hostUpdateTarget }, set: { if $0 == nil { controller.dismissHostUpdate() } })) { host in
                HostUpdateView(controller: controller, host: host)
            }
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
        if host.isPaired, host.isOnline || host.canRelay {
            Button("Update PocketDesk on Mac…", systemImage: "arrow.down.circle") { controller.showHostUpdate(host) }
        }
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
                // The system paste button reads the clipboard without iOS's "Allow Paste" prompt
                // (the tap is the consent), and in a menu it looks like any item.
                PasteButton(supportedContentTypes: [.plainText, .image]) { providers in
                    Task { @MainActor in
                        if let item = await ClipboardItem(providers) { controller.sendClipboard(item, to: host.hostID) }
                    }
                }
                Button("Copy from Mac", systemImage: "doc.on.doc") { controller.copyFromMac(host.hostID) }
            }
            Section {
                // A locked Mac asks before the picker, not after the picking.
                Button("Send Photos…", systemImage: "photo.on.rectangle") {
                    afterUnlocking(host) { choosingPhotos = true }
                }
                Button("Send Files…", systemImage: "doc.badge.arrow.up") {
                    afterUnlocking(host) { choosingFiles = true }
                }
                Button("Mac Files…", systemImage: "folder") {
                    afterUnlocking(host) { browsingFiles = true }
                }
            }
            Menu("Mac Controls", systemImage: "command") {
                ForEach(MacCommand.allCases, id: \.self) { command in
                    Button(command.menuTitle, systemImage: command.symbol) { run(command, on: host) }
                }
            }
        }
        if host.isPaired {
            Button(host.isLocked ? "Remove \(DeviceOwner.method) Lock" : "Lock with \(DeviceOwner.method)",
                   systemImage: host.isLocked ? "lock.open" : "lock") {
                Task { await controller.setLocked(host, !host.isLocked) }
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

    private func afterUnlocking(_ host: DiscoveredHost, _ then: @escaping () -> Void) {
        filesHost = host
        Task { if await controller.unlock(host) { then() } }
    }

    /// The playing app, brought forward on the Mac without opening the stream.
    private func open(_ app: PlayerApp, on host: DiscoveredHost) {
        let shortcut = Shortcut(name: app.name, symbol: "play.square.stack", color: .gray,
                                action: .openApp(bundleID: app.bundleID, name: app.name), showsMac: false)
        controller.run(shortcut, preferredHostID: host.hostID)
    }

    /// Lock, sleep and the rest, without opening the stream. Sleep asks first, as its
    /// quick pick does: it takes the Mac away.
    private func run(_ command: MacCommand, on host: DiscoveredHost) {
        let shortcut = Shortcut(name: command.menuTitle, symbol: command.symbol, color: .gray, action: .system(command),
                                showsMac: false, asksFirst: command == .sleep)
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

private struct PairedMacCard<Actions: View>: View {
    let host: DiscoveredHost
    /// The Mac's volume, battery and now playing, when the app is watching this one.
    let status: MacStatus?
    /// The last round trip to it, likewise.
    let latency: Duration?
    /// Its desktop picture, as last seen.
    let wallpaper: Data?
    let openOnMac: (PlayerApp) -> Void
    /// Everything else to do with this Mac, behind the card's ⋯ button.
    @ViewBuilder let menu: () -> Actions
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
                        if host.isLocked {
                            Image(systemName: host.needsUnlock ? "lock.fill" : "lock.open.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(host.needsUnlock ? "Locked" : "Unlocked")
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
                MacCardMenu(host: host, content: menu).equatable()
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
            .disabled(host.needsUpdate == .phone || (!host.isOnline && !host.canRelay && (!host.canWake || host.isWaking)))
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
    private var live: Bool { host.isOnline && host.needsUpdate == nil && !host.needsUnlock && status != nil }

    private var hint: String? {
        switch host.needsUpdate {
        case .mac: return "This Mac needs an update before you can connect."
        case .phone: return "This Mac has a newer PocketDesk. Update this app to connect."
        case nil: return !host.isOnline && !host.canRelay && !host.canWake ? "Open PocketDesk on this Mac once; then you can wake it from here." : nil
        }
    }

    private var state: (text: String, color: Color) {
        if host.needsUpdate != nil { ("Needs Update", .orange) }
        else if host.isOnline { ("Online", .secondary) }
        else if host.canRelay { ("Not nearby · Relay configured", .secondary) }
        else if host.isWaking { ("Waking…", .orange) }
        else if host.canWake { ("Asleep", .indigo) }
        else { ("Offline", .secondary) }
    }

    private var action: (title: String, symbol: String) {
        if host.needsUpdate == .mac { ("Update Mac", "arrow.down.circle") }
        else if host.needsUpdate == .phone { ("Update iPhone App", "arrow.down.circle") }
        else if host.isOnline, host.needsUnlock { ("Unlock", DeviceOwner.symbol) }
        else if host.isOnline { ("Use This Mac", "play.fill") }
        else if host.canRelay { ("Connect via Relay", "network") }
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
    /// The playing site's icon, when a browser is the player.
    @State private var siteIcon: UIImage?

    /// "netflix.com", when a browser is playing it.
    private var site: String? {
        status.nowPlaying?.site.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
    }

    /// Carrying on here: the site (which opens its app, if it has one), else the player's app.
    private var phoneURL: URL? {
        if let host = status.nowPlaying?.site { return URL(string: "https://\(host)") }
        return status.nowPlaying?.app?.phoneURL.flatMap(URL.init(string:))
    }

    var body: some View {
        VStack(spacing: 12) {
            if let app = status.nowPlaying?.app {
                PlayerSource(app: app, site: site, siteIcon: siteIcon) { choosingWhere = true }
                    .confirmationDialog("Open \(site ?? app.name)", isPresented: $choosingWhere, titleVisibility: .visible) {
                        if let url = phoneURL {
                            Button("On This iPhone") {
                                openURL(url) { opened in
                                    if !opened { openOnMac(app) }
                                }
                            }
                        }
                        Button("On Your Mac") { openOnMac(app) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(phoneURL == nil ? "Bring \(app.name) to the front on your Mac."
                                             : "Carry on in \(site ?? app.name) here, or bring \(app.name) to the front on your Mac.")
                    }
            }
            HStack(spacing: 12) {
                Artwork(nowPlaying: status.nowPlaying, siteIcon: siteIcon)
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
        .task(id: status.nowPlaying?.site) {
            guard let host = status.nowPlaying?.site,
                  let data = await FaviconLoader.shared.icon(for: "https://\(host)") else {
                siteIcon = nil
                return
            }
            withAnimation(.smooth) { siteIcon = UIImage(data: data) }
        }
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

/// "Playing in Spotify", with the app's icon, or "Playing netflix.com in Safari" with the
/// site's: tap to open it.
private struct PlayerSource: View {
    let app: PlayerApp
    var site: String?
    var siteIcon: UIImage?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                if let siteIcon {
                    Image(uiImage: siteIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .frame(width: 20, height: 20)
                        .background(.white, in: .rect(cornerRadius: 5, style: .continuous))
                } else if let icon = app.icon.flatMap({ Data(base64Encoded: $0) }).flatMap(UIImage.init(data:)) {
                    Image(uiImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app.fill").foregroundStyle(.secondary).frame(width: 20, height: 20)
                }
                Group {
                    if let site {
                        Text("Playing ").foregroundStyle(.secondary) + Text(site).fontWeight(.semibold)
                            + Text(" in \(app.name)").foregroundStyle(.secondary)
                    } else {
                        Text("Playing in ").foregroundStyle(.secondary) + Text(app.name).fontWeight(.semibold)
                    }
                }
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
        .accessibilityLabel(site.map { "Playing \($0) in \(app.name)" } ?? "Playing in \(app.name)")
        .accessibilityHint("Opens \(site ?? app.name) on this iPhone or on your Mac.")
    }
}

/// The cover the Mac sent, else the site's icon on white, else a quiet note tile.
private struct Artwork: View {
    let nowPlaying: NowPlaying?
    var siteIcon: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let siteIcon {
                Image(uiImage: siteIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white)
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

struct NearbyMacRow: View {
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
struct SearchingCard: View {
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

private extension MacCommand {
    var menuTitle: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .sleepDisplay: "Sleep Display"
        case .sleep: "Sleep Mac"
        case .toggleDarkMode: "Switch Dark Mode"
        case .screenshot: "Take Screenshot"
        }
    }

    var symbol: String {
        switch self {
        case .lockScreen: "lock.fill"
        case .sleepDisplay: "display"
        case .sleep: "moon.zzz.fill"
        case .toggleDarkMode: "circle.lefthalf.filled"
        case .screenshot: "camera.viewfinder"
        }
    }
}


private extension DiscoveredHost {
    // Bonjour service IDs can change on rediscovery; a paired card keeps its identity.
    var cardIdentity: String { hostID?.uuidString ?? id }
}

/// Keep the system menu out of the live status/latency render loop. Its content only
/// changes when an actual menu capability changes, never when playback or ping updates.
private struct MacMenuIdentity: Equatable {
    let id: String
    let name: String
    let online: Bool
    let paired: Bool
    let locked: Bool
    let relay: Bool
    let update: DiscoveredHost.Side?
    init(_ host: DiscoveredHost) {
        id = host.cardIdentity; name = host.name; online = host.isOnline
        paired = host.isPaired; locked = host.isLocked; relay = host.canRelay; update = host.needsUpdate
    }
}

private struct MacCardMenu<Content: View>: View, Equatable {
    let host: DiscoveredHost
    @ViewBuilder let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { MacMenuIdentity(lhs.host) == MacMenuIdentity(rhs.host) }
    var body: some View {
        Menu { StableMacMenuContent(host: host, content: content).equatable() } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .circle)
        .accessibilityLabel("More for \(host.name)")
    }
}

private struct StableMacMenuContent<Content: View>: View, Equatable {
    let host: DiscoveredHost
    @ViewBuilder let content: () -> Content
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { MacMenuIdentity(lhs.host) == MacMenuIdentity(rhs.host) }
    var body: some View { content() }
}
