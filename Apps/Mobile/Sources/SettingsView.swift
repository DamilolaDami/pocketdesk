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
    /// Seconds PocketDesk may be away before locked Macs ask again (`SessionController` reads it).
    static let relockAfter = SessionController.relockDelayKey
    /// Cover the Mac's picture when the app isn't in front (the app switcher shows a snapshot).
    static let hideInSwitcher = "hideInSwitcher"
    static let keyboardOnOpen = "keyboardOnOpen"
    /// Which groups of keys the key bar above the keyboard shows.
    static let keyBarEditing = "keyBarEditing"
    static let keyBarNavigation = "keyBarNavigation"
    static let keyBarFunction = "keyBarFunction"
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
    @AppStorage(SettingsKey.relockAfter) private var relockAfter: Double = 0
    @AppStorage(SettingsKey.hideInSwitcher) private var hideInSwitcher = true
    @AppStorage(SettingsKey.keyboardOnOpen) private var keyboardOnOpen = false
    @AppStorage(SettingsKey.keyBarEditing) private var keyBarEditing = true
    @AppStorage(SettingsKey.keyBarNavigation) private var keyBarNavigation = true
    @AppStorage(SettingsKey.keyBarFunction) private var keyBarFunction = true
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
                } header: {
                    Text("Shortcuts")
                } footer: {
                    Text("Run On is the Mac a shortcut connects to when you're not already streaming.")
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
                    Toggle(isOn: Binding(get: { allLocked },
                                         set: { locked in Task { await controller.setAllLocked(locked) } })) {
                        SettingsLabel("Lock All Macs", symbol: DeviceOwner.symbol, color: .green)
                    }
                    .disabled(paired.isEmpty)
                    Picker(selection: $relockAfter) {
                        Text("Immediately").tag(0.0)
                        Text("After 1 Minute").tag(60.0)
                        Text("After 5 Minutes").tag(300.0)
                        Text("After 15 Minutes").tag(900.0)
                    } label: {
                        SettingsLabel("Lock Again", symbol: "timer", color: .orange)
                    }
                    Toggle(isOn: $hideInSwitcher) {
                        SettingsLabel("Hide Mac in App Switcher", symbol: "eye.slash.fill", color: .gray)
                    }
                } header: {
                    Text("Privacy & Security")
                } footer: {
                    Text("A locked Mac asks for \(DeviceOwner.method) before it's used. Lock Again is how long PocketDesk can be in the background before it asks again. Lock a single Mac from its page below.")
                }

                Section {
                    Toggle(isOn: $keyboardOnOpen) {
                        SettingsLabel("Show Keyboard on Open", symbol: "keyboard.fill", color: .blue)
                    }
                    Toggle(isOn: $keyBarEditing) {
                        SettingsLabel("Undo, Cut, Copy, Paste", symbol: "scissors", color: .indigo)
                    }
                    Toggle(isOn: $keyBarNavigation) {
                        SettingsLabel("Home, End, Page Keys", symbol: "arrow.up.to.line", color: .teal)
                    }
                    Toggle(isOn: $keyBarFunction) {
                        SettingsLabel("Function Keys", symbol: "fn", color: .gray)
                    }
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("Choose what the bar above the keyboard shows. Esc, Tab, ⌃ ⌥ ⇧ ⌘ and the arrows are always there.")
                }

                Section {
                    if paired.isEmpty {
                        Text("No Macs paired yet.").foregroundStyle(.secondary)
                    }
                    ForEach(paired) { mac in
                        NavigationLink {
                            if let hostID = mac.hostID { MacSettingsView(controller: controller, hostID: hostID) }
                        } label: {
                            HStack(spacing: 12) {
                                MacGlyph(kind: mac.kind, size: 30, status: mac.glyphStatus)
                                Text(mac.name)
                                if mac.isLocked {
                                    Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(mac.isOnline ? "Online" : mac.canWake ? "Asleep" : "Offline")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("Forget", systemImage: "trash", role: .destructive) { forget(mac) }
                        }
                    }
                } header: {
                    Text("Paired Macs")
                } footer: {
                    if !paired.isEmpty { Text("Tap a Mac to rename it, lock it or see its security key.") }
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
                    NavigationLink {
                        HowItsBuiltView()
                    } label: {
                        SettingsLabel("How It's Built", symbol: "cpu.fill", color: Brand.accent)
                    }
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        SettingsLabel("Privacy", symbol: "hand.raised.fill", color: .blue)
                    }
                    NavigationLink {
                        LicensesView()
                    } label: {
                        SettingsLabel("Licences", symbol: "doc.text.fill", color: .gray)
                    }
                    Link(destination: AppInfo.repository) {
                        externalRow("Source Code", symbol: "chevron.left.forwardslash.chevron.right", color: .indigo)
                    }
                    .foregroundStyle(.primary)
                }

                Section {
                    Link(destination: AppInfo.reportProblemURL) {
                        externalRow("Report a Problem", symbol: "ladybug.fill", color: .red)
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Opens a new issue on GitHub with the app, protocol and iOS versions filled in. Nothing else about you or your Macs is included.")
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

    private var allLocked: Bool { !paired.isEmpty && paired.allSatisfy(\.isLocked) }

    private func externalRow(_ title: String, symbol: String, color: Color) -> some View {
        HStack {
            SettingsLabel(title, symbol: symbol, color: color)
            Spacer()
            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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
            Text("Version \(AppInfo.version) · Open source").font(.subheadline).foregroundStyle(.secondary)
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
