#if os(macOS)
import Foundation
import Synchronization
import Testing
import PDProtocol
import PDTransport
@testable import PDClientCore
@testable import PDHostCore

@Suite(.timeLimit(.minutes(1)))
struct FileMutationEndToEndTests {
    @Test func phoneCanOrganizeAndTrashFilesThroughTheHostSession() async throws {
        let fixture = FileTransferEndToEndTests()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.desktop, withIntermediateDirectories: true)
        try Data("report".utf8).write(to: fixture.desktop.appending(path: "Draft.txt"))
        let recovered = fixture.root.appending(path: "Recovered.txt")
        let mutations = FileMutations { try FileManager.default.moveItem(at: $0, to: recovered) }
        try await fixture.withMac(writable: [.desktop], mutations: mutations) { files in
            let path = FolderPath(root: .desktop)
            let initial = try await files.list(path)
            #expect(initial.canWrite)
            let draft = try #require(initial.entries.first { $0.name == "Draft.txt" })
            let source = FileMutation.Item(path: path.appending(draft.name), revision: try #require(draft.revision))
            #expect(try await files.mutate(.createFolder(parent: path, name: "Work")).problem == nil)
            #expect(try await files.mutate(.rename(source, name: "Final.txt")).problem == nil)
            let renamedList = try await files.list(path)
            let renamed = try #require(renamedList.entries.first { $0.name == "Final.txt" })
            #expect(!renamedList.entries.contains { $0.name == "Draft.txt" })
            let current = FileMutation.Item(path: path.appending(renamed.name), revision: try #require(renamed.revision))
            #expect(try await files.mutate(.move(current, to: path.appending("Work"), name: "Final.txt")).problem == nil)
            let movedList = try await files.list(path.appending("Work"))
            let moved = try #require(movedList.entries.first)
            let movedItem = FileMutation.Item(path: path.appending("Work").appending(moved.name), revision: try #require(moved.revision))
            #expect(try await files.mutate(.trash(movedItem)).problem == nil)
            #expect(try await files.list(path.appending("Work")).entries.isEmpty)
        }
        #expect(try String(contentsOf: recovered, encoding: .utf8) == "report")
    }

    @Test func readOnlyHostRefusesAPhoneThatSendsMutationMessagesAnyway() async throws {
        let fixture = FileTransferEndToEndTests()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.withMac { files in
            let path = FolderPath(root: .desktop)
            #expect(try await !files.list(path).canWrite)
            let denied = try await files.mutate(.createFolder(parent: path, name: "Blocked"))
            #expect(denied.problem == .readOnly)
            #expect(try await files.list(path).entries.isEmpty)
        }
    }

    @Test func failedSendDoesNotLeaveThePhoneWaiting() async throws {
        let files = MacFiles(send: { _ in throw TransportError.closed }, sendChunk: { _ in })
        await #expect(throws: TransportError.self) {
            try await files.mutate(.createFolder(parent: .init(root: .desktop), name: "Work"))
        }
        await files.end()
    }

    @Test func anUnconfirmedMutationTimesOutWithoutRetrying() async throws {
        let sent = Mutex(0)
        let files = MacFiles(requestTimeout: .milliseconds(20), send: { _ in sent.withLock { $0 += 1 } }, sendChunk: { _ in })
        await #expect(throws: FileTransferError.self) {
            try await files.mutate(.createFolder(parent: .init(root: .desktop), name: "Work"))
        }
        #expect(sent.withLock { $0 } == 1)
        await files.end()
    }

    @Test func refreshFailuresAreBoundedToo() async throws {
        let files = MacFiles(requestTimeout: .milliseconds(20), send: { _ in }, sendChunk: { _ in })
        await #expect(throws: FileTransferError.self) { try await files.list(.init(root: .desktop)) }
        await files.end()
    }
}
#endif
