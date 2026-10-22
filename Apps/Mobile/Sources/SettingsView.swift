import PDClientCore
import SwiftUI

/// `@AppStorage` keys for the phone's preferences.
enum SettingsKey {
    /// `hostID.uuidString` of the Mac shortcuts run on; empty means the last one used.
    static let defaultMac = "defaultMac"
    static let startInLandscape = "startInLandscape"
    static let showStreamInfo = "showStreamInfo"
    static let haptics = "haptics"
}

struct SettingsView: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @AppStorage(SettingsKey.startInLandscape) private var startInLandscape = false
    @AppStorage(SettingsKey.showStreamInfo) private var showStreamInfo = true
    @AppStorage(SettingsKey.haptics) private var haptics = true

    private var paired: [DiscoveredHost] { hosts.filter(\.isPaired) }

    var body: some View {
        NavigationStack {
            Form {
                Section { AboutHeader() }
                    .listRowBackground(Color.clear)

                Section {
                    Picker(selection: $defaultMacID) {
                        Text("Last Used").tag("")
                        ForEach(paired.filter { $0.hostID != nil }) { mac in
                            Text(mac.name).tag(mac.hostID!.uuidString)
                        }
                    } label: {
                        SettingsLabel("Run On", symbol: "laptopcomputer", color: Brand.accent)
                    }
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text("The Mac a shortcut connects to when you're not already streaming.")
                }

                Section("Streaming") {
                    Toggle(isOn: $startInLandscape) {
                        SettingsLabel("Start in Landscape", symbol: "rectangle.landscape.rotate", color: .orange)
                    }
                    Toggle(isOn: $showStreamInfo) {
                        SettingsLabel("Show Stream Info", symbol: "info.circle.fill", color: .teal)
                    }
                    Toggle(isOn: $haptics) {
                        SettingsLabel("Haptics", symbol: "iphone.radiowaves.left.and.right", color: .pink)
                    }
                }

                Section {
                    if paired.isEmpty {
                        Text("No Macs paired yet.").foregroundStyle(.secondary)
                    }
                    ForEach(paired) { mac in
                        HStack(spacing: 12) {
                            MacGlyph(size: 30, dimmed: !mac.isOnline)
                            Text(mac.name)
                            Spacer()
                            StatusPill(text: mac.isOnline ? "Online" : "Offline", color: mac.isOnline ? Brand.online : .gray)
                        }
                        .swipeActions {
                            Button("Forget", systemImage: "trash", role: .destructive) { forget(mac) }
                        }
                    }
                } header: {
                    Text("Paired Macs")
                } footer: {
                    if !paired.isEmpty { Text("Swipe to forget a Mac. It will need pairing again.") }
                }

                Section("About") {
                    LabeledContent {
                        Text(UIDevice.current.name)
                    } label: {
                        SettingsLabel("This iPhone", symbol: "iphone", color: .gray)
                    }
                    LabeledContent {
                        Text("TLS 1.3, pinned keys")
                    } label: {
                        SettingsLabel("Encryption", symbol: "lock.shield.fill", color: .green)
                    }
                    Link(destination: URL(string: "https://github.com/DamilolaDami/pocketdesk")!) {
                        HStack {
                            SettingsLabel("Source Code", symbol: "chevron.left.forwardslash.chevron.right", color: .indigo)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .navigationTitle("Settings")
        }
    }

    private func forget(_ mac: DiscoveredHost) {
        if mac.hostID?.uuidString == defaultMacID { defaultMacID = "" }
        controller.forget(mac)
    }
}

/// A row title with a colored rounded-square icon, like the Settings app.
private struct SettingsLabel: View {
    let title: String
    let symbol: String
    let color: Color

    init(_ title: String, symbol: String, color: Color) {
        self.title = title
        self.symbol = symbol
        self.color = color
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: .rect(cornerRadius: 7, style: .continuous))
        }
    }
}

private struct AboutHeader: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward.inward")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(LinearGradient(colors: [Brand.accent, .purple.opacity(0.85)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: .rect(cornerRadius: 16, style: .continuous))
            Text("PocketDesk").font(.title2.weight(.bold))
            Text("Version \(version) · Open source").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
