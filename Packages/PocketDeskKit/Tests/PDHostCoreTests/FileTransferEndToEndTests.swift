#if os(macOS)
import Foundation
import Testing
import PDProtocol
import PDSecurity
import PDTransport
@testable import PDClientCore
@testable import PDHostCore

/// The phone's `MacFiles` against a real `HostSession`, over an in-memory link.
@Suite(.timeLimit(.minutes(1)))
struct FileTransferEndToEndTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "pd-files-\(UUID().uuidString)")
    var desktop: URL { root.appending(path: "Desktop") }
    var downloads: URL { root.appending(path: "Downloads") }
    var phoneFolder: URL { root.appending(path: "Phone") }

    /// A streaming-less session with `MacFiles` wired to it, as `ClientConnection.openFiles` does.
    func withMac(shared: Set<SharedFolder> = [.desktop], writable: Set<SharedFolder> = [],
                 mutations: FileMutations = .shared, _ body: (MacFiles) async throws -> Void) async throws {
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        let (hostEnd, phone) = LoopbackSession.pair()
        var configuration = HostSession.Configuration(hostName: "Test")
        let locations: [SharedFolder: URL] = [.desktop: desktop]
        configuration.files = .init(downloads: downloads, incoming: root.appending(path: "Incoming"),
                                    shared: { SharedFolders(enabled: shared, writable: writable, locations: locations) }, mutations: mutations)
        let session = HostSession(session: hostEnd, peer: Fingerprint(bytes: Data(repeating: 6, count: 32)),
                                  configuration: configuration, frameSource: SyntheticFrameSource(),
                                  input: RecordingInputSink(), pairing: TrustEveryone(), clipboard: FakeClipboard())
        let host = Task { try await session.run() }
        let files = MacFiles(folder: phoneFolder, send: { try await phone.send($0) }, sendChunk: { try await phone.send(chunk: $0) })
        let reader = Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        for try await message in phone.controlMessages where MacFiles.handles(message) { await files.receive(message) }
                    } catch {}
                }
                group.addTask {
                    do { for try await chunk in phone.fileChunks { await files.receive(chunk) } } catch {}
                }
            }
        }
        try await phone.send(.hello(Hello(deviceName: "Phone", viewport: Viewport(width: 0, height: 0, scale: 1), mode: .catalog)))
        try await body(files)
        try await phone.send(.bye(reason: "done"))
        try await host.value
        await phone.close()
        reader.cancel()
    }

    func result(_ progress: AsyncThrowingStream<MacFiles.Progress, any Error>) async throws -> MacFiles.Progress? {
        var last: MacFiles.Progress?
        for try await update in progress { last = update }
        return last
    }

    @Test func aPhotoLandsInDownloads() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: phoneFolder, withIntermediateDirectories: true)
        let photo = Data((0..<(FileChunk.size * 3 + 77)).map { UInt8(truncatingIfNeeded: $0) })
        let url = phoneFolder.appending(path: "upload.heic")
        try photo.write(to: url)
        try await withMac { files in
            let first = try await result(files.upload(url, name: "IMG_0042.HEIC"))
            let second = try await result(files.upload(url, name: "IMG_0042.HEIC"))
            #expect(first == .saved(name: "IMG_0042.HEIC"))
            #expect(second == .saved(name: "IMG_0042 2.HEIC"))
        }
        let saved = downloads.appending(path: "IMG_0042.HEIC")
        #expect(try Data(contentsOf: saved) == photo)
        // Gatekeeper checks it before it's opened, like an AirDrop.
        #expect(try saved.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
    }

    @Test func aPDFOnTheDesktopReachesThePhone() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = Data((0..<(FileChunk.size * 2 + 5)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try pdf.write(to: desktop.appending(path: "Report.pdf"))
        try await withMac { files in
            let roots = try await files.list(.shared)
            #expect(roots.entries.map(\.name) == ["Desktop"])
            let folder = FolderPath(root: .desktop)
            let listing = try await files.list(folder)
            let entry = try #require(listing.entries.first { $0.name == "Report.pdf" })
            let outcome = try await result(files.download(entry, in: folder))
            guard case .downloaded(let url) = outcome else {
                Issue.record("not downloaded")
                return
            }
            #expect(url.lastPathComponent == "Report.pdf")
            #expect(try Data(contentsOf: url) == pdf)
        }
    }

    @Test func unsharedFoldersStayClosed() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try await withMac(shared: []) { files in
            let listing = try await files.list(FolderPath(root: .desktop))
            #expect(listing.problem != nil)
            let secret = FileEntry(name: "Secret.txt", isFolder: false, size: 6)
            let download = await files.download(secret, in: FolderPath(root: .desktop))
            await #expect(throws: FileTransferError.self) { try await result(download) }
        }
    }
}
#endif
