import PDClientCore
import SwiftUI

@main
struct PocketDeskApp: App {
    @State private var controller = SessionController()

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller)
                .tint(Brand.accent)
                .onOpenURL { url in try? controller.pair(using: url) }
        }
    }
}

struct RootView: View {
    let controller: SessionController
    @Environment(\.displayScale) private var displayScale
    @AppStorage(SettingsKey.haptics) private var haptics = true

    private var state: SessionState { controller.store.state }

    var body: some View {
        GeometryReader { geometry in
            content
                .onAppear {
                    let size = geometry.size
                    controller.viewport = .init(width: size.width == 0 ? 402 : size.width,
                                                height: size.height == 0 ? 874 : size.height, scale: displayScale)
                    controller.deviceName = UIDevice.current.name
                }
        }
        .overlay(alignment: .top) {
            if let notice = controller.store.notice {
                NoticeBanner(text: notice.text)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: notice.id) {
                        try? await Task.sleep(for: .seconds(4))
                        controller.store.dismiss(notice)
                    }
                    .onTapGesture { controller.store.dismiss(notice) }
            }
        }
        .animation(.smooth(duration: 0.35), value: phase)
        .animation(.bouncy, value: controller.store.notice)
        .sensoryFeedback(trigger: isStreaming) { _, streaming in haptics && streaming ? .success : nil }
        .sensoryFeedback(trigger: controller.store.notice) { _, notice in haptics && notice != nil ? .warning : nil }
        .task { controller.startDiscovery() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle, .discovering:
            // Idle only lasts until discovery starts on appear.
            MainTabs(controller: controller, hosts: hosts)
                .transition(.opacity)
        case .pairing(let host, let code):
            NavigationStack {
                PairingView(controller: controller, host: host, code: code)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        case .connecting(let host):
            ConnectingView(hostName: host.name) { controller.disconnect() }
                .transition(.opacity)
        case .streaming(let host, let config, _):
            StreamScreen(controller: controller, hostName: host.name, config: config)
                .transition(.opacity)
        case .failed(let message):
            FailedView(message: message, canRetry: controller.lastHost?.isPaired == true,
                       retry: { controller.retry() }, back: { controller.disconnect() })
                .transition(.opacity)
        }
    }

    private var hosts: [DiscoveredHost] {
        if case .discovering(let hosts) = state { hosts } else { [] }
    }

    private var isStreaming: Bool {
        if case .streaming = state { true } else { false }
    }

    /// Animates only between screens, not on every in-screen state change.
    private var phase: Int {
        switch state {
        case .idle, .discovering: 1
        case .pairing: 2
        case .connecting: 3
        case .streaming: 4
        case .failed: 5
        }
    }
}

enum AppTab: String {
    case macs, shortcuts, settings
}

/// Home: the tab bar. Pairing, connecting and streaming take over the whole screen.
struct MainTabs: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    @SceneStorage("tab") private var tab = AppTab.macs

    var body: some View {
        TabView(selection: $tab) {
            Tab("Macs", systemImage: "laptopcomputer", value: .macs) {
                HostListView(controller: controller, hosts: hosts)
            }
            Tab("Shortcuts", systemImage: "square.grid.2x2.fill", value: .shortcuts) {
                ShortcutsView(controller: controller)
            }
            Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                SettingsView(controller: controller, hosts: hosts)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

private struct NoticeBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.medium))
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
    }
}
