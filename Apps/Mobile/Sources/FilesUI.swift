import PDClientCore
import PDProtocol
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A photo, video or file copied out of the picker so it can be read while it's sent.
struct PickedFile: Transferable {
    let file: OutgoingFile

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { PickedFile(file: try copy($0.file)) }
        FileRepresentation(importedContentType: .image) { PickedFile(file: try copy($0.file)) }
        FileRepresentation(importedContentType: .item) { PickedFile(file: try copy($0.file)) }
    }

    /// The picker's file only lasts until this returns.
    static func copy(_ url: URL) throws -> OutgoingFile {
        let folder = URL.temporaryDirectory.appending(path: "Outgoing/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appending(path: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return OutgoingFile(url: copy, isTemporary: true)
    }
}

/// Send Photos and Send Files: the pickers, then the files go to `hostID`'s Downloads folder
/// (or the Mac being streamed when it's `nil`).
struct SendToMac: ViewModifier {
    let controller: SessionController
    let hostID: UUID?
    @Binding var choosingPhotos: Bool
    @Binding var choosingFiles: Bool
    @State private var photos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 20,
                          preferredItemEncoding: .current)
            .onChange(of: photos) {
                guard !photos.isEmpty else { return }
                let items = photos
                photos = []
                Task {
                    var files: [OutgoingFile] = []
                    for item in items {
                        if let picked = try? await item.loadTransferable(type: PickedFile.self) { files.append(picked.file) }
                    }
                    if files.count < items.count {
                        controller.store.post(notice: "Some of those couldn't be read, so they weren't sent.")
                    }
                    controller.sendInBackground(files, to: hostID)
                }
            }
            .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                let files = urls.compactMap { url -> OutgoingFile? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try? PickedFile.copy(url)
                }
                controller.sendInBackground(files, to: hostID)
            }
    }
}

extension View {
    func sendToMac(_ controller: SessionController, hostID: UUID?, photos: Binding<Bool>, files: Binding<Bool>) -> some View {
        modifier(SendToMac(controller: controller, hostID: hostID, choosingPhotos: photos, choosingFiles: files))
    }
}

/// What's on its way to the Mac, over whatever screen is up.
struct TransfersBanner: View {
    let transfers: [FileTransferStatus]

