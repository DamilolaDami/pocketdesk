import Foundation
import Testing
@testable import PDProtocol

struct FileMutationProtocolTests {
    @Test func managementMessagesRoundTrip() throws {
        let parent = FolderPath(root: .desktop)
        let item = FileMutation.Item(path: parent.appending("Report.pdf"), revision: String(repeating: "a", count: 64))
        let actions: [FileMutation.Action] = [.createFolder(parent: parent, name: "Work"), .rename(item, name: "Final.pdf"),
                                              .move(item, to: parent.appending("Work"), name: "Final.pdf"), .trash(item)]
        let messages: [ControlMessage] = actions.map { .mutateFile(.init(id: 10, action: $0)) } + [
            .fileMutationResult(.init(id: 10)),
            .fileMutationResult(.init(id: 11, problem: .collision, message: "Choose another name.")),
            .fileList(.init(path: parent, entries: [.init(name: "Report.pdf", isFolder: false, revision: item.revision)], canWrite: true))
        ]
        for message in messages {
            #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }

    @Test func namesCannotBecomePathsOrHiddenFiles() {
        for name in ["", ".", "..", "../outside", "a/b", "a\\b", ".hidden", "a:b", "a\0b", "a\nb", " name", "name ", String(repeating: "x", count: 201)] {
            #expect(!FileMutation.validName(name))
        }
        #expect(FileMutation.validName("Project 2026 📁"))
        #expect(FileMutation.validName("Report.final.pdf"))
    }
}
