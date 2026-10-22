import PDClientCore
import SwiftUI

/// Macs found over Bonjour: paired ones connect on tap, new ones start pairing.
struct HostListView: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    @State private var showingLinkEntry = false

    var body: some View {
        NavigationStack {
            List {
                let paired = hosts.filter(\.isPaired)
                let nearby = hosts.filter { !$0.isPaired }
                if !paired.isEmpty {
                    Section("Your Macs") {
                        ForEach(paired) { host in
                            row(host, subtitle: "Tap to connect", symbol: "desktopcomputer")
                                .swipeActions {
                                    Button("Forget", role: .destructive) { controller.forget(host) }
                                }
                        }
                    }
                }
                Section {
                    ForEach(nearby) { host in
                        row(host, subtitle: "Tap to pair", symbol: "desktopcomputer.and.arrow.down")
                    }
                } header: {
                    Text("Nearby")
                } footer: {
                    Text("Open PocketDesk on your Mac and choose “Pair a Phone…” from its menu bar icon.")
                }
            }
            .overlay {
                if hosts.isEmpty {
                    ContentUnavailableView {
                        Label("Looking for Macs…", systemImage: "wifi")
                    } description: {
                        Text("Make sure PocketDesk is running on your Mac and both are on the same Wi-Fi.")
                    }
                }
            }
            .navigationTitle("PocketDesk")
            .toolbar {
                Button("Pair with Link", systemImage: "link") { showingLinkEntry = true }
            }
            .sheet(isPresented: $showingLinkEntry) {
                NavigationStack {
                    PairingLinkEntry(controller: controller) { showingLinkEntry = false }
                        .navigationTitle("Pair with Link")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium])
            }
        }
    }

    private func row(_ host: DiscoveredHost, subtitle: String, symbol: String) -> some View {
        Button {
            controller.select(host)
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(host.name).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol)
            }
        }
    }
}