    var body: some View {
        if let transfer = transfers.last {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill").foregroundStyle(Brand.accent)
                    Text(transfer.count > 1 ? "Sending \(transfer.position) of \(transfer.count) to \(transfer.macName)"
                                            : "Sending to \(transfer.macName)")
                        .font(.footnote.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(transfer.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: transfer.fraction)
                Text(transfer.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(14)
            .frame(maxWidth: 420)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The folders a Mac shares, to browse and fetch files from. Holds a connection to the Mac
/// (or uses the stream's) while it's open.
struct MacFilesBrowser: View {
    let controller: SessionController
    let hostID: UUID?
    let dismiss: () -> Void
    @State private var link: SessionController.FilesLink?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Group {
                if let link {
                    FolderView(files: link.files, path: .shared, macName: link.macName)
                } else if let problem {
                    ContentUnavailableView("Can't Open Files", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text(problem))
                } else {
                    ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Mac Files")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FolderPath.self) { path in
                if let link { FolderView(files: link.files, path: path, macName: link.macName) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: dismiss)
                }
            }
        }
        .task {
            do { link = try await controller.openFiles(on: hostID) } catch {
                problem = String(describing: error)
            }
        }
        .onDisappear { link?.close() }
    }
}

private struct FolderView: View {
    let files: MacFiles
    let path: FolderPath
    let macName: String
    @State private var list: FileList?
    @State private var problem: String?
    @State private var options = FileBrowserOptions()
    @State private var downloadProblem: String?
    /// Fetches under way, by file name: how far along.
    @State private var fetching: [String: Double] = [:]
    @State private var preview: URL?
    @State private var naming: FileNameEdit?
    @State private var moving: FileEntry?
    @State private var trashing: FileEntry?
    @State private var changing = false

    var body: some View {
        let entries = options.applying(to: list?.entries ?? [])
        List {
            if let list, !list.entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        Group {
                            if entry.isFolder {
                                NavigationLink(value: entry.isFolder && path.root == nil
                                               ? FolderPath(root: SharedFolder.allCases.first { $0.name == entry.name })
                                               : path.appending(entry.name)) {
                                    FileRow(entry: entry, progress: nil)
                                }
                            } else {
                                Button { fetch(entry) } label: { FileRow(entry: entry, progress: fetching[entry.name]) }
                                    .foregroundStyle(.primary)
                                    .disabled(fetching[entry.name] != nil)
                            }
                        }
                        .contextMenu {
                            if list.canWrite, entry.revision != nil {
                                Button("Rename", systemImage: "pencil") { naming = .rename(entry, in: path) }
                                Button("Move…", systemImage: "folder") { moving = entry }
                                Button("Move to Trash…", systemImage: "trash", role: .destructive) { trashing = entry }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(path.root == nil ? "Shared Folders" : options.kind.title)
                        Spacer()
                        Text(options.isFiltering ? "\(entries.count) of \(list.entries.count)" : "\(entries.count) items")
                            .monospacedDigit()
                    }
                } footer: {
                    if path.root != nil {
                        Text("Search and filters apply to this folder only.")
                        if !list.canWrite { Text("Read-only. Allow file changes from PocketDesk's Mac menu to organize these files.") }
                    }
                }
            }
        }
        .disabled(changing)
        .overlay {
            if let problem = list?.problem ?? problem {
                ContentUnavailableView(path.root == nil ? "Nothing Shared" : "Can't Open", systemImage: "folder.badge.questionmark",
                                       description: Text(problem))
            } else if list == nil {
                ProgressView()
            } else if list?.entries.isEmpty == true {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label(options.searchText.isEmpty ? "No \(options.kind.title)" : "No Matching Items",
                          systemImage: options.searchText.isEmpty ? options.kind.symbol : "magnifyingglass")
                } description: {
                    Text(options.searchText.isEmpty
                         ? "There are no \(options.kind.title.lowercased()) in this folder. Try another file type."
                         : "Nothing in this folder matches “\(options.searchText)”\(options.kind == .all ? "." : " in \(options.kind.title.lowercased()).")")
                } actions: {
                    Button("Reset Search and Filters") { options.query = ""; options.kind = .all }
                        .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle(path.root == nil ? macName : path.title)
        .searchable(text: $options.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: path.root == nil ? "Search shared folders" : "Search this folder")
        .toolbar {
            if path.root != nil {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                if list?.canWrite == true {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New Folder", systemImage: "folder.badge.plus") { naming = .create(in: path) }
                    }
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        // Quick Look, with Share › Save to Files to keep it.
        .quickLookPreview($preview)
        .sheet(item: $naming) { edit in
            FileNameSheet(edit: edit) { action in await change(action) }
        }
        .sheet(item: $moving) { entry in
            if let revision = entry.revision {
                FileMoveSheet(files: files, item: .init(path: path.appending(entry.name), revision: revision)) { action in
                    await change(action)
                }
            }
        }
        .confirmationDialog("Move “\(trashing?.name ?? "")” to the Mac's Trash?",
                            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
                            titleVisibility: .visible) {
            if let entry = trashing, let revision = entry.revision {
                Button("Move to Trash", role: .destructive) {
                    Task {
                        let result = await change(.trash(.init(path: path.appending(entry.name), revision: revision)))
                        if let result { downloadProblem = result.message ?? "The Mac couldn't move “\(entry.name)” to Trash." }
                    }
                }
            }
            Button("Cancel", role: .cancel) { trashing = nil }
        } message: {
            Text("You can recover it from Trash on the Mac. Folders include everything inside them.")
        }
        .alert("Couldn’t Complete Action", isPresented: Binding(get: { downloadProblem != nil }, set: { if !$0 { downloadProblem = nil } })) {
            Button("OK", role: .cancel) { downloadProblem = nil }
        } message: {
            Text(downloadProblem ?? "")
        }
    }

    /// Always refresh after an attempt, including a rejected or unconfirmed change.
    /// A nil result means confirmed success; errors leave the editor open for correction.
    private func change(_ action: FileMutation.Action) async -> FileMutationResult? {
        changing = true
        defer { changing = false }
        let result: FileMutationResult
        do { result = try await files.mutate(action) }
        catch { result = .init(id: 0, problem: .failed, message: String(describing: error)) }
        await load()
        return result.problem == nil ? nil : result
    }

    private var filterMenu: some View {
        Menu {
            Picker("File Type", selection: $options.kind) {
                ForEach(FileBrowserOptions.Kind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            Picker("Sort By", selection: $options.sort) {
                ForEach(FileBrowserOptions.Sort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            Section {
                Text(options.sort == .newest ? "Newest first · Folders first"
                     : options.sort == .largest ? "Largest first · Folders first" : "A–Z · Folders first")
                if options.kind != .all || options.sort != .newest {
                    Button("Reset Filters and Sort", systemImage: "arrow.counterclockwise") {
                        options.kind = .all
                        options.sort = .newest
                    }
                }
            }
        } label: {
            Label("Filter and Sort", systemImage: options.kind == .all && options.sort == .newest
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .tint(options.kind == .all && options.sort == .newest ? .primary : Brand.accent)
        .accessibilityValue("\(options.kind.title), sorted by \(options.sort.title)")
        .disabled(list == nil || list?.problem != nil || problem != nil)
    }

    private func load() async {
        do {
            list = try await files.list(path)
            problem = nil
        } catch {
            problem = "The Mac went away. Close this and open it again."
        }
    }

    private func fetch(_ entry: FileEntry) {
        fetching[entry.name] = 0
        Task {
            do {
                for try await progress in await files.download(entry, in: path) {
                    switch progress {
                    case .transferring(let done, let total):
                        fetching[entry.name] = total == 0 ? 1 : Double(done) / Double(total)
                    case .downloaded(let url):
                        preview = url
                    case .saved:
                        break
                    }
                }
            } catch {
                downloadProblem = String(describing: error)
            }
            fetching[entry.name] = nil
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    /// 0...1 while it's being fetched.
    let progress: Double?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isFolder ? "folder.fill" : symbol)
                .font(.title3)
                .foregroundStyle(entry.isFolder ? Brand.accent : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(2)
                if !entry.isFolder {
                    Group {
                        if let progress {
                            ProgressView(value: progress)
                        } else {
                            Text("\(entry.size.formatted(.byteCount(style: .file))) · \(Date(timeIntervalSince1970: TimeInterval(entry.modified)).formatted(date: .abbreviated, time: .omitted))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        FileBrowserOptions.kind(of: entry).symbol
    }
}
