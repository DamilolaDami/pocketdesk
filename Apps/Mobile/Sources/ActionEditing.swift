import PDClientCore
import PDProtocol
import SwiftUI

/// One action as the editor's fields hold it, before it's a valid `MacAction`.
struct ActionDraft: Equatable {
    enum Kind: String, CaseIterable {
        case website = "Website", app = "App", macShortcut = "Shortcuts", control = "Control", wait = "Wait"

        /// What a shortcut's first step can be; a wait only makes sense between steps.
        static let actions: [Kind] = [.website, .app, .macShortcut, .control]

        var stepTitle: String {
            switch self {
            case .website: "Open Website"
            case .app: "Open App"
            case .macShortcut: "Run Mac Shortcut"
            case .control: "Mac Control"
            case .wait: "Wait"
            }
        }

        var symbol: String {
            switch self {
            case .website: "globe"
            case .app: "app.fill"
            case .macShortcut: "square.stack.3d.up.fill"
            case .control: "command"
            case .wait: "hourglass"
            }
        }
    }

    var kind: Kind
    var website = ""
    var appName = ""
    /// Set when picked from the Mac's list or a popular app; typed names go by name.
    var appBundleID: String?
    var shortcutName = ""
    var shortcutID: String?
    var controlID = ActionDraft.controls[0].id
    var volume: Double = 50
    /// For Play / Pause, Next and Previous: one player, or `nil` for whatever's playing.
    var player: MediaPlayer?
    var seconds: Double = 1

    static let volumeID = "Set Volume"
    static var controls: [ShortcutPreset] { ShortcutPreset.all.filter { $0.category == .controls } }
    private static var appPresets: [ShortcutPreset] { ShortcutPreset.all.filter { $0.category == .apps } }

    init(kind: Kind) {
        self.kind = kind
    }

    init(_ action: MacAction) {
        self.init(kind: .website)
        switch action {
        case .openURL(let url):
            kind = .website
            website = url.replacing(/^https?:\/\/(www\.)?/, with: "")
        case .openApp(let bundleID, let name):
            kind = .app
            appName = name
            appBundleID = bundleID
        case .runShortcut(let id, let name):
            kind = .macShortcut
            shortcutName = name
            shortcutID = id
        case .keystroke, .media:
            kind = .control
            controlID = Self.controls.first { $0.shortcut.action == action }?.id ?? Self.controls[0].id
        case .mediaIn(let key, let player):
            kind = .control
            controlID = Self.controls.first { $0.shortcut.action == .media(key) }?.id ?? Self.controls[0].id
            self.player = player
        case .setVolume(let level):
            kind = .control
            controlID = Self.volumeID
            volume = Double(level)
        case .wait(let milliseconds):
            kind = .wait
            seconds = Double(milliseconds) / 1000
        case .steps(let steps):
            self = ActionDraft(steps.first ?? .openURL(""))
        }
    }

    /// `nil` until the fields describe something the Mac can do.
    var action: MacAction? {
        switch kind {
        case .website:
            ShortcutEditor.url(from: website).map(MacAction.openURL)
        case .app:
            appName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .openApp(
                // A picked app keeps its bundle ID (robust to renamed apps); typed ones go by name.
                bundleID: appBundleID ?? Self.appPresets.first { $0.shortcut.name == appName }?.shortcut.appBundleID,
                name: appName.trimmingCharacters(in: .whitespaces))
        case .macShortcut:
            shortcutName.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                : .runShortcut(id: shortcutID, name: shortcutName.trimmingCharacters(in: .whitespaces))
        case .control:
            if controlID == Self.volumeID { .setVolume(Int(volume.rounded())) }
            else if let key = transportKey, let player { .mediaIn(key, player: player) }
            else { Self.controls.first { $0.id == controlID }?.shortcut.action }
        case .wait:
            .wait(milliseconds: Int((seconds * 1000).rounded()))
        }
    }

    /// The chosen control, if it's one a player can take directly.
    var transportKey: MediaKey? {
        guard kind == .control, case .media(let key)? = Self.controls.first(where: { $0.id == controlID })?.shortcut.action,
              key.isTransport else { return nil }
        return key
    }

