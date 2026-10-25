import Foundation
import PDProtocol
import UniformTypeIdentifiers

/// Local presentation of one listing. Never searches other folders or changes the wire.
public struct FileBrowserOptions: Sendable, Equatable {
    public enum Kind: String, CaseIterable, Sendable {
        case all, folders, documents, images, videos, audio, archives, other

        public var title: String {
            switch self {
            case .all: "All Items"
            case .folders: "Folders"
            case .documents: "Documents"
            case .images: "Images"
            case .videos: "Videos"
            case .audio: "Audio"
            case .archives: "Archives"
            case .other: "Other Files"
            }
        }

        public var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .folders: "folder.fill"
            case .documents: "doc.richtext"
            case .images: "photo"
            case .videos: "film"
            case .audio: "waveform"
            case .archives: "doc.zipper"
            case .other: "doc"
            }
        }
    }

    public enum Sort: String, CaseIterable, Sendable {
        case newest, name, largest

        public var title: String {
            switch self {
            case .newest: "Date Modified"
            case .name: "Name"
            case .largest: "Size"
            }
        }
    }

    public var query: String
    public var kind: Kind
    public var sort: Sort

    public init(query: String = "", kind: Kind = .all, sort: Sort = .newest) {
        self.query = query
        self.kind = kind
        self.sort = sort
    }

    public var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isFiltering: Bool { !searchText.isEmpty || kind != .all }

    public func applying(to entries: [FileEntry]) -> [FileEntry] {
        let words = searchText
        return entries.filter { entry in
            (words.isEmpty || entry.name.localizedStandardContains(words)) && (kind == .all || Self.kind(of: entry) == kind)
        }.sorted { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
            switch sort {
            case .newest:
                if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            case .largest:
                // Folder sizes aren't supplied by the host; keep folders in name order.
                if !lhs.isFolder, lhs.size != rhs.size { return lhs.size > rhs.size }
            case .name: break
            }
            let comparison = lhs.name.localizedStandardCompare(rhs.name)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return lhs.name < rhs.name
        }
    }

    public static func kind(of entry: FileEntry) -> Kind {
        guard !entry.isFolder else { return .folders }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        // Some formats only get a registered type after an app is installed on that device.
        // Common Mac files should still land in the same filter on an iPhone.
        if type?.conforms(to: .image) == true
            || ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "avif", "bmp", "svg", "dng"].contains(ext) { return .images }
        if type?.conforms(to: .movie) == true
            || ["mov", "mp4", "m4v", "avi", "mkv", "webm", "mpeg", "mpg"].contains(ext) { return .videos }
        if type?.conforms(to: .audio) == true
            || ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus"].contains(ext) { return .audio }
        if type?.conforms(to: .archive) == true
            || ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"].contains(ext) { return .archives }
        if type?.conforms(to: .pdf) == true || type?.conforms(to: .text) == true
            || type?.conforms(to: .presentation) == true || type?.conforms(to: .spreadsheet) == true
            || ["doc", "docx", "pages", "numbers", "key", "odt", "ods", "odp", "epub", "rtfd"].contains(ext) {
            return .documents
        }
        return .other
    }
}
