import Foundation
import PDProtocol

public enum FileTransferError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The other side stopped it; its reason.
    case stopped(String)
    case cancelled
    /// The file changed size while it was being sent, or chunks arrived out of order.
    case corrupted
    case unreadable(String)

    public var description: String {
        switch self {
        case .stopped(let reason): reason
        case .cancelled: "Cancelled."
        case .corrupted: "The file changed while it was being sent. Try again."
        case .unreadable(let reason): reason
        }
    }
}

/// Sends one file in `FileChunk`s, never more than `FileChunk.window` ahead of what the
/// receiver has acknowledged.
public actor FileSender {
    public nonisolated let id: UInt64
    private let url: URL
    private let size: UInt64
    private var window: TransferWindow
    private var waiting: CheckedContinuation<Void, any Error>?
    private var stopped: FileTransferError?

    public init(id: UInt64, url: URL, size: UInt64) {
        self.id = id
        self.url = url
        self.size = size
        window = TransferWindow()
    }

    /// Sends from `offset` to the end, then returns. Progress is what the receiver acknowledges.
    public func run(from offset: UInt64, send: @Sendable (FileChunk) async throws -> Void) async throws {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw FileTransferError.unreadable("Couldn't read “\(url.lastPathComponent)”.")
        }
        defer { try? handle.close() }
        let start = min(offset, size)
        try handle.seek(toOffset: start)
        window = TransferWindow(startingAt: start)
        var position = start
        repeat {
            let bytes = try handle.read(upToCount: Int(min(UInt64(FileChunk.size), size - position))) ?? Data()
            let isLast = position + UInt64(bytes.count) >= size
            guard bytes.count > 0 || isLast else { throw FileTransferError.corrupted }
            while !window.canSend(bytes.count) {
                try await waitForAcknowledgement()
            }
            if let stopped { throw stopped }
            try await send(FileChunk(id: id, offset: position, bytes: [UInt8](bytes), isLast: isLast))
            window.didSend(bytes.count)
            position += UInt64(bytes.count)
        } while position < size
    }

    /// Bytes the receiver has (from its `fileProgress`).
    public func acknowledge(_ received: UInt64) {
        window.acknowledge(received)
        waiting?.resume()
        waiting = nil
    }

    public func stop(_ reason: FileTransferError) {
        stopped = reason
        waiting?.resume(throwing: reason)
        waiting = nil
    }

    private func waitForAcknowledgement() async throws {
        if let stopped { throw stopped }
        try await withCheckedThrowingContinuation { waiting = $0 }
    }
}

/// Receives one file into `partURL`, which survives a cut-off connection so the next attempt
/// with the same ID resumes from what's there.
public struct FileReceiver: Sendable {
    public let id: UInt64
    public let size: UInt64
    public let partURL: URL
    public private(set) var received: UInt64
    private var acknowledged: UInt64

    /// Opens (or creates) the part file. `received` is where the sender should start.
    public init(id: UInt64, size: UInt64, partURL: URL) throws {
        self.id = id
        self.size = size
        self.partURL = partURL
        let files = FileManager.default
        try files.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? files.attributesOfItem(atPath: partURL.path)[.size] as? UInt64) ?? nil
        if let existing, existing <= size {
            received = existing
        } else {
            try? files.removeItem(at: partURL)
            files.createFile(atPath: partURL.path, contents: nil)
            received = 0
        }
        acknowledged = received
    }

    public enum Outcome: Sendable, Equatable {
        case more
        /// Tell the sender it has this much.
        case acknowledge(UInt64)
        /// All of it is in `partURL`.
        case done
    }

    public mutating func write(_ chunk: FileChunk) throws -> Outcome {
        guard chunk.id == id, chunk.offset == received, received + UInt64(chunk.bytes.count) <= size else {
            throw FileTransferError.corrupted
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: received)
        try handle.write(contentsOf: chunk.bytes)
        received += UInt64(chunk.bytes.count)
        if chunk.isLast {
            guard received == size else { throw FileTransferError.corrupted }
            return .done
        }
        guard received - acknowledged >= FileChunk.acknowledgeEvery else { return .more }
        acknowledged = received
        return .acknowledge(received)
    }

    /// Moves the finished file into `folder` under `name`, or "name 2", "name 3"… if taken.
    public func finish(into folder: URL, name: String) throws -> URL {
        let destination = Self.unusedURL(in: folder, for: FileOffer.safeName(name))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: partURL, to: destination)
        return destination
    }

    static func unusedURL(in folder: URL, for name: String) -> URL {
        let candidate = folder.appending(path: name)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for number in 2... {
            let numbered = folder.appending(path: ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !FileManager.default.fileExists(atPath: numbered.path) { return numbered }
        }
        return candidate
    }
}
