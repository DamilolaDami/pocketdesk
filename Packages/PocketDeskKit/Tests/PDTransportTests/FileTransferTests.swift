import Foundation
import PDProtocol
import Testing
@testable import PDTransport

/// `FileSender` into `FileReceiver`, acknowledging as a real receiver would.
struct FileSenderReceiverTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "pd-transfer-\(UUID().uuidString)")

    func file(size: Int) throws -> (URL, Data) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = folder.appending(path: "source.bin")
        try data.write(to: url)
        return (url, data)
    }

    /// Sends `url` into `receiver`, stopping (like a dropped connection) after `stopAfter` chunks.
    func transfer(_ url: URL, size: Int, into receiver: inout FileReceiver, stopAfter: Int = .max) async throws -> Bool {
        let sender = FileSender(id: receiver.id, url: url, size: UInt64(size))
        let (chunks, sink) = AsyncStream<FileChunk>.makeStream()
        let start = receiver.received
        let sending = Task { try await sender.run(from: start) { sink.yield($0) } }
        var count = 0
        for await chunk in chunks {
            count += 1
            if count > stopAfter {
                await sender.stop(.cancelled)
                sending.cancel()
                return false
            }
            switch try receiver.write(chunk) {
            case .more: break
            case .acknowledge(let received): await sender.acknowledge(received)
            case .done:
                try await sending.value
                return true
            }
        }
        return false
    }

    @Test func aFileArrivesWhole() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let size = FileChunk.size * 5 + 123
        let (url, data) = try file(size: size)
        var receiver = try FileReceiver(id: 1, size: UInt64(size), partURL: folder.appending(path: "1.part"))
        #expect(try await transfer(url, size: size, into: &receiver))
        let saved = try receiver.finish(into: folder.appending(path: "out"), name: "photo.heic")
        #expect(saved.lastPathComponent == "photo.heic")
        #expect(try Data(contentsOf: saved) == data)
    }

    @Test func aCutOffTransferResumes() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // Bigger than the window, so the sender has to wait for acknowledgements.
        let size = Int(FileChunk.window) + FileChunk.size * 3 + 9
        let (url, data) = try file(size: size)
        let part = folder.appending(path: "2.part")
        var first = try FileReceiver(id: 2, size: UInt64(size), partURL: part)
        #expect(try await !transfer(url, size: size, into: &first, stopAfter: 6))
        var second = try FileReceiver(id: 2, size: UInt64(size), partURL: part)
        #expect(second.received == UInt64(FileChunk.size * 6))
        #expect(try await transfer(url, size: size, into: &second))
        #expect(try Data(contentsOf: second.finish(into: folder, name: "big.mov")) == data)
    }

    @Test func emptyFilesAndNameClashes() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (url, _) = try file(size: 0)
        for expected in ["notes.txt", "notes 2.txt", "notes 3.txt"] {
            var receiver = try FileReceiver(id: 3, size: 0, partURL: folder.appending(path: "3.part"))
            #expect(try await transfer(url, size: 0, into: &receiver))
            #expect(try receiver.finish(into: folder.appending(path: "out"), name: "notes.txt").lastPathComponent == expected)
        }
    }

    @Test func outOfOrderChunksAreRefused() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var receiver = try FileReceiver(id: 4, size: 10, partURL: folder.appending(path: "4.part"))
        #expect(throws: FileTransferError.corrupted) {
            try receiver.write(FileChunk(id: 4, offset: 5, bytes: [1, 2, 3, 4, 5], isLast: true))
        }
        #expect(throws: FileTransferError.corrupted) {
            try receiver.write(FileChunk(id: 4, offset: 0, bytes: [UInt8](repeating: 0, count: 11), isLast: true))
        }
    }
}
