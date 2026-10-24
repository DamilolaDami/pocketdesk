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

/// The top level: one row per area, like the Settings app. Each area has its own page.
struct SettingsView: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @AppStorage(SettingsKey.streamQuality) private var quality = StreamQuality.best
    @AppStorage(RelayServer.enabledKey) private var relayEnabled = false
    @AppStorage(RelayServer.addressKey) private var relayAddress = RelayServer.defaultAddress

    private var paired: [DiscoveredHost] { hosts.filter(\.isPaired) }

    var body: some View {
        NavigationStack {
            Form {
                Section { AboutHeader() }
                    .listRowBackground(Color.clear)

                Section {
                    NavigationLink {
                        MacsSettingsPage(controller: controller, paired: paired)
                    } label: {
                        row("Macs", symbol: "laptopcomputer", color: Brand.accent,
                            value: paired.isEmpty ? "None" : "\(paired.count)")
                    }
                    NavigationLink {
                        RelaySettingsView(controller: controller, pairedCount: paired.count)
                    } label: {
                        row("Remote Access", symbol: "globe", color: .blue,
                            value: relayEnabled && RelayServer(address: relayAddress) != nil ? "On" : "Off")
                    }
                }

                Section {
                    NavigationLink {
                        StreamingSettingsPage(controller: controller)
                    } label: {
                        row("Streaming", symbol: "play.rectangle.fill", color: .purple, value: quality.name)
                    }
                    NavigationLink {
                        KeyboardSettingsPage()
                    } label: {
                        SettingsLabel("Keyboard", symbol: "keyboard.fill", color: .gray)
                    }
                    NavigationLink {
                        ShortcutsSettingsPage(controller: controller, paired: paired)
                    } label: {
                        row("Shortcuts & Siri", symbol: "waveform", color: .pink, value: runOnName)
                    }
                    NavigationLink {
                        PrivacySettingsPage(controller: controller, paired: paired)
                    } label: {
                        SettingsLabel("Privacy & Security", symbol: "hand.raised.fill", color: .green)
                    }
                }

                Section {
                    NavigationLink {
                        AboutSettingsPage()
                    } label: {
                        SettingsLabel("About", symbol: "info.circle.fill", color: .gray)
                    }
                    Link(destination: AppInfo.reportProblemURL) {
                        externalRow("Report a Problem", symbol: "ladybug.fill", color: .red)
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Report a Problem opens a new issue on GitHub with the app, protocol and iOS versions filled in. Nothing else about you or your Macs is included.")
                }
            }
            .scrollContentBackground(.hidden)
            .background { AppBackground() }
            .navigationTitle("Settings")
        }
    }

    /// The Mac shortcuts run on, for the row's value.
    private var runOnName: String {
        paired.first { $0.hostID?.uuidString == defaultMacID }?.name ?? "Last Used"
    }

    private func row(_ title: String, symbol: String, color: Color, value: String) -> some View {
        HStack {
            SettingsLabel(title, symbol: symbol, color: color)
            Spacer()
            Text(value).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// A row that opens outside the app, with the arrow that says so.
private func externalRow(_ title: String, symbol: String, color: Color) -> some View {
    HStack {
        SettingsLabel(title, symbol: symbol, color: color)
        Spacer()
        Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
    }
}

private extension View {
    /// The look every settings page shares.
    func settingsPage(_ title: String) -> some View {
        scrollContentBackground(.hidden)
            .background { AppBackground() }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The paired Macs: tap one to rename, lock or check it; swipe to forget.
private struct MacsSettingsPage: View {
    let controller: SessionController
    let paired: [DiscoveredHost]
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""

    var body: some View {
        Form {
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
            } footer: {
                if !paired.isEmpty { Text("Tap a Mac to rename it, lock it or see its security key. Swipe left to forget it.") }
            }
        }
        .settingsPage("Macs")
    }

    private func forget(_ mac: DiscoveredHost) {
        if mac.hostID?.uuidString == defaultMacID { defaultMacID = "" }
        controller.forget(mac)
    }
}

/// How the stream looks, sounds and behaves.
private struct StreamingSettingsPage: View {
    let controller: SessionController
    @AppStorage(SettingsKey.streamQuality) private var quality = StreamQuality.best
    @AppStorage(SettingsKey.streamAudio) private var streamAudio = true
    @AppStorage(SettingsKey.shareClipboard) private var shareClipboard = true
    @AppStorage(SettingsKey.autoConnect) private var autoConnect = false
    @AppStorage(SettingsKey.trackpad) private var trackpad = false
    @AppStorage(SettingsKey.startInLandscape) private var startInLandscape = false
    @AppStorage(SettingsKey.showStreamInfo) private var showStreamInfo = true
    @AppStorage(SettingsKey.haptics) private var haptics = true

    var body: some View {
        Form {
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

            Section("Sound and Clipboard") {
                Toggle(isOn: $streamAudio) {
                    SettingsLabel("Play Mac Audio", symbol: "speaker.wave.2.fill", color: .blue)
                }
                .onChange(of: streamAudio) { _, enabled in controller.audioEnabled = enabled }
                Toggle(isOn: $shareClipboard) {
                    SettingsLabel("Share Clipboard", symbol: "doc.on.clipboard.fill", color: .indigo)
                }
                .onChange(of: shareClipboard) { _, enabled in controller.clipboardEnabled = enabled }
            }

            Section("When Streaming") {
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
        }
        .settingsPage("Streaming")
    }
}

/// The keyboard and the bar of Mac keys above it.
private struct KeyboardSettingsPage: View {
    @AppStorage(SettingsKey.keyboardOnOpen) private var keyboardOnOpen = false
    @AppStorage(SettingsKey.keyBarEditing) private var keyBarEditing = true
    @AppStorage(SettingsKey.keyBarNavigation) private var keyBarNavigation = true
    @AppStorage(SettingsKey.keyBarFunction) private var keyBarFunction = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $keyboardOnOpen) {
                    SettingsLabel("Show Keyboard on Open", symbol: "keyboard.fill", color: .blue)
                }
            }
            Section {
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
                Text("Key Bar")
            } footer: {
                Text("Choose what the bar above the keyboard shows. Esc, Tab, ⌃ ⌥ ⇧ ⌘ and the arrows are always there.")
            }
        }
        .settingsPage("Keyboard")
    }
}

/// Which Mac shortcuts run on, and running them from outside the app.
private struct ShortcutsSettingsPage: View {
    let controller: SessionController
    let paired: [DiscoveredHost]
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @State private var showingSiri = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $defaultMacID) {
                    Text("Last Used").tag("")
                    ForEach(paired.filter { $0.hostID != nil }) { mac in
                        Text(mac.name).tag(mac.hostID!.uuidString)
                    }
                } label: {
                    SettingsLabel("Run On", symbol: "laptopcomputer", color: Brand.accent)
                }
            } footer: {
                Text("Run On is the Mac a shortcut connects to when you're not already streaming.")
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
            } footer: {
                Text("Run your shortcuts with Siri, from widgets and from Control Center.")
            }
        }
        .settingsPage("Shortcuts & Siri")
        .sheet(isPresented: $showingSiri) {
            SiriSettingsSheet(shortcuts: controller.store.shortcuts)
                .presentationDetents([.medium, .large])
        }
    }
}

