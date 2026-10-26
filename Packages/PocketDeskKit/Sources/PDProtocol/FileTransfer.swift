/// Files between the phone and the Mac: photos and files sent to the Mac's Downloads folder,
/// and files fetched from the folders the Mac shares.
///
/// The data rides a channel of its own (see `PeerSession.send(chunk:)`), never the control
/// stream, so a big file can't hold up keys and clicks. The receiver acknowledges with
/// `fileProgress` and the sender stays at most `FileChunk.window` bytes ahead, which bounds
/// memory on both sides and shows progress. A cut-off transfer resumes: the receiver keeps
/// what arrived under the transfer's ID and answers with where to carry on from.
public struct FileOffer: Codable, Sendable, Equatable {
    public var id: UInt64
    public var name: String
    public var size: UInt64

    public init(id: UInt64, name: String, size: UInt64) {
        self.id = id
        self.name = name
        self.size = size
    }

    /// A name that's safe to save under in any folder: no path separators, not hidden, no
    /// control characters, at most 200 UTF-8 bytes (keeping the extension).
    public static func safeName(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar in
            scalar == "/" || scalar == ":" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F
                ? "-" : Character(scalar)
        })
        while cleaned.hasPrefix(".") || cleaned.hasPrefix(" ") { cleaned.removeFirst() }
        while cleaned.hasSuffix(" ") { cleaned.removeLast() }
        if cleaned.isEmpty { return "File" }
        guard cleaned.utf8.count > maxNameBytes else { return cleaned }
        let dot = cleaned.lastIndex(of: ".")
        let ext = dot.map { String(cleaned[$0...]) }.flatMap { $0.utf8.count <= 16 ? $0 : nil } ?? ""
        var stem = String(cleaned[..<(ext.isEmpty ? cleaned.endIndex : dot!)])
        while stem.utf8.count + ext.utf8.count > maxNameBytes { stem.removeLast() }
        return stem + ext
    }

    static let maxNameBytes = 200
}

/// Phone → host: send this file from a shared folder, starting at `offset`.
public struct FileRequest: Codable, Sendable, Equatable {
    public var id: UInt64
    public var path: FolderPath
    public var offset: UInt64

    public init(id: UInt64, path: FolderPath, offset: UInt64 = 0) {
        self.id = id
        self.path = path
        self.offset = offset
    }
}

/// The folders a Mac can share with the phone, each switched on at the Mac.
public enum SharedFolder: String, Codable, Sendable, CaseIterable {
    case desktop, documents, downloads

    public var name: String {
        switch self {
        case .desktop: "Desktop"
        case .documents: "Documents"
        case .downloads: "Downloads"
        }
    }
}

/// Somewhere in a shared folder: a folder or a file, by its names below the shared folder.
/// `root == nil` is the list of shared folders itself.
public struct FolderPath: Codable, Sendable, Hashable {
    public var root: SharedFolder?
    public var components: [String]

    public init(root: SharedFolder? = nil, components: [String] = []) {
        self.root = root
        self.components = components
    }

    public static let shared = FolderPath()

    public func appending(_ name: String) -> FolderPath {
        FolderPath(root: root, components: components + [name])
    }

    /// Only names, so it can't step out of its shared folder: no "..", no separators, not empty.
    public var isValid: Bool {
        guard root != nil || components.isEmpty else { return false }
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }
    }

    /// What the phone shows as its title.
    public var title: String { components.last ?? root?.name ?? "Mac" }
}

public struct FileEntry: Codable, Sendable, Equatable, Identifiable {
    /// An opaque host revision. Mutations must present the revision from a fresh listing.
    public var revision: String?
    public var name: String
    public var isFolder: Bool
    public var size: UInt64
    /// Seconds since 1970.
    public var modified: Int64
    public var id: String { name }

    public init(name: String, isFolder: Bool, size: UInt64 = 0, modified: Int64 = 0, revision: String? = nil) {
        self.revision = revision
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
    }

    /// The same file at the same size and date gets the same transfer ID, so fetching it again
    /// after a cut-off connection resumes instead of starting over. (FNV-1a over path, size, date.)
    public func transferID(at path: FolderPath) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            hash ^= 0xFF
            hash = hash &* 0x0000_0100_0000_01B3
        }
        mix((path.root?.rawValue ?? "").utf8)
        for component in path.components { mix(component.utf8) }
        mix(name.utf8)
        withUnsafeBytes(of: size.littleEndian) { mix($0) }
        withUnsafeBytes(of: modified.littleEndian) { mix($0) }
        return hash
    }
}

public struct FileList: Codable, Sendable, Equatable {
    public var canWrite: Bool
    public var path: FolderPath
    public var entries: [FileEntry]
    /// Why the folder couldn't be listed (not shared, or the Mac wasn't allowed to read it).
    public var problem: String?

    public init(path: FolderPath, entries: [FileEntry], problem: String? = nil, canWrite: Bool = false) {
        self.canWrite = canWrite
        self.path = path
        self.entries = entries
        self.problem = problem
    }

    /// A folder lists at most this many entries (folders first, then newest).
    public static let maxEntries = 2_000
}

/// One piece of a file. Binary on the wire, little-endian: transfer ID (8), offset (8),
/// length (4), flags (1, bit 0 = last), then the bytes.
public struct FileChunk: Sendable, Equatable {
    public var id: UInt64
    public var offset: UInt64
    public var bytes: [UInt8]
    public var isLast: Bool

    public static let size = 256 * 1024
    /// How far the sender may run ahead of what the receiver has acknowledged.
    public static let window: UInt64 = 4 * 1024 * 1024
    /// The receiver acknowledges at least this often, in bytes.
    public static let acknowledgeEvery: UInt64 = 1024 * 1024
    public static let headerSize = 21

    public init(id: UInt64, offset: UInt64, bytes: [UInt8], isLast: Bool) {
        self.id = id
        self.offset = offset
        self.bytes = bytes
        self.isLast = isLast
    }

    public func encoded() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.headerSize + bytes.count)
        out.appendLE(id)
        out.appendLE(offset)
        out.appendLE(UInt32(bytes.count))
        out.append(isLast ? 1 : 0)
        out.append(contentsOf: bytes)
        return out
    }

    public init(decoding data: some Collection<UInt8>) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerSize else { throw WireError.truncated }
        var reader = ByteReader(bytes)
        id = try reader.u64()
        offset = try reader.u64()
        let length = Int(try reader.u32())
        isLast = try reader.u8() & 1 == 1
        guard length <= Self.size, bytes.count == Self.headerSize + length else { throw WireError.invalidValue }
        self.bytes = Array(bytes[Self.headerSize...])
    }
}

/// The sender's side of the window: how much is out, how much the receiver has.
public struct TransferWindow: Sendable, Equatable {
    public private(set) var sent: UInt64
    public private(set) var acknowledged: UInt64

    public init(startingAt offset: UInt64 = 0) {
        sent = offset
        acknowledged = offset
    }

    /// Room for `count` more bytes. Always room when nothing is out, however big the chunk.
    public func canSend(_ count: Int) -> Bool {
        sent == acknowledged || sent - acknowledged + UInt64(count) <= FileChunk.window
    }

    public mutating func didSend(_ count: Int) { sent += UInt64(count) }

    public mutating func acknowledge(_ received: UInt64) {
        acknowledged = min(max(acknowledged, received), sent)
    }
}
