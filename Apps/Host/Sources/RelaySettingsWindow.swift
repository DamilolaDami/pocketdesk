import PDHostCore
import PDProtocol
import SwiftUI

struct RelaySettingsWindow: View {
    static let id = "relay-settings"
    let controller: HostController
    @AppStorage(RelayServer.enabledKey) private var enabled = false
    @AppStorage(RelayServer.addressKey) private var address = ""
    @State private var draft = ""

    private var valid: Bool { RelayServer(address: draft) != nil }
    var body: some View {
        Form {
            Section {
                Toggle("Reach this Mac from anywhere", isOn: $enabled)
                    .disabled(RelayServer(address: address) == nil && !enabled)
                    .onChange(of: enabled) { controller.relaySettingsChanged() }
                Label(
                    controller.store.state.relayStatus.text,
                    systemImage: enabled ? "network" : "network.slash"
                )
                .foregroundStyle(.secondary)
            } footer: {
                Text(
                    "Only your paired phones can connect. Keep this Mac awake with PocketDesk running. Pair new phones on the same network first."
                )
            }
            Section {
                TextField("Hostname and port", text: $draft, prompt: Text("relay.example.com:4433"))
                    .autocorrectionDisabled()
                Button("Save Relay") {
                    address = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    controller.relaySettingsChanged()
                }
                .disabled(!valid || draft == address)
                if !draft.isEmpty, !valid {
                    Text("Enter a hostname and optional port, without a URL path.").foregroundStyle(.red).font(.caption)
                }
            } header: {
                Text("Relay server")
            } footer: {
                Text(
                    "Enter the same server in PocketDesk Settings on your iPhone. Use a relay with a valid TLS certificate for this hostname. Local connections are always tried first."
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 360)
        .onAppear { draft = address }
    }
}
