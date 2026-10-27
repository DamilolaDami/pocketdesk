import PDClientCore
import PDProtocol
import SwiftUI

/// One paired Mac: its name, its lock, what this iPhone knows about it, and forgetting it.
struct MacSettingsView: View {
    let controller: SessionController
    let hostID: UUID
    @State private var name = ""
    @State private var confirmingForget = false
    @Environment(\.dismiss) private var dismiss

    private var host: DiscoveredHost? {
        guard case .discovering(let hosts) = controller.store.state else { return nil }
        return hosts.first { $0.hostID == hostID }
    }

    var body: some View {
        Group {
            if let host {
                form(host)
            } else {
                ContentUnavailableView("Mac Not Found", systemImage: "laptopcomputer.slash",
                                       description: Text("It may have been forgotten."))
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle(host?.name ?? "Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = host?.name ?? "" }
    }

    private func form(_ host: DiscoveredHost) -> some View {
        let pairing = controller.pairing(of: host)
        return Form {
            Section {
                VStack(spacing: 12) {
                    MacPreview(kind: host.kind, wallpaper: controller.store.wallpapers[hostID],
                               status: host.glyphStatus, height: 110)
                    Text(host.name).font(.title3.weight(.semibold))
                    Text(statusText(host)).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)

            Section {
                TextField(pairing?.macName ?? "Name", text: $name)
                    .submitLabel(.done)
                    .onSubmit { controller.rename(host, to: name) }
            } header: {
                Text("Name")
            } footer: {
                Text("The name this iPhone shows. Leave it empty to use the Mac's own\(pairing.map { ", “\($0.macName)”" } ?? "").")
            }

            Section {
                Toggle(isOn: Binding(get: { host.isLocked },
                                     set: { locked in Task { await controller.setLocked(host, locked) } })) {
                    Label("Lock with \(DeviceOwner.method)", systemImage: DeviceOwner.symbol)
                }
                if let pairing {
                    LabeledContent("Security Key") {
                        Text(pairing.key).font(.body.monospaced())
                    }
                    LabeledContent("Paired", value: pairing.pairedAt.formatted(date: .abbreviated, time: .omitted))
                }
            } header: {
                Text("Security")
            } footer: {
                Text("A locked Mac asks for \(DeviceOwner.method) before it can be used from this iPhone. The security key is the Mac's, pinned when you paired: PocketDesk only connects to a Mac that presents it.")
            }

            Section {
                Button("Update PocketDesk on Mac…", systemImage: "arrow.down.circle") { controller.showHostUpdate(host) }
                    .disabled(!host.isOnline && !host.canRelay)
            }
            Section("This iPhone") {
                LabeledContent("Last Used") {
                    Text(host.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                }
                LabeledContent("Wake from Sleep") {
                    Text(host.canWake ? "Ready" : "After First Connection")
                }
                if let kind = host.kind {
                    LabeledContent("Kind", value: kind.title)
                }
            }

            Section {
                Button("Forget This Mac", role: .destructive) { confirmingForget = true }
            } footer: {
                Text("It will need pairing again, and its shortcuts run on another Mac.")
            }
        }
        .confirmationDialog("Forget “\(host.name)”?", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("Forget This Mac", role: .destructive) {
                controller.forget(host)
                dismiss()
            }
        } message: {
            Text("You'll need to pair with it again to use it from this iPhone.")
        }
    }

    private func statusText(_ host: DiscoveredHost) -> String {
        if host.needsUpdate == .mac { return "Needs a newer PocketDesk on the Mac" }
        if host.needsUpdate == .phone { return "Needs a newer PocketDesk on this iPhone" }
        if host.isOnline { return host.needsUnlock ? "Online · Locked" : "Online" }
        if host.isWaking { return "Waking…" }
        return host.canWake ? "Asleep" : "Offline"
    }
}

extension MacKind {
    var title: String {
        switch self {
        case .laptop: "MacBook"
        case .imac: "iMac"
        case .mini: "Mac mini"
        case .studio: "Mac Studio"
        case .pro: "Mac Pro"
        case .desktop: "Mac"
        }
    }
}
