import AppKit
import PDHostCore
import PDProtocol
import SwiftUI

struct RelaySettingsWindow: View {
    static let id = "relay-settings"
    let controller: HostController
    @AppStorage(RelayServer.enabledKey) private var enabled = false
    @AppStorage(RelayServer.addressKey) private var address = RelayServer.defaultAddress
    @State private var draft = ""
    @State private var custom = false
    @State private var copied = false

    private var statusColor: Color {
        guard enabled else { return .secondary }
        switch controller.store.state.relayStatus {
        case .ready: return .green
        case .connecting: return .blue
        case .unavailable: return .orange
        case .disabled: return .secondary
        }
    }
    var body: some View {
        Form {
            Section {
                Toggle("Reach this Mac from anywhere", isOn: $enabled)
                    .onChange(of: enabled) { controller.relaySettingsChanged() }
            } footer: {
                Text("Only your paired phones can connect. Keep this Mac awake with PocketDesk running. Pair new phones on the same Wi-Fi first.")
            }
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .font(.title2).foregroundStyle(.blue)
                            .frame(width: 44, height: 44)
                            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(address == RelayServer.defaultAddress ? "PocketDesk Relay" : "Custom Relay")
                                .font(.headline)
                            Label(enabled ? controller.store.state.relayStatus.text : "Off", systemImage: "circle.fill")
                                .font(.caption).foregroundStyle(statusColor)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 8) {
                        Text(address).font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(address, forType: .string)
                            copied = true
                        } label: {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(copied ? "Copied" : "Copy relay address")
                        .accessibilityLabel(copied ? "Relay address copied" : "Copy relay address")
                    }
                    Label("Encrypted between your devices", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                DisclosureGroup("Use a custom relay", isExpanded: $custom) {
                    TextField("Hostname and port", text: $draft, prompt: Text("relay.example.com:4433"))
                        .autocorrectionDisabled()
                    Button("Save Relay") { save(draft) }
                        .disabled(RelayServer(address: draft) == nil || draft == address)
                    if !draft.isEmpty, RelayServer(address: draft) == nil {
                        Text("Enter a hostname and optional port, without a URL path.")
                            .foregroundStyle(.red).font(.caption)
                    }
                    if address != RelayServer.defaultAddress {
                        Button("Use PocketDesk Relay") { save(RelayServer.defaultAddress) }
                    }
                }
            } header: { Text("Relay server") } footer: {
                Text("Use the same relay on your iPhone. Local connections are always tried first.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: custom ? 510 : 390)
        .onAppear {
            if address.isEmpty { address = RelayServer.defaultAddress }
            draft = address
        }
        .onChange(of: address) { copied = false }
    }
    private func save(_ value: String) {
        address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = address
        custom = false
        controller.relaySettingsChanged()
    }
}
