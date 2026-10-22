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

    /// A quick pick, filled in and ready to save or tweak.
    static func from(_ preset: ShortcutPreset) -> ShortcutDraft {
        ShortcutDraft(shortcut: preset.shortcut.copy(), isNew: true)
    }

    /// One of the Mac's Shortcuts-app shortcuts as a tile.
    static func from(_ macShortcut: MacShortcut) -> ShortcutDraft {
        ShortcutDraft(shortcut: Shortcut(name: macShortcut.name, symbol: "square.stack.3d.up.fill", color: .indigo,
                                         action: .runShortcut(id: macShortcut.id, name: macShortcut.name)), isNew: true)
    }

    static func editing(_ shortcut: Shortcut) -> ShortcutDraft {
        ShortcutDraft(shortcut: shortcut, isNew: false)
    }
}

/// Create or edit a shortcut, with a live preview. New ones usually start from a quick pick.
/// The first step is edited in place; more steps ("Then") make it a routine.
struct ShortcutEditor: View {
    let controller: SessionController
    let isNew: Bool
    let save: (Shortcut) -> Void
    let delete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var shortcut: Shortcut
    @State private var first: ActionDraft
    @State private var more: [StepDraft]

    init(controller: SessionController, draft: ShortcutDraft, save: @escaping (Shortcut) -> Void, delete: (() -> Void)?) {
        self.controller = controller
        isNew = draft.isNew
        self.save = save
        self.delete = delete
        _shortcut = State(initialValue: draft.shortcut)
        if case .steps(let steps) = draft.shortcut.action, let head = steps.first {
            _first = State(initialValue: ActionDraft(head))
            _more = State(initialValue: steps.dropFirst().map { StepDraft(draft: ActionDraft($0)) })
        } else {
            _first = State(initialValue: ActionDraft(draft.shortcut.action))
            _more = State(initialValue: [])
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

                Section("Name") {
                    TextField("Netflix", text: $shortcut.name)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    ActionFields(controller: controller, draft: $first, kinds: ActionDraft.Kind.actions,
                                 picked: named)
                } header: {
                    Text(more.isEmpty ? "Action" : "First")
                } footer: {
                    Text(first.footer)
                }

                Section {
                    ForEach($more) { $step in
                        StepRow(controller: controller, step: $step)
                    }
                    .onDelete { more.remove(atOffsets: $0) }
                    .onMove { more.move(fromOffsets: $0, toOffset: $1) }
                    if more.count + 1 < MacAction.maxSteps {
                        Menu {
                            ForEach(ActionDraft.Kind.allCases.reversed(), id: \.self) { kind in
                                Button(kind.stepTitle, systemImage: kind.symbol) {
                                    withAnimation { more.append(StepDraft(draft: ActionDraft(kind: kind))) }
                                }
                            }
                        } label: {
                            Label("Add Step", systemImage: "plus.circle.fill")
                        }
                    }
                } header: {
                    if !more.isEmpty { Text("Then") }
                } footer: {
                    Text(more.isEmpty
                         ? "Add steps to make a routine, like opening Netflix, waiting a moment, then going full screen."
                         : "Steps run in order. If one can't be done, the rest are skipped.")
                }

                Section {
                    Toggle("Show the Mac", isOn: Binding(
                        get: { preview.opensStream },
                        set: { shortcut.showsMac = $0 }))
                } footer: {
                    Text(preview.opensStream
                         ? "Opens the stream so you can see it happen."
                         : "Runs in the background. You stay where you are.")
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

    /// The shortcut as it would be saved right now.
    private var preview: Shortcut {
        var result = shortcut
        result.action = action ?? shortcut.action
        return result
    }

    private var action: MacAction? {
        guard let head = first.action else { return nil }
        if more.isEmpty { return head }
        let rest = more.compactMap(\.draft.action)
        guard rest.count == more.count else { return nil }
        return .steps([head] + rest)
    }

    private var canSave: Bool {
        !shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty && action?.isValid == true
    }

    /// A Mac app or Mac Shortcut picked for the first step: the shortcut takes its name
    /// unless you've named it yourself.
    private func named(_ name: String, previous: String, symbol: String) {
        if shortcut.name.isEmpty || shortcut.name == previous { shortcut.name = name }
        if shortcut.symbol == "bolt.fill" { shortcut.symbol = symbol }
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