    var footer: String {
        switch kind {
        case .website: website.contains(MacAction.textPlaceholder)
            ? "Asks what to type each time and puts it where {text} is."
            : "Opens in the Mac's default browser. To be asked for words each time, put {text} in the link, like youtube.com/results?search_query={text}."
        case .app: "Opens the app, or brings it to the front if it's already running."
        case .macShortcut: "Runs a shortcut from the Shortcuts app on your Mac: HomeKit scenes, Focus, scripts and more."
        case .control:
            if let player, transportKey != nil {
                "Goes straight to \(player.name), even if something else is playing. \(player.name) needs to be open; the Mac asks once to allow it."
            } else if controlID == Self.volumeID { "Sets the Mac's sound output volume." } else {
                "Presses the keys on the Mac. Play / Pause works on whatever is playing, like Netflix in Safari."
            }
        case .wait: "Gives the Mac a moment, like letting a page load before going full screen."
        }
    }
}

/// The fields for one action. With more than one kind, a segmented picker switches them.
struct ActionFields: View {
    let controller: SessionController
    @Binding var draft: ActionDraft
    var kinds: [ActionDraft.Kind]
    /// A Mac app or Mac Shortcut was picked: its name, the name it replaces, and a symbol.
    var picked: ((String, String, String) -> Void)?

    var body: some View {
        if kinds.count > 1 {
            Picker("Does", selection: $draft.kind) {
                ForEach(kinds, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
        switch draft.kind {
        case .website:
            TextField("netflix.com", text: $draft.website)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .app:
            NavigationLink {
                MacAppPicker(controller: controller, selected: draft.appBundleID) { app in
                    picked?(app.name, draft.appName, "app.fill")
                    draft.appName = app.name
                    draft.appBundleID = app.bundleID
                }
            } label: {
                HStack(spacing: 12) {
                    if let bundleID = draft.appBundleID {
                        AppIconImage(bundleID: bundleID, png: controller.store.appIcons[bundleID], size: 30)
                    } else {
                        Image(systemName: "square.grid.3x3.fill").foregroundStyle(Brand.accent).frame(width: 30)
                    }
                    Text(draft.appBundleID == nil ? "Choose an App" : draft.appName)
                        .foregroundStyle(draft.appBundleID == nil ? Brand.accent : .primary)
                }
            }
            TextField("Or type its name", text: Binding(get: { draft.appBundleID == nil ? draft.appName : "" }, set: {
                draft.appName = $0
                draft.appBundleID = nil
            }))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
        case .macShortcut:
            NavigationLink {
                MacShortcutPicker(controller: controller, selected: draft.shortcutID) { shortcut in
                    picked?(shortcut.name, draft.shortcutName, ActionDraft.Kind.macShortcut.symbol)
                    draft.shortcutName = shortcut.name
                    draft.shortcutID = shortcut.id
                }
            } label: {
                Label(draft.shortcutID == nil ? "Choose a Shortcut" : draft.shortcutName,
                      systemImage: ActionDraft.Kind.macShortcut.symbol)
                    .foregroundStyle(draft.shortcutID == nil ? Brand.accent : .primary)
            }
            TextField("Or type its name", text: Binding(get: { draft.shortcutID == nil ? draft.shortcutName : "" }, set: {
                draft.shortcutName = $0
                draft.shortcutID = nil
            }))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
        case .control:
            Picker("Press", selection: $draft.controlID) {
                ForEach(ActionDraft.controls) { preset in
                    Text("\(preset.shortcut.name)  \(preset.shortcut.action.summary)").tag(preset.id)
                }
                Text("Set Volume…").tag(ActionDraft.volumeID)
            }
            .pickerStyle(.navigationLink)
            if draft.transportKey != nil {
                Picker("Controls", selection: $draft.player) {
                    Text("Whatever's Playing").tag(MediaPlayer?.none)
                    ForEach(players, id: \.self) { Text($0.name).tag(MediaPlayer?.some($0)) }
                }
            }
            if draft.controlID == ActionDraft.volumeID {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $draft.volume, in: 0...100, step: 5)
                    Text("\(Int(draft.volume))%").monospacedDigit().frame(width: 46, alignment: .trailing)
                }
            }
        case .wait:
            Stepper(value: $draft.seconds, in: 0.5...Double(MacAction.maxWaitMilliseconds / 1000), step: 0.5) {
                Text("Wait \(draft.seconds.formatted(.number.precision(.fractionLength(0...1)))) s")
            }
        }
    }
}

extension ActionFields {
    /// Players installed on the Mac (all of them until its app list has loaded), plus the
    /// chosen one so it never vanishes from the picker.
    fileprivate var players: [MediaPlayer] {
        let installed = Set(controller.store.macApps.map(\.bundleID))
        return MediaPlayer.allCases.filter { installed.isEmpty || installed.contains($0.bundleID) || $0 == draft.player }
    }
}

/// A step after the first, with an identity for the list.
struct StepDraft: Identifiable {
    let id = UUID()
    var draft: ActionDraft
}

/// One "Then" row: waits adjust in place, anything else opens its own pane.
struct StepRow: View {
    let controller: SessionController
    @Binding var step: StepDraft