/// Face ID locks, and keeping the Mac's picture out of the app switcher.
private struct PrivacySettingsPage: View {
    let controller: SessionController
    let paired: [DiscoveredHost]
    @AppStorage(SettingsKey.relockAfter) private var relockAfter: Double = 0
    @AppStorage(SettingsKey.hideInSwitcher) private var hideInSwitcher = true

    private var allLocked: Bool { !paired.isEmpty && paired.allSatisfy(\.isLocked) }

    var body: some View {
        Form {
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
            } footer: {
                Text("A locked Mac asks for \(DeviceOwner.method) before it's used. Lock Again is how long PocketDesk can be in the background before it asks again. Lock a single Mac from its page in Macs.")
            }
            Section {
                Toggle(isOn: $hideInSwitcher) {
                    SettingsLabel("Hide Mac in App Switcher", symbol: "eye.slash.fill", color: .gray)
                }
            } footer: {
                Text("Covers your Mac's screen in the app switcher's snapshot.")
            }
        }
        .settingsPage("Privacy & Security")
    }
}

/// This iPhone, how PocketDesk is built and secured, and its legal pages.
private struct AboutSettingsPage: View {
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(UIDevice.current.name)
                } label: {
                    SettingsLabel("This iPhone", symbol: "iphone", color: .gray)
                }
                LabeledContent {
                    Text("\(AppInfo.version) (\(AppInfo.build))")
                } label: {
                    SettingsLabel("Version", symbol: "number", color: .gray)
                }
                LabeledContent {
                    Text("TLS 1.3, pinned keys")
                } label: {
                    SettingsLabel("Encryption", symbol: "lock.shield.fill", color: .green)
                }
            }
            Section {
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
                Link(destination: AppInfo.terms) {
                    externalRow("Terms of Use", symbol: "doc.plaintext.fill", color: .teal)
                }
                .foregroundStyle(.primary)
                Link(destination: AppInfo.repository) {
                    externalRow("Source Code", symbol: "chevron.left.forwardslash.chevron.right", color: .indigo)
                }
                .foregroundStyle(.primary)
            }
        }
        .settingsPage("About")
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
            // The app icon's artwork, rounded like the Home Screen does it.
            Image("AppIconArtwork")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
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

