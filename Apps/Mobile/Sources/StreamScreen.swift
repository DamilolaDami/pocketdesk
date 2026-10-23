import PDClientCore
import PDProtocol
import SwiftUI
import UniformTypeIdentifiers

/// The Mac, edge to edge, with a floating glass control bar that tucks away.
struct StreamScreen: View {
    let controller: SessionController
    let hostName: String
    let config: StreamConfig
    @State private var keyboardShown = false
    @State private var showingWindows = false
    @State private var showingDisplays = false
    @State private var showingShortcuts = false
    @State private var showingMenus = false
    @State private var choosingPhotos = false
    @State private var choosingFiles = false
    @State private var browsingFiles = false
    @AppStorage(SettingsKey.startInLandscape) private var startInLandscape = false
    @AppStorage(SettingsKey.showStreamInfo) private var showStreamInfo = true
    @AppStorage(SettingsKey.shareClipboard) private var shareClipboard = true
    @AppStorage(SettingsKey.trackpad) private var trackpad = false
    @AppStorage(SettingsKey.streamQuality) private var quality = StreamQuality.best
    @AppStorage(SettingsKey.hideInSwitcher) private var hideInSwitcher = true
    @AppStorage(SettingsKey.keyboardOnOpen) private var keyboardOnOpen = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var controlsExpanded = true
    @State private var showsStatus = true
    /// The on-screen keyboard is up (not just the key bar a hardware keyboard leaves).
    @State private var softKeyboardUp = false
    @Namespace private var glass

    var body: some View {
        GeometryReader { geometry in
            stream(isLandscape: geometry.size.width > geometry.size.height)
        }
        // Not the keyboard's: the control bar rides above the keyboard and its key bar.
        .ignoresSafeArea(.container)
        // The app switcher shows a snapshot of the screen: not the Mac's, if asked.
        .overlay {
            if hideInSwitcher, scenePhase != .active {
                PrivacyCover(hostName: hostName)
            }
        }
        .onAppear { if keyboardOnOpen { keyboardShown = true } }
    }

