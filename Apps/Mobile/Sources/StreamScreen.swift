import PDClientCore
import PDProtocol
import SwiftUI

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

    private func controls(isLandscape: Bool) -> some View {
        GlassEffectContainer(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    if controlsExpanded {
                        control(isLandscape ? "Portrait" : "Landscape",
                                isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                            rotate(toLandscape: !isLandscape)
                        }
                        control("Keyboard", keyboardShown ? "keyboard.chevron.compact.down.fill" : "keyboard") {
                            keyboardShown.toggle()
                        }
                        control("Shortcuts", "square.grid.2x2.fill") { showingShortcuts = true }
                        control("Displays", "display.2") { showingDisplays = true }
                        control("Windows", "macwindow.on.rectangle") {
                            controller.refreshWindows()
                            showingWindows = true
                        }
                        control("Disconnect", "xmark", tint: .red) { controller.disconnect() }
                    }
                    control(controlsExpanded ? "Hide Controls" : "Show Controls",
                            controlsExpanded ? "chevron.down" : "slider.horizontal.3") {
                        withAnimation(.bouncy) { controlsExpanded.toggle() }
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: controlsExpanded ? 450 : 72)
        }
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
