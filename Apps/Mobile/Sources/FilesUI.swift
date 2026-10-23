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
    /// Fetches under way, by file name: how far along.
    @State private var fetching: [String: Double] = [:]
    @State private var preview: URL?

    var body: some View {
        List {
            if let list {
                ForEach(list.entries) { entry in
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
            }
        }
        .overlay {
            if let problem = list?.problem ?? problem {
                ContentUnavailableView(path.root == nil ? "Nothing Shared" : "Can't Open", systemImage: "folder.badge.questionmark",
                                       description: Text(problem))
            } else if list == nil {
                ProgressView()
            } else if list?.entries.isEmpty == true {
                ContentUnavailableView("Empty Folder", systemImage: "folder")
            }
        }
        .navigationTitle(path.root == nil ? macName : path.title)
        .refreshable { await load() }
        .task { await load() }
        // Quick Look, with Share › Save to Files to keep it.
        .quickLookPreview($preview)
    }

    private func load() async {
        do { list = try await files.list(path) } catch {
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
                problem = String(describing: error)
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
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .movie) == true { return "film" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        if type?.conforms(to: .audio) == true { return "waveform" }
        return "doc"
    }
}