/// Remote Access: what it does, whether it's working, and what to set up, in that order. The
/// relay server itself is an advanced detail, on a page of its own.
private struct RelaySettingsView: View {
    let controller: SessionController
    let pairedCount: Int
    @AppStorage(RelayServer.enabledKey) private var enabled = false
    @AppStorage(RelayServer.addressKey) private var address = RelayServer.defaultAddress

    private var usingDefault: Bool { address == RelayServer.defaultAddress }

    var body: some View {
        Form {
            Section { RemoteAccessHeader(enabled: enabled) }
                .listRowBackground(Color.clear)

            Section {
                Toggle(isOn: $enabled) {
                    SettingsLabel("Remote Access", symbol: "globe", color: Brand.accent)
                }
                .onChange(of: enabled) { controller.relaySettingsChanged() }
                RemoteAccessStatus(status: status)
            }

            Section {
                SetupStep(number: 1, done: pairedCount > 0, title: "Pair on the same Wi-Fi",
                          detail: pairedCount > 0
                              ? "Done. Pairing always happens in person, so no one can pair from far away."
                              : "Pair your Mac while you're together. No one can pair from far away.")
                SetupStep(number: 2, done: false, title: "Turn it on on your Mac",
                          detail: "Click PocketDesk in the menu bar, choose Remote Access… and turn it on.")
                SetupStep(number: 3, done: false, title: "Keep your Mac awake",
                          detail: "A sleeping Mac can't be reached from away. Leave it on power with PocketDesk open.")
            } header: {
                Text("Set Up Once")
            }

            Section {
                InfoRow(symbol: "lock.shield.fill", color: .green, title: "Private and encrypted",
                        detail: "Your screen and typing are encrypted between your iPhone and Mac. The relay only passes sealed data along and can't see either.")
                InfoRow(symbol: "wifi", color: .blue, title: "Home Wi-Fi comes first",
                        detail: "When your Mac is nearby, PocketDesk connects straight to it, just as before.")
            }

            Section {
                NavigationLink {
                    RelayServerView(controller: controller)
                } label: {
                    HStack {
                        SettingsLabel("Relay Server", symbol: "server.rack", color: .gray)
                        Spacer()
                        Text(usingDefault ? "PocketDesk" : (RelayServer(address: address)?.host ?? "Custom"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Only change this if you run your own relay.")
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle("Remote Access")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if address.isEmpty { address = RelayServer.defaultAddress } }
    }

    private var status: RemoteAccessStatus.Status {
        guard enabled else { return .off }
        guard controller.store.connectionPath == .relay else { return .ready }
        switch controller.store.state {
        case .streaming: return .connected
        case .connecting: return .connecting
        case .failed: return .unreachable
        default: return .ready
        }
    }
}

/// An iPhone and a Mac with the globe between them; the link lights up when it's on.
private struct RemoteAccessHeader: View {
    let enabled: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                device("iphone")
                link
                Image(systemName: "globe")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background((enabled ? Brand.accent : Color.gray).gradient, in: .circle)
                    .shadow(color: (enabled ? Brand.accent : .clear).opacity(0.35), radius: 10, y: 4)
                link
                device("laptopcomputer")
            }
            .animation(.smooth, value: enabled)
            Text("Your Mac, from anywhere")
                .font(.title2.weight(.bold))
            Text("Use your Mac over cellular or any Wi-Fi, not only when you're home.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func device(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 52, height: 52)
            .background(.background, in: .rect(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }

    private var link: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().frame(width: 4, height: 4)
            }
        }
        .foregroundStyle(enabled ? Brand.accent : Color.secondary.opacity(0.4))
    }
}

/// One line that says, in plain words, what Remote Access is doing right now.
private struct RemoteAccessStatus: View {
    enum Status { case off, ready, connecting, connected, unreachable }
    let status: Status

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 29)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status {
        case .off: "wifi"
        case .ready: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .connected: "dot.radiowaves.left.and.right"
        case .unreachable: "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch status {
        case .off: .secondary
        case .ready: Brand.accent
        case .connecting: Brand.accent
        case .connected: .green
        case .unreachable: .orange
        }
    }
    private var title: String {
        switch status {
        case .off: "Only on the same Wi-Fi"
        case .ready: "Ready"
        case .connecting: "Connecting from away…"
        case .connected: "Connected from away"
        case .unreachable: "Couldn't reach your Mac"
        }
    }
    private var detail: String {
        switch status {
        case .off: "Turn on Remote Access to reach your Mac when you're out."
        case .ready: "When your Mac isn't nearby, PocketDesk connects through the relay."
        case .connecting: "Reaching your Mac through the relay."
        case .connected: "Your Mac is streaming through the relay."
        case .unreachable: "Check that it's awake, PocketDesk is open, and Remote Access is on on the Mac."
        }
    }
}

/// A numbered setup step, with a green tick once it's done.
private struct SetupStep: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green.gradient : Brand.accent.opacity(0.12).gradient)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.subheadline.weight(.bold)).foregroundStyle(Brand.accent)
                }
            }
            .frame(width: 29, height: 29)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)\(done ? ", done" : ""). \(detail)")
    }
}

