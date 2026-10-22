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
    @AppStorage(SettingsKey.startInLandscape) private var startInLandscape = false
    @AppStorage(SettingsKey.showStreamInfo) private var showStreamInfo = true
    @AppStorage(SettingsKey.shareClipboard) private var shareClipboard = true
    @State private var controlsExpanded = true
    @State private var showsStatus = true
    @Namespace private var glass

    var body: some View {
        GeometryReader { geometry in
            stream(isLandscape: geometry.size.width > geometry.size.height)
        }
        .ignoresSafeArea()
    }

    private func stream(isLandscape: Bool) -> some View {
        StreamView(controller: controller, videoSize: CGSize(width: config.width, height: config.height),
                   keyboardShown: $keyboardShown)
            .ignoresSafeArea()
            .background(.black)
            .overlay(alignment: .topLeading) {
                if showsStatus && showStreamInfo {
                    StatusChip(hostName: hostName, config: config, link: controller.store.link)
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
            .overlay(alignment: .bottom) { controls(isLandscape: isLandscape).padding(.bottom, 10) }
            .persistentSystemOverlays(.hidden)
            .statusBarHidden()
            .onAppear { if startInLandscape { rotate(toLandscape: true) } }
            .task {
                // The chip confirms what you're looking at, then gets out of the way.
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.smooth) { showsStatus = false }
            }
            // The other screens are designed for portrait; don't leave the phone stuck sideways.
            .onDisappear { rotate(toLandscape: false) }
            .sheet(isPresented: $showingDisplays) {
                DisplayPicker(controller: controller) { showingDisplays = false }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingWindows) {
                WindowPicker(controller: controller) { showingWindows = false }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showingShortcuts) {
                ShortcutsSheet(controller: controller) { showingShortcuts = false }
                    .presentationDetents([.medium, .large])
            }
    }

    /// The few things used all the time stay out; the rest live in More, like a media
    /// player's controls. Hidden, it shrinks to one button.
    private func controls(isLandscape: Bool) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if controlsExpanded {
                    control("Keyboard", keyboardShown ? "keyboard.chevron.compact.down.fill" : "keyboard") {
                        keyboardShown.toggle()
                    }
                    control("Shortcuts", "square.grid.2x2.fill") { showingShortcuts = true }
                    if shareClipboard {
                        // The system paste button reads the clipboard without iOS's
                        // "Allow Paste" prompt, because the tap itself is the consent.
                        PasteButton(supportedContentTypes: [.plainText, .image]) { providers in
                            Task { @MainActor in
                                if let item = await ClipboardItem(providers) { controller.sendClipboard(item) }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.circle)
                        .tint(Color(white: 0.2))
                        .foregroundStyle(.white)
                        .controlSize(.large)
                        .accessibilityLabel("Paste to Mac")
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
            Section {
                Button(isLandscape ? "Portrait" : "Landscape",
                       systemImage: isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                    rotate(toLandscape: !isLandscape)
                }
                Button("Displays", systemImage: "display.2") { showingDisplays = true }
                Button("Windows", systemImage: "macwindow.on.rectangle") {
                    controller.refreshWindows()
                    showingWindows = true
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

    private func control(_ title: String, _ symbol: String, tint: Color? = nil,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint ?? .primary)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .glassEffectID(title, in: glass)
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

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(link?.isWeak == true ? Color.orange : Brand.online).frame(width: 8, height: 8)
            Text(hostName).font(.footnote.weight(.semibold)).lineLimit(1)
            Text("\(config.width)×\(config.height) · \(link?.fps ?? config.fps) fps")
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

private extension ClipboardItem {
    /// The first text or image the paste button handed over; images go as PNG.
    init?(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                let text: String? = await withCheckedContinuation { done in
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in done.resume(returning: object as? String) }
                }
                if let text {
                    self.init(text: text)
                    return
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data: Data = await withCheckedContinuation({ done in
                   _ = provider.loadDataRepresentation(for: .image) { data, _ in done.resume(returning: data) }
               }),
               let png = UIImage(data: data)?.pngData() {
                self.init(png: png.base64EncodedString())
                return
            }
        }
        return nil
    }
}