    private func stream(isLandscape: Bool) -> some View {
        StreamView(controller: controller, videoSize: CGSize(width: config.width, height: config.height),
                   trackpad: trackpad, keyboardShown: $keyboardShown)
            .ignoresSafeArea()
            .background(.black)
            .overlay(alignment: .topLeading) {
                if showsStatus && showStreamInfo {
                    StatusChip(hostName: hostName, config: config, link: controller.store.link,
                               quality: controller.store.quality)
                        .padding(.leading, 16)
                        .padding(.top, topInset)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                // Shown whatever the stream-info setting: it explains a softer picture.
                if controller.store.link?.isWeak == true {
                    WeakConnectionPill()
                        .padding(.top, topInset + 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: controller.store.link?.isWeak)
            .overlay(alignment: .bottom) {
                // While typing, the key bar's own button puts the keyboard away.
                if !softKeyboardUp {
                    controls(isLandscape: isLandscape).padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let screen = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.bounds ?? .zero
                // The key bar alone is ~56 pt; the keyboard is several times that.
                let up = screen.intersection(frame).height > 150
                if up != softKeyboardUp { withAnimation(.smooth) { softKeyboardUp = up } }
            }
            .persistentSystemOverlays(.hidden)
            .statusBarHidden()
            .onAppear {
                Orientation.allowLandscape(true)
                if startInLandscape { rotate(toLandscape: true) }
            }
            .onChange(of: quality) { controller.qualityChanged() }
            .task(id: controller.store.quality) {
                // The chip confirms what you're looking at (again after a quality change), then
                // gets out of the way.
                withAnimation(.smooth) { showsStatus = true }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth) { showsStatus = false }
            }
            // The other screens are designed for portrait; don't leave the phone stuck sideways.
            .onDisappear { Orientation.allowLandscape(false) }
            .sheet(isPresented: $showingDisplays) {
                DisplayPicker(controller: controller) { showingDisplays = false }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingWindows) {
                WindowPicker(controller: controller) { showingWindows = false }
                    .presentationDetents([.medium, .large])
            }
            .sendToMac(controller, hostID: nil, photos: $choosingPhotos, files: $choosingFiles)
            .sheet(isPresented: $browsingFiles) {
                MacFilesBrowser(controller: controller, hostID: nil) { browsingFiles = false }
            }
            .sheet(isPresented: $showingMenus) {
                MenusSheet(controller: controller) { showingMenus = false }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingShortcuts) {
                ShortcutsSheet(controller: controller) { showingShortcuts = false }
                    .presentationDetents([.medium, .large])
            }
    }

    /// What's used all the time stays out; the rest (paste included) lives in More,
    /// like a media player's controls. Hidden, it shrinks to one button.
    private func controls(isLandscape: Bool) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if controlsExpanded {
                    control("Keyboard", keyboardShown ? "keyboard.chevron.compact.down.fill" : "keyboard") {
                        keyboardShown.toggle()
                    }
                    // Shows the mode you're in; tap to switch.
                    control(trackpad ? "Trackpad Mode" : "Touch Mode", trackpad ? "cursorarrow" : "hand.point.up.left",
                            id: "Mode") {
                        trackpad.toggle()
                    }
                    control("Menus", "filemenu.and.selection") { showingMenus = true }
                    control("Shortcuts", "square.grid.2x2.fill") { showingShortcuts = true }
                    control("Windows", "macwindow.on.rectangle") {
                        controller.refreshWindows()
                        showingWindows = true
                    }
                    moreMenu(isLandscape: isLandscape)
                } else {
                    control("Show Controls", "slider.horizontal.3") {
                        withAnimation(.bouncy) { controlsExpanded = true }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func moreMenu(isLandscape: Bool) -> some View {
        Menu {
            if shareClipboard {
                Section {
                    // The system paste button reads the clipboard without iOS's "Allow Paste"
                    // prompt (the tap is the consent), and in a menu it looks like any item.
                    PasteButton(supportedContentTypes: [.plainText, .image]) { providers in
                        Task { @MainActor in
                            if let item = await ClipboardItem(providers) { controller.sendClipboard(item) }
                        }
                    }
                }
            }
            Section {
                Picker(selection: $quality) {
                    ForEach(StreamQuality.allCases, id: \.self) { Text($0.name).tag($0) }
                } label: {
                    Label("Quality: \(controller.store.quality.name)", systemImage: "sparkles.tv")
                }
                .pickerStyle(.menu)
            }
            Section {
                Button("Send Photos…", systemImage: "photo.on.rectangle") { choosingPhotos = true }
                Button("Send Files…", systemImage: "doc.badge.arrow.up") { choosingFiles = true }
                Button("Mac Files…", systemImage: "folder") { browsingFiles = true }
            }
            Section {
                // Not used often enough for the bar, which needs the room for Menus.
                Button("Displays", systemImage: "display.2") { showingDisplays = true }
                Button(isLandscape ? "Portrait" : "Landscape",
                       systemImage: isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                    rotate(toLandscape: !isLandscape)
                }
            }
            Button("Hide Controls", systemImage: "chevron.down") {
                withAnimation(.bouncy) { controlsExpanded = false }
            }
            Section {
                Button("Disconnect", systemImage: "xmark", role: .destructive) { controller.disconnect() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID("More", in: glass)
        .accessibilityLabel("More")
    }

    /// The stream ignores the safe area; overlays still have to clear the Dynamic Island.
    private var topInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.keyWindow?.safeAreaInsets.top ?? 0
    }

    /// A Mac display fits a landscape phone far better; this flips without needing the
    /// phone's rotation lock off.
    private func rotate(toLandscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: toLandscape ? .landscapeRight : .portrait))
    }

    private func control(_ title: String, _ symbol: String, tint: Color? = nil, id: String? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(id ?? title, in: glass)
        .accessibilityLabel(title)
    }
}

private struct WeakConnectionPill: View {
    var body: some View {
        Label("Weak connection", systemImage: "wifi.exclamationmark")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
            .accessibilityHint("The picture is reduced to keep up with the network.")
    }
}

private struct StatusChip: View {
    let hostName: String
    let config: StreamConfig
    let link: LinkQuality?
    let quality: StreamQuality

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(link?.isWeak == true ? Color.orange : Brand.online).frame(width: 8, height: 8)
            Text(hostName).font(.footnote.weight(.semibold)).lineLimit(1)
            Text("\(config.width)×\(config.height) · \(link?.fps ?? config.fps) fps\(quality == .best ? "" : " · \(quality.name)")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Stream the whole display or one window (fitted to the phone).
struct WindowPicker: View {
    let controller: SessionController
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        controller.selectSource(nil)
                        dismiss()
                    } label: {
                        Label("Whole Display", systemImage: "display")
                    }
                }
                Section("Windows") {
                    ForEach(controller.store.windows) { window in
                        Button {
                            controller.selectSource(window)
                            dismiss()
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(window.title.isEmpty ? window.appName : window.title).lineLimit(1)
                                    Text(window.appName).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "macwindow")
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .overlay {
                if controller.store.windows.isEmpty { ProgressView() }
            }
            .navigationTitle("Show on Phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: dismiss)
                }
            }
        }
    }
}


/// Stands in for the Mac's screen while PocketDesk isn't in front.
private struct PrivacyCover: View {
    let hostName: String

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            VStack(spacing: 10) {
                Image(systemName: "lock.display")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(hostName).font(.headline)
                Text("Hidden while PocketDesk is in the background").font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding()
        }
        .ignoresSafeArea()
    }
}
