import AppIntents
import PDClientCore
import PDProtocol
import SwiftUI

/// `@AppStorage` keys for the phone's preferences.
enum SettingsKey {
    /// `hostID.uuidString` of the Mac shortcuts run on; empty means the last one used.
    static let defaultMac = "defaultMac"
    static let startInLandscape = "startInLandscape"
    static let showStreamInfo = "showStreamInfo"
    static let streamAudio = "streamAudio"
    /// Same key `SessionController.clipboardEnabled` reads.
    static let shareClipboard = "shareClipboard"
    static let haptics = "haptics"
    /// The stream starts in trackpad mode (the control bar switches it too).
    static let trackpad = "trackpad"
    /// Same key `SessionController.autoConnect` reads.
    static let autoConnect = "autoConnect"
    /// Same key `SessionController.preferredQuality` reads.
    static let streamQuality = "streamQuality"
}

struct SettingsView: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @AppStorage(SettingsKey.startInLandscape) private var startInLandscape = false
    @AppStorage(SettingsKey.showStreamInfo) private var showStreamInfo = true
    @AppStorage(SettingsKey.streamAudio) private var streamAudio = true
    @AppStorage(SettingsKey.shareClipboard) private var shareClipboard = true
    @AppStorage(SettingsKey.haptics) private var haptics = true
    @AppStorage(SettingsKey.trackpad) private var trackpad = false
    @AppStorage(SettingsKey.autoConnect) private var autoConnect = false
    @AppStorage(SettingsKey.streamQuality) private var quality = StreamQuality.best
    @State private var showingSiri = false

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

                Section {
                    Button {
                        showingSiri = true
                    } label: {
                        HStack {
                            SettingsLabel("Siri & Shortcuts", symbol: "waveform", color: .purple)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }


                Section {
                    Picker(selection: $quality) {
                        ForEach(StreamQuality.allCases, id: \.self) { Text($0.name).tag($0) }
                    } label: {
                        SettingsLabel("Quality", symbol: "sparkles.tv.fill", color: .purple)
                    }
                    .onChange(of: quality) { controller.qualityChanged() }
                } header: {
                    Text("Picture")
                } footer: {
                    Text("Best keeps text sharp when you zoom in. Battery Saver lowers resolution and frame rate to save battery and data, and is used automatically in Low Power Mode.")
                }

                Section("Streaming") {
                    Toggle(isOn: $streamAudio) {
                        SettingsLabel("Play Mac Audio", symbol: "speaker.wave.2.fill", color: .blue)
                    }
                    .onChange(of: streamAudio) { _, enabled in controller.audioEnabled = enabled }
                    Toggle(isOn: $shareClipboard) {
                        SettingsLabel("Share Clipboard", symbol: "doc.on.clipboard.fill", color: .indigo)
                    }
                    .onChange(of: shareClipboard) { _, enabled in controller.clipboardEnabled = enabled }
                    Toggle(isOn: $autoConnect) {
                        SettingsLabel("Open Last Mac at Launch", symbol: "bolt.horizontal.fill", color: .green)
                    }
                    Toggle(isOn: $trackpad) {
                        SettingsLabel("Trackpad Mode", symbol: "cursorarrow", color: .gray)
                    }
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
                            MacGlyph(kind: mac.kind, size: 30, status: mac.glyphStatus)
                            Text(mac.name)
                            Spacer()
                            Text(mac.isOnline ? "Online" : mac.canWake ? "Asleep" : "Offline")
                                .foregroundStyle(.secondary)
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
            .sheet(isPresented: $showingSiri) {
                SiriSettingsSheet(shortcuts: controller.store.shortcuts)
                    .presentationDetents([.medium, .large])
            }
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

/// How to run shortcuts from outside the app: the phrase, and the way into the Shortcuts app.
private struct SiriSettingsSheet: View {
    let shortcuts: [Shortcut]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let first = shortcuts.first {
                        SiriTipView(intent: RunShortcutIntent(shortcut: ShortcutEntity(first)))
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                } footer: {
                    Text("Works with any of your shortcuts, by name.")
                }

                Section {
                    ShortcutsLink()
                        .shortcutsLinkStyle(.automatic)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("In the Shortcuts app you can give a shortcut your own phrase (like “Open Netflix on my Mac”), add it to the Home Screen, or run it from Control Center.")
                }

                Section("Also") {
                    Label("Home Screen and Lock Screen widgets show your first shortcuts.", systemImage: "square.grid.2x2")
                    Label("Add a Control Center control and pick which shortcut it runs.", systemImage: "switch.2")
                }
                .font(.subheadline)
            }
            .navigationTitle("Siri & Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
    }
}
