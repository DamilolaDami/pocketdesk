#if os(macOS)
import Foundation
import Synchronization
import Testing
import PDProtocol
@testable import PDHostCore

struct FileMutationTests {
    let root = URL.temporaryDirectory.appending(path: "pd-mutations-\(UUID())")
    var desktop: URL { root.appending(path: "Desktop") }
    var documents: URL { root.appending(path: "Documents") }

    func setup() throws -> SharedFolders {
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        return SharedFolders(enabled: [.desktop, .documents], writable: [.desktop],
                             locations: [.desktop: desktop, .documents: documents])
    }

    func item(_ name: String, folder: FolderPath = .init(root: .desktop), shared: SharedFolders) throws -> FileMutation.Item {
        let entry = try #require(shared.list(folder).entries.first { $0.name == name })
        return .init(path: folder.appending(name), revision: try #require(entry.revision))
    }

    @Test func createsRenamesAndMovesWithoutReplacingAnything() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try setup(), directory = FolderPath(root: .desktop)
        let mutations = FileMutations()
        #expect(shared.list(directory).canWrite)
        #expect(!shared.list(.init(root: .documents)).canWrite)
        let created = await mutations.apply(.init(id: 1, action: .createFolder(parent: directory, name: "Projects")), folders: { shared })
        #expect(created.problem == nil)
        try Data("original".utf8).write(to: desktop.appending(path: "Report.txt"))
        try Data("existing".utf8).write(to: desktop.appending(path: "Taken.txt"))
        let original = try item("Report.txt", shared: shared)
        let conflict = await mutations.apply(.init(id: 2, action: .rename(original, name: "Taken.txt")), folders: { shared })
        #expect(conflict.problem == .collision)
        #expect(try String(contentsOf: desktop.appending(path: "Taken.txt"), encoding: .utf8) == "existing")
        #expect(try String(contentsOf: desktop.appending(path: "Report.txt"), encoding: .utf8) == "original")
        let renamed = await mutations.apply(.init(id: 3, action: .rename(original, name: "Final.txt")), folders: { shared })
        #expect(renamed.problem == nil)
        let current = try item("Final.txt", shared: shared)
        let moved = await mutations.apply(.init(id: 4, action: .move(current, to: directory.appending("Projects"), name: "Final.txt")), folders: { shared })
        #expect(moved.problem == nil)
        #expect(!FileManager.default.fileExists(atPath: desktop.appending(path: "Final.txt").path))
        #expect(try String(contentsOf: desktop.appending(path: "Projects/Final.txt"), encoding: .utf8) == "original")
        let duplicate = await mutations.apply(.init(id: 5, action: .createFolder(parent: directory, name: "Projects")), folders: { shared })
        #expect(duplicate.problem == .collision)
    }

    @Test func revokedGrantsAndChangedFilesAreRejectedAtExecution() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try setup()
        let mutations = FileMutations()
        let url = desktop.appending(path: "Draft.txt")
        try Data("first".utf8).write(to: url)
        let original = try item("Draft.txt", shared: shared)
        try FileManager.default.removeItem(at: url)
        try Data("other".utf8).write(to: url)
        let changed = await mutations.apply(.init(id: 1, action: .trash(original)), folders: { shared })
        #expect(changed.problem == .changed)
        #expect(FileManager.default.fileExists(atPath: url.path))
        var readOnly = shared
        readOnly.writable = []
        let permissions = Mutex(readOnly)
        let denied = await mutations.apply(.init(id: 2, action: .createFolder(parent: .init(root: .desktop), name: "Denied")),
                                          folders: { permissions.withLock { $0 } })
        #expect(denied.problem == .readOnly)
        #expect(!FileManager.default.fileExists(atPath: desktop.appending(path: "Denied").path))
        #expect(SharedFolders(enabled: [.desktop], locations: shared.locations).writable.isEmpty)
    }

    @Test func traversalSymlinksAndCrossRootMovesStayClosed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try setup(), mutations = FileMutations()
        try Data("secret".utf8).write(to: documents.appending(path: "Secret.txt"))
        try FileManager.default.createSymbolicLink(at: desktop.appending(path: "Escape"), withDestinationURL: documents)
        try FileManager.default.createSymbolicLink(at: desktop.appending(path: "Inside"), withDestinationURL: desktop)
        for link in ["Escape", "Inside"] {
            let result = await mutations.apply(.init(id: 1, action: .createFolder(parent: .init(root: .desktop, components: [link]), name: "No")), folders: { shared })
            #expect(result.problem == .invalid)
            #expect(!shared.list(.init(root: .desktop, components: [link])).canWrite)
        }
        let secret = try item("Secret.txt", folder: .init(root: .documents), shared: shared)
        let forged = FileMutation.Item(path: .init(root: .desktop, components: ["../Documents/Secret.txt"]), revision: secret.revision)
        let traversal = await mutations.apply(.init(id: 2, action: .trash(forged)), folders: { shared })
        #expect(traversal.problem == .invalid)
        try Data("public".utf8).write(to: desktop.appending(path: "Public.txt"))
        let source = try item("Public.txt", shared: shared)
        let crossRoot = await mutations.apply(.init(id: 3, action: .move(source, to: .init(root: .documents), name: "Public.txt")), folders: { shared })
        #expect(crossRoot.problem == .differentRoot)
        #expect(try String(contentsOf: documents.appending(path: "Secret.txt"), encoding: .utf8) == "secret")
        #expect(FileManager.default.fileExists(atPath: desktop.appending(path: "Public.txt").path))
    }

    @Test func cannotMoveAFolderIntoItselfOrMutateTheSharedRoot() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try setup(), mutations = FileMutations()
        try FileManager.default.createDirectory(at: desktop.appending(path: "Parent/Child"), withIntermediateDirectories: true)
        let parent = try item("Parent", shared: shared)
        let result = await mutations.apply(.init(id: 1, action: .move(parent, to: parent.path.appending("Child"), name: "Parent")), folders: { shared })
        #expect(result.problem == .invalid)
        let rootItem = FileMutation.Item(path: .init(root: .desktop), revision: String(repeating: "a", count: 64))
        let rootResult = await mutations.apply(.init(id: 2, action: .trash(rootItem)), folders: { shared })
        #expect(rootResult.problem == .invalid)
    }

    @Test func trashUsesTheMacTrashAndTheItemCanBeRecovered() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = try setup()
        let url = desktop.appending(path: "PocketDesk-test-\(UUID()).txt")
        try Data("recoverable".utf8).write(to: url)
        let source = try item(url.lastPathComponent, shared: shared)
        let trashed = Mutex<URL?>(nil)
        let mutations = FileMutations { reference in
            var result: NSURL?
            try FileManager.default.trashItem(at: reference, resultingItemURL: &result)
            trashed.withLock { $0 = result as URL? }
        }
        let result = await mutations.apply(.init(id: 1, action: .trash(source)), folders: { shared })
        #expect(result.problem == nil)
        let trashURL = try #require(trashed.withLock { $0 })
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: trashURL, encoding: .utf8) == "recoverable")
        try FileManager.default.moveItem(at: trashURL, to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