/// A short reassurance: a colored icon, a title and one or two lines.
private struct InfoRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color.gradient, in: .rect(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Which relay to use: PocketDesk's, or your own. Both devices need the same one.
private struct RelayServerView: View {
    let controller: SessionController
    @AppStorage(RelayServer.addressKey) private var address = RelayServer.defaultAddress
    @State private var draft = ""
    @State private var customSelected = false
    @FocusState private var editing: Bool

    private var usingDefault: Bool { address == RelayServer.defaultAddress }
    private var draftValid: Bool { RelayServer(address: draft) != nil }

    var body: some View {
        Form {
            Section {
                choice("PocketDesk Relay", detail: "Recommended. Run by PocketDesk.", selected: !customSelected) {
                    customSelected = false
                    save(RelayServer.defaultAddress)
                }
                choice("Your Own Relay", detail: "A server you run yourself.", selected: customSelected) {
                    customSelected = true
                    editing = true
                }
            } footer: {
                Text("Use the same relay on your iPhone and your Mac.")
            }

            if customSelected {
                Section {
                    TextField("relay.example.com:4433", text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($editing)
                        .submitLabel(.done)
                        .onSubmit { if draftValid { save(draft) } }
                        .accessibilityLabel("Relay hostname and port")
                    Button("Use This Relay") { save(draft) }
                        .disabled(!draftValid || draft == address)
                } header: {
                    Text("Server Address")
                } footer: {
                    if !draft.isEmpty && !draftValid {
                        Text("Enter a hostname, with a port if it isn't 4433. For example relay.example.com:4433.")
                            .foregroundStyle(.red)
                    } else if !usingDefault {
                        Text("Now using \(address).")
                    } else {
                        Text("A hostname, with a port if it isn't 4433.")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background { AppBackground() }
        .navigationTitle("Relay Server")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            customSelected = !usingDefault
            draft = usingDefault ? "" : address
        }
    }

    private func choice(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Brand.accent)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RelayServer(address: trimmed) != nil, trimmed != address else { return }
        address = trimmed
        editing = false
        controller.relaySettingsChanged()
    }
}
