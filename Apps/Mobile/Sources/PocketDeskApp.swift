import PDClientCore
import SwiftUI

@main
struct PocketDeskApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        switch session.state {
        case .idle, .failed:
            ContentUnavailableView {
                Label("PocketDesk", systemImage: "desktopcomputer")
            } description: {
                Text("Open PocketDesk on your Mac, then find it here.")
            } actions: {
                Button("Find my Mac") { session.send(.startDiscovery) }
                    .buttonStyle(.glassProminent)
            }
        case .discovering(let hosts):
            List(hosts) { host in
                Button(host.name) { session.send(.select(host)) }
            }
            .overlay { if hosts.isEmpty { ProgressView("Looking for Macs…") } }
        case .pairing(_, let code):
            Text(code.map { "Confirm code \($0) on your Mac" } ?? "Pairing…")
        case .connecting(let host):
            ProgressView("Connecting to \(host.name)…")
        case .streaming:
            Text("Stream view goes here")
        }
    }
}
