#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import PDProtocol

/// All phone-initiated mutations are serialized across sessions. Re-read the Mac's grants
/// here, not when the connection was opened or the folder was listed.
actor FileMutations {
    static let shared = FileMutations()
    private let trash: @Sendable (URL) throws -> Void

    init(trash: @escaping @Sendable (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }) { self.trash = trash }

    func apply(_ request: FileMutation, folders: @Sendable () -> SharedFolders) -> FileMutationResult {
        do {
            let shared = folders()
            switch request.action {
            case .createFolder(let parent, let name):
                try FileMutationAccess.checkName(name)
                let fd = try FileMutationAccess.directory(parent, in: shared)
                defer { close(fd) }
                guard mkdirat(fd, name, 0o755) == 0 else { throw FileMutationAccess.systemError() }
            case .rename(let item, let name):
                var parent = item.path
                guard !parent.components.isEmpty else { throw FileMutationAccess.Failure(.invalid) }
                parent.components.removeLast()
                try relocate(item, to: parent, name: name, in: shared)
            case .move(let item, let destination, let name):
                try relocate(item, to: destination, name: name, in: shared)
            case .trash(let item):
                let (fd, name, _) = try FileMutationAccess.item(item, in: shared)
                defer { close(fd) }
                // A reference URL follows the checked inode if its parent is renamed. Never
                // pass the phone's original path to Foundation's path-based Trash operation.
                let leaf = openat(fd, name, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
                guard leaf >= 0 else { throw FileMutationAccess.systemError() }
                defer { close(leaf) }
                var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                guard fcntl(leaf, F_GETPATH, &path) == 0 else { throw FileMutationAccess.systemError() }
                let url = URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                guard let reference = (url as NSURL).fileReferenceURL(),
                      FileMutationAccess.revision(at: reference) == item.revision,
                      let base = item.path.root.flatMap({ shared.locations[$0] })?.resolvingSymlinksInPath().standardizedFileURL.path,
                      let current = (reference as NSURL).filePathURL?.standardizedFileURL.path,
                      current.hasPrefix(base + "/") else { throw FileMutationAccess.Failure(.changed) }
                try trash(reference)
            }
            return FileMutationResult(id: request.id)
        } catch let failure as FileMutationAccess.Failure {
            return FileMutationResult(id: request.id, problem: failure.problem,
                                      message: "“\(request.itemName)”: \(failure.message)")
        } catch {
            return FileMutationResult(id: request.id, problem: .failed,
                                      message: "“\(request.itemName)”: The Mac couldn't complete this change. Check its file permissions and try again.")
        }
    }

    private func relocate(_ item: FileMutation.Item, to destination: FolderPath, name: String, in shared: SharedFolders) throws {
        try FileMutationAccess.checkName(name)
        guard item.path.root == destination.root else { throw FileMutationAccess.Failure(.differentRoot) }
        let (source, oldName, info) = try FileMutationAccess.item(item, in: shared)
        defer { close(source) }
        if info.st_mode & S_IFMT == S_IFDIR, destination.components.starts(with: item.path.components) {
            throw FileMutationAccess.Failure(.invalid)
        }
        let target = try FileMutationAccess.directory(destination, in: shared)
        defer { close(target) }
        var targetInfo = stat()
        guard fstat(target, &targetInfo) == 0 else { throw FileMutationAccess.systemError() }
        guard info.st_dev == targetInfo.st_dev else { throw FileMutationAccess.Failure(.differentRoot) }
        if destination.appending(name) == item.path { return }
        // Atomic exclusive rename: checking existence followed by moveItem would race with
        // another creator and could overwrite its file. This never replaces a destination.
        guard renameatx_np(source, oldName, target, name, UInt32(RENAME_EXCL)) == 0 else {
            throw FileMutationAccess.systemError()
        }
    }
}

enum FileMutationAccess {
    struct Failure: Error {
        let problem: FileMutationResult.Problem
        init(_ problem: FileMutationResult.Problem) { self.problem = problem }
        var message: String {
            switch problem {
            case .readOnly: "This folder is read-only. Allow file changes in PocketDesk's Mac menu."
            case .changed: "This item changed on the Mac. Refresh the folder before trying again."
            case .collision: "An item with that name already exists. Choose another name or cancel."
            case .invalid: "Choose a valid name and a destination outside the item being moved. Links cannot be changed from the phone."
            case .notFound: "This item or folder is no longer available."
            case .notAllowed: "macOS didn't allow this change. Check file permissions on the Mac."
            case .differentRoot: "Choose a folder in the same shared folder and on the same volume."
            case .failed: "The Mac couldn't complete this change."
            }
        }
    }

    static func checkName(_ name: String) throws {
        guard FileMutation.validName(name) else { throw Failure(.invalid) }
    }

    static func systemError() -> Failure {
        switch errno {
        case EEXIST, ENOTEMPTY: Failure(.collision)
        case ENOENT: Failure(.notFound)
        case ELOOP, ENOTDIR, EINVAL: Failure(.invalid)
        case EXDEV: Failure(.differentRoot)
        case EACCES, EPERM, EROFS: Failure(.notAllowed)
        default: Failure(.failed)
        }
    }

    /// Walk with directory descriptors: a renamed ancestor or symlink substitution cannot
    /// redirect mkdir/rename to an unshared directory. Mutation paths never follow links.
    static func directory(_ path: FolderPath, in shared: SharedFolders) throws -> Int32 {
        guard path.isValid, path.components.count <= 64, let root = path.root,
              shared.enabled.contains(root), shared.writable.contains(root), let base = shared.locations[root] else {
            throw Failure(.readOnly)
        }
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open(base.resolvingSymlinksInPath().path, flags)
        guard fd >= 0 else { throw systemError() }
        for name in path.components {
            let child = openat(fd, name, flags)
            close(fd)
            guard child >= 0 else { throw systemError() }
            fd = child
        }
        return fd
    }

    static func item(_ item: FileMutation.Item, in shared: SharedFolders) throws -> (Int32, String, stat) {
        var parent = item.path
        guard item.path.isValid, let name = parent.components.popLast(), item.revision.count == 64 else { throw Failure(.invalid) }
        let fd = try directory(parent, in: shared)
        do {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw systemError() }
            guard info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { throw Failure(.invalid) }
            guard revision(info) == item.revision else { throw Failure(.changed) }
            return (fd, name, info)
        } catch { close(fd); throw error }
    }

    static func revision(at url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return revision(info)
    }

    private static func revision(_ info: stat) -> String {
        let identity = "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension FileMutation {
    var itemName: String {
        switch action {
        case .createFolder(_, let name): name
        case .rename(let item, _), .move(let item, _, _), .trash(let item): item.path.title
        }
    }
}
#endif
