#if os(macOS)
import Foundation
import PDProtocol

/// The folders the person at the Mac shares with their phones, chosen in the menu bar panel.
/// Nothing is shared until they switch a folder on. A phone sees names below a shared folder
/// only, and nothing that leads out of it (`..`, or a link to somewhere else).
public struct SharedFolders: Sendable, Equatable {
    public var enabled: Set<SharedFolder>
    /// Where each shared folder is (the user's own, outside tests).
    public var locations: [SharedFolder: URL]

    public init(enabled: Set<SharedFolder>, locations: [SharedFolder: URL] = SharedFolders.userLocations) {
        self.enabled = enabled
        self.locations = locations
    }

    public static let defaultsKey = "sharedFolders"

    /// As chosen in the menu bar panel.
    public static var current: SharedFolders {
        let names = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return SharedFolders(enabled: Set(names.compactMap(SharedFolder.init(rawValue:))))
    }

    public static func setShared(_ folder: SharedFolder, _ shared: Bool) {
        var enabled = current.enabled
        if shared { enabled.insert(folder) } else { enabled.remove(folder) }
        UserDefaults.standard.set(enabled.map(\.rawValue).sorted(), forKey: defaultsKey)
    }

    public static var userLocations: [SharedFolder: URL] {
        let files = FileManager.default
        var locations: [SharedFolder: URL] = [:]
        for (folder, directory) in [(SharedFolder.desktop, FileManager.SearchPathDirectory.desktopDirectory),
                                    (.documents, .documentDirectory), (.downloads, .downloadsDirectory)] {
            locations[folder] = files.urls(for: directory, in: .userDomainMask).first
        }
        return locations
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notShared, notFound, notAllowed, isFolder

        public var description: String {
            switch self {
            case .notShared: "That folder isn't shared. Share it from the PocketDesk menu on the Mac."
            case .notFound: "It isn't on the Mac any more."
            case .notAllowed: "The Mac didn't let PocketDesk read it. Allow it in System Settings › Privacy & Security › Files & Folders on the Mac."
            case .isFolder: "That's a folder."
            }
        }
    }

    /// Where `path` is on disk, if it's inside a shared folder.
    public func url(for path: FolderPath) throws(Problem) -> URL {
        guard path.isValid, let root = path.root, enabled.contains(root), let base = locations[root] else {
            throw .notShared
        }
        let url = path.components.reduce(base) { $0.appending(path: $1) }
        // Links are followed only while they stay inside the shared folder.
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved == resolvedBase || resolved.hasPrefix(resolvedBase + "/") else { throw .notShared }
        guard FileManager.default.fileExists(atPath: url.path) else { throw .notFound }
        return url
    }

    public func list(_ path: FolderPath) -> FileList {
        guard path.root != nil else {
            let shared = SharedFolder.allCases.filter(enabled.contains)
            return FileList(path: path, entries: shared.map { FileEntry(name: $0.name, isFolder: true) },
                            problem: shared.isEmpty ? "No folders are shared. Share some from the PocketDesk menu on the Mac." : nil)
        }
        let folder: URL
        do { folder = try url(for: path) } catch {
            return FileList(path: path, entries: [], problem: error.description)
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])
        } catch {
            return FileList(path: path, entries: [], problem: Problem.notAllowed.description)
        }
        let entries = contents.compactMap { url -> FileEntry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  (try? self.url(for: path.appending(url.lastPathComponent))) != nil else { return nil }
            // Packages (an app, some Keynote files) are folders on disk, so they show as folders.
            return FileEntry(name: url.lastPathComponent, isFolder: values.isDirectory == true,
                             size: UInt64(values.fileSize ?? 0),
                             modified: Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        .sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return FileList(path: path, entries: Array(entries.prefix(FileList.maxEntries)))
    }
}
#endif
