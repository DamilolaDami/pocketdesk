import Foundation
import PDProtocol
import PDTransport

/// File transfers with one Mac: sending files to its Downloads folder, and browsing and
/// fetching from the folders it shares. Works over a stream (`ClientConnection` feeds it) or
/// a quick connection of its own (`ClientConnection.openFiles`).
public actor MacFiles: Equatable {
    public static func == (a: MacFiles, b: MacFiles) -> Bool { a === b }

    public enum Progress: Sendable, Equatable {
        case transferring(done: UInt64, total: UInt64)
        /// Sent: the Mac saved it in Downloads under this name.
        case saved(name: String)
        /// Fetched: it's on the phone at this URL.
        case downloaded(URL)
    }

    private struct Upload {
        let sender: FileSender
        let size: UInt64
        let progress: AsyncThrowingStream<Progress, any Error>.Continuation
        var task: Task<Void, Never>?
    }

    private struct Download {
        var receiver: FileReceiver
        let name: String
        let progress: AsyncThrowingStream<Progress, any Error>.Continuation
    }

    private let send: @Sendable (ControlMessage) async throws -> Void
    private let sendChunk: @Sendable (FileChunk) async throws -> Void
    /// Fetched files, and unfinished ones waiting to resume.
    private let folder: URL
    private var lists: [FolderPath: [CheckedContinuation<FileList, any Error>]] = [:]
    private var uploads: [UInt64: Upload] = [:]
    private var downloads: [UInt64: Download] = [:]
    private var ended: (any Error)?
    private var mutations: [UInt64: CheckedContinuation<FileMutationResult, any Error>] = [:]
    private var listGenerations: [FolderPath: UUID] = [:]
    private let requestTimeout: Duration

    public init(folder: URL = URL.cachesDirectory.appending(path: "PocketDesk/Files"),
                requestTimeout: Duration = .seconds(30),
                send: @escaping @Sendable (ControlMessage) async throws -> Void,
                sendChunk: @escaping @Sendable (FileChunk) async throws -> Void) {
        self.folder = folder
        self.requestTimeout = requestTimeout
        self.send = send
        self.sendChunk = sendChunk
    }

    // MARK: Browsing

    public func list(_ path: FolderPath) async throws -> FileList {
        if let ended { throw ended }
        return try await withCheckedThrowingContinuation { continuation in
            lists[path, default: []].append(continuation)
            if lists[path]?.count == 1 {
                let generation = UUID()
                listGenerations[path] = generation
                Task {
                    do { try await self.send(.listFiles(path)) }
                    catch { self.finishList(path, generation: generation, error: error) }
                }
                Task {
                    try? await Task.sleep(for: requestTimeout)
                    self.finishList(path, generation: generation, error: FileTransferError.stopped("The Mac didn't answer. Reconnect and refresh the folder."))
                }
            }
        }
    }

    private func finishList(_ path: FolderPath, generation: UUID, error: any Error) {
        guard listGenerations[path] == generation else { return }
        listGenerations[path] = nil
        for waiter in lists.removeValue(forKey: path) ?? [] { waiter.resume(throwing: error) }
    }

    // MARK: Sending

    /// Each request runs once. A lost response is an unknown outcome; refresh instead of
    /// retrying a destructive action automatically.
    public func mutate(_ action: FileMutation.Action) async throws -> FileMutationResult {
        if let ended { throw ended }
        let id = UInt64.random(in: 1...UInt64.max)
        return try await withCheckedThrowingContinuation { continuation in
            mutations[id] = continuation
            Task {
                do { try await self.send(.mutateFile(.init(id: id, action: action))) }
                catch { self.finishMutation(id, error: error) }
            }
            Task {
                try? await Task.sleep(for: requestTimeout)
                self.finishMutation(id, error: FileTransferError.stopped("The Mac didn't confirm this change. Refresh the folder to check what happened before trying again."))
            }
        }
    }

    private func finishMutation(_ id: UInt64, error: any Error) {
        mutations.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// Sends the file at `url` to the Mac's Downloads folder as `name`. Using the same `id`
    /// again resumes a transfer that was cut off.
    public func upload(_ url: URL, name: String,
                       id: UInt64 = .random(in: 1...UInt64.max)) -> AsyncThrowingStream<Progress, any Error> {
        let (stream, progress) = AsyncThrowingStream<Progress, any Error>.makeStream()
        if let ended {
            progress.finish(throwing: ended)
            return stream
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil else {
            progress.finish(throwing: FileTransferError.unreadable("Couldn't read “\(name)”."))
            return stream
        }
        uploads[id] = Upload(sender: FileSender(id: id, url: url, size: size), size: size, progress: progress)
        progress.yield(.transferring(done: 0, total: size))
        progress.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            Task { await self.cancel(id) }
        }
        Task { try? await self.send(.sendFile(FileOffer(id: id, name: name, size: size))) }
        return stream
    }

    // MARK: Fetching

    /// Fetches `entry` from the folder at `path`. Fetching the same file again after a
    /// cut-off connection resumes where it stopped.
    public func download(_ entry: FileEntry, in path: FolderPath) -> AsyncThrowingStream<Progress, any Error> {
        let (stream, progress) = AsyncThrowingStream<Progress, any Error>.makeStream()
        if let ended {
            progress.finish(throwing: ended)
            return stream
        }
        let filePath = path.appending(entry.name)
        let id = entry.transferID(at: path)
        do {
            let receiver = try FileReceiver(id: id, size: entry.size, partURL: folder.appending(path: "Partial/\(id).part"))
            downloads[id] = Download(receiver: receiver, name: entry.name, progress: progress)
            progress.yield(.transferring(done: receiver.received, total: entry.size))
            progress.onTermination = { [weak self] termination in
                guard case .cancelled = termination, let self else { return }
                Task { await self.cancel(id) }
            }
            Task { try? await self.send(.getFile(FileRequest(id: id, path: filePath, offset: receiver.received))) }
        } catch {
            progress.finish(throwing: FileTransferError.unreadable("This iPhone couldn't save “\(entry.name)”."))
        }
        return stream
    }

    public func cancel(_ id: UInt64) async {
        let upload = uploads.removeValue(forKey: id)
        let download = downloads.removeValue(forKey: id)
        guard upload != nil || download != nil else { return }
        await upload?.sender.stop(.cancelled)
        upload?.progress.finish(throwing: FileTransferError.cancelled)
        download?.progress.finish(throwing: FileTransferError.cancelled)
        try? await send(.fileFailed(id: id, reason: "Cancelled on the phone."))
    }

    // MARK: From the connection

    /// The file messages; anything else is the caller's.
    public static func handles(_ message: ControlMessage) -> Bool {
        switch message {
        case .fileAccepted, .fileOffer, .fileProgress, .fileSaved, .fileFailed, .fileList, .fileMutationResult: true
        default: false
        }
    }

    public func receive(_ message: ControlMessage) async {
        switch message {
        case .fileMutationResult(let result):
            mutations.removeValue(forKey: result.id)?.resume(returning: result)
        case .fileList(let list):
            listGenerations[list.path] = nil
            for waiter in lists.removeValue(forKey: list.path) ?? [] { waiter.resume(returning: list) }
        case .fileAccepted(let id, let offset):
            guard var upload = uploads[id] else { return }
            upload.progress.yield(.transferring(done: offset, total: upload.size))
            let sender = upload.sender, sendChunk = sendChunk
            upload.task = Task {
                do { try await sender.run(from: offset, send: sendChunk) } catch FileTransferError.cancelled {
                } catch {
                    await self.fail(id, FileTransferError.unreadable(String(describing: error)), tellMac: true)
                }
            }
            uploads[id] = upload
        case .fileProgress(let id, let received):
            if let upload = uploads[id] {
                await upload.sender.acknowledge(received)
                upload.progress.yield(.transferring(done: received, total: upload.size))
            }
        case .fileSaved(let id, let name):
            guard let upload = uploads.removeValue(forKey: id) else { return }
            upload.progress.yield(.transferring(done: upload.size, total: upload.size))
            upload.progress.yield(.saved(name: name))
            upload.progress.finish()
        case .fileOffer(let offer):
            // The Mac's copy changed since it was listed: start over from the listing.
            guard let download = downloads[offer.id], offer.size != download.receiver.size else { return }
            await fail(offer.id, FileTransferError.stopped("“\(download.name)” changed on the Mac. Try again."), tellMac: true)
        case .fileFailed(let id, let reason):
            await fail(id, FileTransferError.stopped(reason), tellMac: false)
        default:
            break
        }
    }

    public func receive(_ chunk: FileChunk) async {
        guard var download = downloads[chunk.id] else { return }
        do {
            switch try download.receiver.write(chunk) {
            case .more:
                downloads[chunk.id] = download
            case .acknowledge(let received):
                downloads[chunk.id] = download
                download.progress.yield(.transferring(done: received, total: download.receiver.size))
                try? await send(.fileProgress(id: chunk.id, received: received))
            case .done:
                downloads[chunk.id] = nil
                try? await send(.fileProgress(id: chunk.id, received: download.receiver.size))
                let url = try download.receiver.finish(into: folder.appending(path: "Received/\(chunk.id)"), name: download.name)
                download.progress.yield(.transferring(done: download.receiver.size, total: download.receiver.size))
                download.progress.yield(.downloaded(url))
                download.progress.finish()
            }
        } catch {
            downloads[chunk.id] = nil
            download.progress.finish(throwing: error)
            try? await send(.fileFailed(id: chunk.id, reason: "The phone couldn't save it."))
        }
    }

    /// The connection is gone: everything in flight stops (fetches keep what they have).
    public func end(_ error: any Error = TransportError.closed) async {
        ended = error
        for (_, waiter) in mutations { waiter.resume(throwing: error) }
        mutations = [:]
        for (_, waiters) in lists { for waiter in waiters { waiter.resume(throwing: error) } }
        lists = [:]
        listGenerations = [:]
        for (_, upload) in uploads {
            await upload.sender.stop(.cancelled)
            upload.progress.finish(throwing: error)
        }
        uploads = [:]
        for (_, download) in downloads { download.progress.finish(throwing: error) }
        downloads = [:]
    }

    private func fail(_ id: UInt64, _ error: FileTransferError, tellMac: Bool) async {
        if let upload = uploads.removeValue(forKey: id) {
            await upload.sender.stop(error)
            upload.progress.finish(throwing: error)
        }
        if let download = downloads.removeValue(forKey: id) {
            download.progress.finish(throwing: error)
        }
        if tellMac { try? await send(.fileFailed(id: id, reason: error.description)) }
    }
}
