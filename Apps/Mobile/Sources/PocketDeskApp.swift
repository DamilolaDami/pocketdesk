import PDClientCore
import SwiftUI

@main
struct PocketDeskApp: App {
    @State private var controller = SessionController()

    var body: some Scene {
        WindowGroup {
            RootView(controller: controller)
                .onOpenURL { url in try? controller.pair(using: url) }
        }
    }
}

struct RootView: View {
    let controller: SessionController
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            content
                .onAppear {
                    let size = geometry.size
                    controller.viewport = .init(width: min(size.width, size.height) == 0 ? 402 : size.width,
                                                height: size.height == 0 ? 874 : size.height, scale: displayScale)
                    controller.deviceName = UIDevice.current.name
                }
        }
        .task { controller.startDiscovery() }
    }

    @ViewBuilder private var content: some View {
        switch controller.store.state {
        case .idle:
            ProgressView()
        case .discovering(let hosts):
            HostListView(controller: controller, hosts: hosts)
        case .pairing(let host, let code):
            NavigationStack {
                PairingView(controller: controller, host: host, code: code)
            }
        case .connecting(let host):
            ContentUnavailableView {
                ProgressView().controlSize(.large)
            } description: {
                Text("Connecting to \(host.name)…")
            } actions: {
                Button("Cancel") { controller.disconnect() }
            }
        case .streaming(_, let config, _):
            StreamScreen(controller: controller, config: config)
        case .failed(let message):
            ContentUnavailableView {
                Label("Disconnected", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Back to Macs") { controller.disconnect() }
                    .buttonStyle(.glassProminent)
            }
        }
    }
}
