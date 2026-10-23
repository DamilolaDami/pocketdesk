#if os(macOS)
import Foundation
import Testing
import PDProtocol
@testable import PDHostCore

struct SharedFoldersTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "pd-shared-\(UUID().uuidString)")
    var desktop: URL { home.appending(path: "Desktop") }
    var documents: URL { home.appending(path: "Documents") }

    func folders(_ enabled: Set<SharedFolder>) throws -> SharedFolders {
        let files = FileManager.default
        try files.createDirectory(at: desktop.appending(path: "Projects"), withIntermediateDirectories: true)
        try files.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: desktop.appending(path: "Report.pdf"))
        try Data("secret".utf8).write(to: documents.appending(path: "Secret.txt"))
        try Data("hidden".utf8).write(to: desktop.appending(path: ".hidden"))
        // Links that lead out of the shared folder, and one that stays inside.
        try files.createSymbolicLink(at: desktop.appending(path: "Escape"), withDestinationURL: documents)
        try files.createSymbolicLink(at: desktop.appending(path: "Shortcut.pdf"), withDestinationURL: desktop.appending(path: "Report.pdf"))
        return SharedFolders(enabled: enabled, locations: [.desktop: desktop, .documents: documents])
    }

    @Test func listsOnlyWhatsShared() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = try folders([.desktop])
        #expect(shared.list(.shared).entries.map(\.name) == ["Desktop"])
        let desktop = shared.list(FolderPath(root: .desktop))
        #expect(desktop.problem == nil)
        // Folders first; no hidden files; no link out of the folder.
        #expect(desktop.entries.map(\.name) == ["Projects", "Report.pdf", "Shortcut.pdf"])
        #expect(desktop.entries.first { $0.name == "Report.pdf" }?.size == 3)
        #expect(shared.list(FolderPath(root: .documents)).problem != nil)
    }

    @Test func pathsCantEscape() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = try folders([.desktop])
        #expect(throws: SharedFolders.Problem.notShared) { try shared.url(for: FolderPath(root: .documents, components: ["Secret.txt"])) }
        #expect(throws: SharedFolders.Problem.notShared) { try shared.url(for: FolderPath(root: .desktop, components: ["..", "Documents"])) }
        #expect(throws: SharedFolders.Problem.notShared) { try shared.url(for: FolderPath(root: .desktop, components: ["Escape", "Secret.txt"])) }
        #expect(throws: SharedFolders.Problem.notFound) { try shared.url(for: FolderPath(root: .desktop, components: ["Gone.pdf"])) }
        #expect(try shared.url(for: FolderPath(root: .desktop, components: ["Shortcut.pdf"])).lastPathComponent == "Shortcut.pdf")
    }

    @Test func nothingIsSharedUntilChosen() {
        let none = SharedFolders(enabled: [], locations: [:])
        #expect(none.list(.shared).entries.isEmpty)
        #expect(none.list(.shared).problem != nil)
    }
}
#endif
