import PDClientCore
import PDProtocol
import SwiftUI

struct HostUpdateView: View {
    let controller: SessionController
    let host: DiscoveredHost
    @State private var attempt = 0
    @State private var confirming = false
    private var status: HostUpdateStatus? { controller.store.hostUpdateStatus }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 46)).foregroundStyle(Brand.accent)
                        Text("Update \(host.name)").font(.title2.bold())
                        Text(title).font(.subheadline).foregroundStyle(.secondary)
                        if let progress = status?.progress { ProgressView(value: progress) }
                        else if status == nil || status?.isBusy == true { ProgressView() }
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    if let status, !status.version.isEmpty {
                        LabeledContent("Mac version", value: "\(status.version) (\(status.build))")
                    }
                    if let message = status?.message { Text(message).font(.subheadline).foregroundStyle(.secondary) }
                }
                if status?.phase == .idle || status?.phase == .failed || status?.phase == .upToDate {
                    Section {
                        Button("Download & Restart Mac Host", systemImage: "arrow.down.circle") { confirming = true }
                    } footer: {
                        Text("Installs the latest signed PocketDesk update. The Mac host will restart and active sessions will disconnect.")
                    }
                }
                if status?.phase == .unavailable {
                    Section {
                        Link("Download for Mac", destination: URL(string: "https://pocketdesk.runmira.dev/")!)
                    }
                }
            }
            .navigationTitle("Mac Update").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { controller.dismissHostUpdate() } } }
            .confirmationDialog("Update PocketDesk on \(host.name)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Download & Restart") { attempt += 1 }
            } message: { Text("This ends active PocketDesk sessions. Your Mac stays on and your apps stay open.") }
            .task(id: attempt) { await controller.watchHostUpdate(host, install: attempt > 0) }
        }
        .tint(Brand.accent)
    }
    private var title: String {
        guard let status else { return "Connecting securely to your Mac…" }
        switch status.phase {
        case .idle:
            if status.hostProtocol > protocolVersion { return "Update the iPhone app to connect" }
            return status.hostProtocol == protocolVersion ? "Ready to check for updates" : "A Mac update is needed to connect"
        case .checking: return "Checking for an update…"
        case .downloading: return "Downloading update…"
        case .installing: return "Installing and reconnecting…"
        case .upToDate: return "Latest published version installed"
        case .unavailable: return "Update on the Mac first"
        case .failed: return "Couldn't finish the update"
        }
    }
}
