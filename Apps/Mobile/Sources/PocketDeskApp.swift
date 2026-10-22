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
        .animation(.smooth(duration: 0.35), value: phase)
        .sensoryFeedback(.success, trigger: isStreaming) { _, streaming in streaming }
        .task { controller.startDiscovery() }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .idle:
            // Discovery starts on appear; show the searching state rather than a blank screen.
            HostListView(controller: controller, hosts: [])
        case .discovering(let hosts):
            HostListView(controller: controller, hosts: hosts)
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

    private var isStreaming: Bool {
        if case .streaming = state { true } else { false }
    }

    /// Animates only between screens, not on every in-screen state change.
    private var phase: Int {
        switch state {
        case .idle: 0
        case .discovering: 1
        case .pairing: 2
        case .connecting: 3
        case .streaming: 4
        case .failed: 5
        }
    }
}
