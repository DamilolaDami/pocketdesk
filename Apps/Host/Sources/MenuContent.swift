import PDHostCore
import SwiftUI

struct MenuContent: View {
    let controller: HostController
    @State private var permissions = HostPermissions.current()
    @Environment(\.openWindow) private var openWindow

    private var state: HostState { controller.store.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !permissions.allGranted {
                PermissionsCard(permissions: permissions) {
                    HostPermissions.request()
                    permissions = .current()
                }
            }

            if let approval = state.pendingApprovals.first {
                ApprovalCard(approval: approval) { accepted in
                    Task { await controller.resolveApproval(approval.id, accepted: accepted) }
                }
            }

            if !state.connected.isEmpty {
                Section("Connected") {
                    ForEach(state.connected) { phone in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(phone.deviceName, systemImage: "iphone")
                            if let stream = phone.stream {
                                Text("\(phone.window.map { "\($0.appName) — \($0.title)" } ?? "Main display") · \(stream.width)×\(stream.height)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !state.pairedPeers.isEmpty {
                Section("Paired phones") {
                    ForEach(state.pairedPeers) { peer in
                        HStack {
                            Text(peer.name)
                            Spacer()
                            Button("Forget") { Task { await controller.revoke(peer.fingerprint) } }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Divider()
            Button("Pair a Phone…") {
                openWindow(id: PairingWindow.id)
                NSApplication.shared.activate()
            }
            Button("Quit PocketDesk") { NSApplication.shared.terminate(nil) }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { permissions = .current() }
    }

    private var header: some View {
        HStack {
            Text("PocketDesk").font(.headline)
            Spacer()
            switch state.listening {
            case .starting:
                Text("Starting…").foregroundStyle(.secondary)
            case .listening:
                Label("Ready", systemImage: "circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
            case .stopped(let error):
                Label(error == nil ? "Stopped" : "Error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).help(error ?? "")
            }
        }
        .font(.caption)
    }
}

private struct PermissionsCard: View {
    let permissions: HostPermissions
    let request: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PocketDesk needs permission").font(.subheadline.bold())
            Label("Screen Recording", systemImage: permissions.screenRecording ? "checkmark.circle.fill" : "xmark.circle")
            Label("Accessibility (for mouse and keyboard)", systemImage: permissions.accessibility ? "checkmark.circle.fill" : "xmark.circle")
            Button("Grant in System Settings…", action: request)
        }
        .font(.caption)
        .padding(10)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 8))
    }
}

struct ApprovalCard: View {
    let approval: PairingApproval
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("“\(approval.deviceName)” wants to pair").font(.subheadline.bold())
            Text("Accept only if your phone shows this code:").font(.caption)
            Text(approval.code.inserting(" ", at: 3))
                .font(.system(.title, design: .monospaced).bold())
            HStack {
                Button("Decline", role: .cancel) { decide(false) }
                Button("Accept") { decide(true) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(.blue.opacity(0.1), in: .rect(cornerRadius: 8))
    }
}

extension String {
    fileprivate func inserting(_ separator: String, at offset: Int) -> String {
        guard count > offset else { return self }
        return String(prefix(offset)) + separator + String(dropFirst(offset))
    }
}
