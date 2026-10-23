import Foundation
import Testing
@testable import PDProtocol

struct FileTransferTests {
    @Test(arguments: [[UInt8](), [1, 2, 3], [UInt8](repeating: 7, count: FileChunk.size)])
    func chunksRoundTrip(_ bytes: [UInt8]) throws {
        let chunk = FileChunk(id: 0xDEAD_BEEF_0000_0001, offset: 1 << 40, bytes: bytes, isLast: bytes.count == 3)
        #expect(try FileChunk(decoding: chunk.encoded()) == chunk)
    }

    @Test func malformedChunksAreRefused() {
        let chunk = FileChunk(id: 1, offset: 0, bytes: [1, 2, 3], isLast: true).encoded()
        #expect(throws: WireError.truncated) { try FileChunk(decoding: chunk.prefix(10)) }
        // Says three bytes, carries two.
        #expect(throws: WireError.invalidValue) { try FileChunk(decoding: chunk.dropLast()) }
    }

    @Test func safeNames() {
        #expect(FileOffer.safeName("IMG_0042.HEIC") == "IMG_0042.HEIC")
        #expect(FileOffer.safeName("../../etc/passwd") == "-..-etc-passwd")
        #expect(FileOffer.safeName(".hidden") == "hidden")
        #expect(FileOffer.safeName("a\u{0}b:c\\d") == "a-b-c-d")
        #expect(FileOffer.safeName("   ") == "File")
        let long = FileOffer.safeName(String(repeating: "é", count: 300) + ".pdf")
        #expect(long.utf8.count <= 200)
        #expect(long.hasSuffix(".pdf"))
    }

    @Test func pathsCantLeaveTheirFolder() {
        #expect(FolderPath(root: .desktop, components: ["Projects", "a.pdf"]).isValid)
        #expect(FolderPath.shared.isValid)
        #expect(!FolderPath(root: .desktop, components: [".."]).isValid)
        #expect(!FolderPath(root: .desktop, components: ["a/b"]).isValid)
        #expect(!FolderPath(root: .desktop, components: [""]).isValid)
        #expect(!FolderPath(root: nil, components: ["Users"]).isValid)
    }

    @Test func transferIDsFollowTheFile() {
        let path = FolderPath(root: .documents, components: ["Taxes"])
        let file = FileEntry(name: "2026.pdf", isFolder: false, size: 1_000, modified: 1_790_000_000)
        #expect(file.transferID(at: path) == file.transferID(at: path))
        var edited = file
        edited.modified += 1
        #expect(edited.transferID(at: path) != file.transferID(at: path))
        #expect(file.transferID(at: FolderPath(root: .desktop, components: ["Taxes"])) != file.transferID(at: path))
    }

    @Test func windowBoundsWhatsInFlight() {
        var window = TransferWindow(startingAt: 100)
        #expect(window.canSend(Int(FileChunk.window) * 2)) // nothing out: always room
        for _ in 0..<16 {
            #expect(window.canSend(FileChunk.size))
            window.didSend(FileChunk.size)
        }
        #expect(!window.canSend(1))
        window.acknowledge(100 + UInt64(FileChunk.size))
        #expect(window.canSend(FileChunk.size))
        // Acknowledgements never go backwards or past what was sent.
        window.acknowledge(0)
        window.acknowledge(.max)
        #expect(window.acknowledged == window.sent)
    }

    @Test func messagesRoundTrip() throws {
        let path = FolderPath(root: .downloads, components: ["Invoices"])
        let messages: [ControlMessage] = [
            .sendFile(FileOffer(id: 9, name: "photo.heic", size: 4_000_000)),
            .fileAccepted(id: 9, offset: 1_048_576),
            .getFile(FileRequest(id: 10, path: path.appending("a.pdf"), offset: 0)),
            .fileOffer(FileOffer(id: 10, name: "a.pdf", size: 12)),
            .fileData("AAEC"), .fileProgress(id: 9, received: 2_097_152),
            .fileSaved(id: 9, name: "photo 2.heic"), .fileFailed(id: 10, reason: "Cancelled"),
            .listFiles(.shared), .listFiles(path),
            .fileList(FileList(path: path, entries: [FileEntry(name: "a.pdf", isFolder: false, size: 12, modified: 5)])),
            .fileList(FileList(path: .shared, entries: [], problem: "No folders are shared.")),
        ]
        for message in messages {
            #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }
}
