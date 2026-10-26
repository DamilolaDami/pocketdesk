/// One explicit file change. Operations are never retried automatically after a disconnect.
public struct FileMutation: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var path: FolderPath
        public var revision: String
        public init(path: FolderPath, revision: String) { self.path = path; self.revision = revision }
    }

    public enum Action: Codable, Sendable, Equatable {
        case createFolder(parent: FolderPath, name: String)
        case rename(Item, name: String)
        case move(Item, to: FolderPath, name: String)
        case trash(Item)
    }

    public var id: UInt64
    public var action: Action
    public init(id: UInt64, action: Action) { self.id = id; self.action = action }

    /// Names are used literally, never silently sanitized into another destination.
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200 && !name.hasPrefix(".")
            && !name.hasPrefix(" ") && !name.hasSuffix(" ")
            && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || "/\\:".unicodeScalars.contains($0) }
    }
}

public struct FileMutationResult: Codable, Sendable, Equatable {
    public enum Problem: String, Codable, Sendable {
        case readOnly, changed, collision, invalid, notFound, notAllowed, differentRoot, failed
    }
    public var id: UInt64
    public var problem: Problem?
    /// A user-facing explanation, including the affected item on failure.
    public var message: String?
    public init(id: UInt64, problem: Problem? = nil, message: String? = nil) {
        self.id = id; self.problem = problem; self.message = message
    }
}
