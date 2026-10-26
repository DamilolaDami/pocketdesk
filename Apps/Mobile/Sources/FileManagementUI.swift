import PDClientCore
import PDProtocol
import SwiftUI

struct FileNameEdit: Identifiable {
    let id = UUID()
    let title: String
    let name: String
    let action: (String) -> FileMutation.Action

    static func create(in path: FolderPath) -> Self {
        Self(title: "New Folder", name: "", action: { .createFolder(parent: path, name: $0) })
    }

    static func rename(_ entry: FileEntry, in path: FolderPath) -> Self {
        Self(title: "Rename", name: entry.name,
             action: { .rename(.init(path: path.appending(entry.name), revision: entry.revision ?? ""), name: $0) })
    }
}

struct FileNameSheet: View {
    let edit: FileNameEdit
    let change: (FileMutation.Action) async -> FileMutationResult?
    @State private var name = ""
    @State private var problem: String?
    @State private var busy = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .disabled(busy)
                } header: { Text("Name") } footer: {
                    Text("Choose a different name if one already exists. Existing items are never replaced.")
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .navigationTitle(edit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : "Save") {
                        busy = true
                        focused = false
                        Task {
                            if let result = await change(edit.action(name)) {
                                problem = result.message
                                busy = false
                            } else { dismiss() }
                        }
                    }
                    .disabled(busy || !FileMutation.validName(name) || name == edit.name)
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .onAppear { name = edit.name; focused = true }
    }
}

/// A destination picker confined to this item's root. The user can change the destination
/// name here to resolve a collision without ever replacing the existing item.
struct FileMoveSheet: View {
    let files: MacFiles
    let item: FileMutation.Item
    let change: (FileMutation.Action) async -> FileMutationResult?
    @State private var path: FolderPath
    @State private var list: FileList?
    @State private var name: String
    @State private var problem: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    init(files: MacFiles, item: FileMutation.Item, change: @escaping (FileMutation.Action) async -> FileMutationResult?) {
        self.files = files; self.item = item; self.change = change
        _path = State(initialValue: FolderPath(root: item.path.root))
        _name = State(initialValue: item.path.title)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Move “\(item.path.title)”") {
                    TextField("Destination name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Destination: \(path.components.isEmpty ? path.title : path.components.joined(separator: " / "))") {
                    if !path.components.isEmpty {
                        Button("Enclosing Folder", systemImage: "arrow.up") { path.components.removeLast() }
                    }
                    ForEach((list?.entries ?? []).filter { $0.isFolder && path.appending($0.name) != item.path }) { folder in
                        Button { path = path.appending(folder.name) } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                    if list == nil { ProgressView("Loading…") }
                    if let message = list?.problem { Text(message).foregroundStyle(.secondary) }
                    if list?.canWrite == false, list?.problem == nil {
                        Text("This destination is read-only. Allow file changes on the Mac.").foregroundStyle(.secondary)
                    }
                }
                if let problem { Section { Text(problem).foregroundStyle(.red) } }
            }
            .disabled(busy)
            .navigationTitle("Move Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Moving…" : "Move Here") {
                        busy = true
                        Task {
                            if let result = await change(.move(item, to: path, name: name)) {
                                problem = result.message
                                list = try? await files.list(path)
                                busy = false
                            } else { dismiss() }
                        }
                    }
                    .disabled(busy || list?.canWrite != true || list?.problem != nil || !FileMutation.validName(name)
                              || path.appending(name) == item.path)
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .task(id: path) {
            let requestedPath = path
            list = nil
            do {
                let result = try await files.list(requestedPath)
                guard !Task.isCancelled, path == requestedPath else { return }
                list = result
            } catch {
                guard !Task.isCancelled else { return }
                problem = "The Mac went away. Close Files and reconnect before trying again."
            }
        }
    }
}