    var body: some View {
        if step.draft.kind == .wait {
            Stepper(value: $step.draft.seconds, in: 0.5...Double(MacAction.maxWaitMilliseconds / 1000), step: 0.5) {
                Label("Wait \(step.draft.seconds.formatted(.number.precision(.fractionLength(0...1)))) s",
                      systemImage: ActionDraft.Kind.wait.symbol)
            }
        } else {
            NavigationLink {
                Form {
                    Section {
                        ActionFields(controller: controller, draft: $step.draft, kinds: [step.draft.kind])
                    } footer: {
                        Text(step.draft.footer)
                    }
                }
                .navigationTitle(step.draft.kind.stepTitle)
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label {
                    if let action = step.draft.action {
                        Text(action.summary)
                    } else {
                        Text("\(step.draft.kind.stepTitle)…").foregroundStyle(Brand.accent)
                    }
                } icon: {
                    Image(systemName: step.draft.kind.symbol)
                }
            }
        }
    }
}

/// The shortcuts in the Mac's Shortcuts app.
struct MacShortcutPicker: View {
    let controller: SessionController
    let selected: String?
    let pick: (MacShortcut) -> Void
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var store: SessionStore { controller.store }

    private var shortcuts: [MacShortcut] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? store.macShortcuts
            : store.macShortcuts.filter { $0.name.localizedStandardContains(trimmed) }
    }

    var body: some View {
        List(shortcuts) { shortcut in
            Button {
                pick(shortcut)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: ActionDraft.Kind.macShortcut.symbol)
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Brand.accent.gradient, in: .rect(cornerRadius: 8, style: .continuous))
                    Text(shortcut.name)
                    Spacer()
                    if shortcut.id == selected {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Brand.accent)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .overlay { emptyState }
        .searchable(text: $query, prompt: "Search shortcuts")
        .navigationTitle("Mac Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { controller.loadApps(preferredHostID: UUID(uuidString: defaultMacID), force: true) }
        .task { controller.loadApps(preferredHostID: UUID(uuidString: defaultMacID)) }
    }

    @ViewBuilder private var emptyState: some View {
        if store.macShortcuts.isEmpty {
            switch store.catalogStatus {
            case .idle, .loading:
                ProgressView("Asking your Mac…")
            case .unavailable:
                ContentUnavailableView("No Mac Online", systemImage: "laptopcomputer.slash",
                                       description: Text("Open PocketDesk on a paired Mac to see its shortcuts."))
            case .failed(let reason):
                ContentUnavailableView("Couldn't Load Shortcuts", systemImage: "exclamationmark.triangle",
                                       description: Text(reason))
            case .loaded:
                ContentUnavailableView("No Shortcuts on This Mac", systemImage: ActionDraft.Kind.macShortcut.symbol,
                                       description: Text("Make one in the Shortcuts app on your Mac, then pull to refresh."))
            }
        } else if shortcuts.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }
}
