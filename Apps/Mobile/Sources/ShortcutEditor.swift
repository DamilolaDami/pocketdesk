import PDClientCore
import PDProtocol
import SwiftUI

struct ShortcutDraft: Identifiable {
    var shortcut: Shortcut
    var isNew: Bool
    var id: UUID { shortcut.id }

    static func new() -> ShortcutDraft {
        ShortcutDraft(shortcut: Shortcut(name: "", symbol: "bolt.fill", color: .blue, action: .openURL("")), isNew: true)
    }

    static func editing(_ shortcut: Shortcut) -> ShortcutDraft {
        ShortcutDraft(shortcut: shortcut, isNew: false)
    }
}

/// Create or edit a shortcut: start from a quick pick or build one, with a live preview.
struct ShortcutEditor: View {
    let controller: SessionController
    let isNew: Bool
    let save: (Shortcut) -> Void
    let delete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var shortcut: Shortcut
    @State private var kind: Kind
    @State private var website: String
    @State private var appName: String
    /// Set when picked from the Mac's list or a popular app; typed names go by name.
    @State private var appBundleID: String?
    @State private var keyPreset: String

    private enum Kind: String, CaseIterable {
        case website = "Website", app = "App", control = "Mac Control"
    }

    init(controller: SessionController, draft: ShortcutDraft, save: @escaping (Shortcut) -> Void, delete: (() -> Void)?) {
        self.controller = controller
        isNew = draft.isNew
        _appBundleID = State(initialValue: draft.shortcut.appBundleID)
        self.save = save
        self.delete = delete
        _shortcut = State(initialValue: draft.shortcut)
        let controls = ShortcutPreset.all.filter { $0.category == .controls }
        switch draft.shortcut.action {
        case .openURL(let url):
            _kind = State(initialValue: .website)
            _website = State(initialValue: url.replacing(/^https?:\/\/(www\.)?/, with: ""))
            _appName = State(initialValue: "")
            _keyPreset = State(initialValue: controls[0].id)
        case .openApp(_, let name):
            _kind = State(initialValue: .app)
            _website = State(initialValue: "")
            _appName = State(initialValue: name)
            _keyPreset = State(initialValue: controls[0].id)
        case .keystroke, .media:
            _kind = State(initialValue: .control)
            _website = State(initialValue: "")
            _appName = State(initialValue: "")
            _keyPreset = State(initialValue: controls.first { $0.shortcut.action == draft.shortcut.action }?.id
                                ?? controls[0].id)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ShortcutTile(shortcut: preview,
                                 appIcon: preview.appBundleID.flatMap { controller.store.appIcons[$0] })
                        .frame(width: 180)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                        .animation(.smooth, value: preview)
                }
                .listRowBackground(Color.clear)

                if isNew {
                    Section("Quick Picks") { quickPicks }
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section("Name") {
                    TextField("Netflix", text: $shortcut.name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    Picker("Does", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    actionFields
                } header: {
                    Text("Action")
                } footer: {
                    Text(actionFooter)
                }

                Section("Color") { colorPicker }
                Section("Icon") { iconPicker }

                if let delete {
                    Section {
                        Button("Delete Shortcut", role: .destructive) {
                            delete()
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle(isNew ? "New Shortcut" : "Edit Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        save(preview)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    // MARK: Sections

    private var quickPicks: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ShortcutPreset.all) { preset in
                    Button {
                        apply(preset)
                    } label: {
                        Label(preset.shortcut.name, systemImage: preset.shortcut.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(preset.shortcut.color.tint.gradient, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var actionFields: some View {
        switch kind {
        case .website:
            TextField("netflix.com", text: $website)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .app:
            NavigationLink {
                MacAppPicker(controller: controller, selected: appBundleID) { pick($0) }
            } label: {
                HStack(spacing: 12) {
                    if let appBundleID {
                        AppIconImage(bundleID: appBundleID, png: controller.store.appIcons[appBundleID], size: 30)
                    } else {
                        Image(systemName: "square.grid.3x3.fill").foregroundStyle(Brand.accent).frame(width: 30)
                    }
                    Text(appName.isEmpty ? "Choose an App" : appName)
                        .foregroundStyle(appName.isEmpty ? Brand.accent : .primary)
                }
            }
            TextField("Or type its name", text: Binding(get: { appBundleID == nil ? appName : "" }, set: { name in
                appName = name
                appBundleID = nil
            }))
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
        case .control:
            Picker("Press", selection: $keyPreset) {
                ForEach(controlPresets) { preset in
                    Text("\(preset.shortcut.name)  \(preset.shortcut.action.summary)").tag(preset.id)
                }
            }
            .pickerStyle(.navigationLink)
        }
    }

    private var actionFooter: String {
        switch kind {
        case .website: "Opens in the Mac's default browser."
        case .app: "Opens the app, or brings it to the front if it's already running."
        case .control: "Presses the keys on the Mac. Play / Pause works on whatever is playing, like Netflix in Safari."
        }
    }

    private var colorPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
            ForEach(ShortcutColor.allCases, id: \.self) { color in
                Button {
                    shortcut.color = color
                } label: {
                    Circle()
                        .fill(color.tint.gradient)
                        .frame(width: 38, height: 38)
                        .padding(3)
                        .overlay {
                            if shortcut.color == color {
                                Circle().strokeBorder(color.tint, lineWidth: 2.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(color.rawValue.capitalized)
                .accessibilityAddTraits(shortcut.color == color ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
    }

    private var iconPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
            ForEach(Self.symbols, id: \.self) { symbol in
                Button {
                    shortcut.symbol = symbol
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(shortcut.symbol == symbol ? .white : .primary)
                        .frame(width: 44, height: 44)
                        .background {
                            Circle().fill(shortcut.symbol == symbol
                                          ? AnyShapeStyle(shortcut.color.tint.gradient)
                                          : AnyShapeStyle(.quaternary.opacity(0.6)))
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Building the shortcut

    private var appPresets: [ShortcutPreset] { ShortcutPreset.all.filter { $0.category == .apps } }
    private var controlPresets: [ShortcutPreset] { ShortcutPreset.all.filter { $0.category == .controls } }

    /// The shortcut as it would be saved right now.
    private var preview: Shortcut {
        var result = shortcut
        result.action = action ?? shortcut.action
        return result
    }

    private var action: MacAction? {
        switch kind {
        case .website:
            Self.url(from: website).map(MacAction.openURL)
        case .app:
            appName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .openApp(
                // A picked app keeps its bundle ID (robust to renamed apps); typed ones go by name.
                bundleID: appBundleID ?? appPresets.first { $0.shortcut.name == appName }?.shortcut.appBundleID,
                name: appName.trimmingCharacters(in: .whitespaces))
        case .control:
            controlPresets.first { $0.id == keyPreset }?.shortcut.action
        }
    }

    private var canSave: Bool {
        !shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty && action != nil
    }

    private func apply(_ preset: ShortcutPreset) {
        withAnimation(.smooth) {
            let id = shortcut.id
            shortcut = preset.shortcut
            shortcut.id = id
            switch preset.shortcut.action {
            case .openURL(let url):
                kind = .website
                website = url.replacing(/^https?:\/\/(www\.)?/, with: "")
            case .openApp(let bundleID, let name):
                kind = .app
                appName = name
                appBundleID = bundleID
            case .keystroke, .media:
                kind = .control
                keyPreset = preset.id
            }
        }
    }

    /// An app from the Mac's list: named after it unless you've named the shortcut yourself.
    private func pick(_ app: MacApp) {
        let previousName = appName
        appName = app.name
        appBundleID = app.bundleID
        if shortcut.name.isEmpty || shortcut.name == previousName { shortcut.name = app.name }
        if shortcut.symbol == "bolt.fill" { shortcut.symbol = "app.fill" }
    }

    /// "netflix.com" → "https://netflix.com"; full URLs and app schemes ("spotify:") pass through.
    static func url(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.contains("://") || (!text.contains(".") && text.contains(":")) { return text }
        guard text.contains(".") else { return nil }
        return "https://\(text)"
    }

    private static let symbols = [
        "bolt.fill", "play.tv.fill", "play.rectangle.fill", "film.fill", "sparkles.tv.fill", "music.note",
        "headphones", "gamecontroller.fill", "safari.fill", "globe", "envelope.fill", "message.fill",
        "video.fill", "phone.fill", "calendar", "note.text", "doc.text.fill", "folder.fill",
        "photo.on.rectangle", "camera.fill", "terminal.fill", "hammer.fill", "curlybraces", "number",
        "magnifyingglass", "rectangle.3.group.fill", "arrow.up.left.and.arrow.down.right", "xmark.square.fill",
        "power", "lock.fill", "moon.fill", "speaker.wave.2.fill", "star.fill", "heart.fill",
        "cart.fill", "briefcase.fill",
    ]
}
