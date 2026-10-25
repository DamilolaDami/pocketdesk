import PDProtocol
import Testing
@testable import PDClientCore

struct FileBrowserOptionsTests {
    @Test func searchesNamesWithoutCaseOrAccentAndTrimsWhitespace() {
        let entries = [FileEntry(name: "Résumé.PDF", isFolder: false), FileEntry(name: "Photos", isFolder: true)]
        #expect(FileBrowserOptions(query: "  resume\n").applying(to: entries).map(\.name) == ["Résumé.PDF"])
        #expect(FileBrowserOptions(query: "   ").applying(to: entries).count == 2)
    }

    @Test func combinesKindWithSearchAndNeverMistakesFoldersForFiles() {
        let entries = [FileEntry(name: "Holiday.JPG", isFolder: false), FileEntry(name: "Holiday.jpg", isFolder: true),
                       FileEntry(name: "Holiday.MOV", isFolder: false), FileEntry(name: "Other.png", isFolder: false)]
        #expect(FileBrowserOptions(query: "holiday", kind: .images).applying(to: entries).map(\.name) == ["Holiday.JPG"])
        #expect(FileBrowserOptions(kind: .folders).applying(to: entries).map(\.name) == ["Holiday.jpg"])
    }

    @Test(arguments: [("report.PDF", FileBrowserOptions.Kind.documents), ("letter.docx", .documents),
                      ("notes.txt", .documents), ("photo.HEIC", .images), ("clip.mp4", .videos),
                      ("clip.mkv", .videos), ("song.MP3", .audio), ("song.flac", .audio),
                      ("backup.zip", .archives), ("backup.7z", .archives), ("Makefile", .other)])
    func classifiesCommonMacFiles(name: String, expected: FileBrowserOptions.Kind) {
        #expect(FileBrowserOptions.kind(of: FileEntry(name: name, isFolder: false)) == expected)
    }

    @Test func sortsNaturallyWithFoldersFirstAndStableTies() {
        let entries = [FileEntry(name: "file10.txt", isFolder: false, size: 100, modified: 2),
                       FileEntry(name: "file2.txt", isFolder: false, size: 100, modified: 2),
                       FileEntry(name: "older.txt", isFolder: false, size: 200, modified: 1),
                       FileEntry(name: "Folder", isFolder: true)]
        #expect(FileBrowserOptions(sort: .name).applying(to: entries).map(\.name) == ["Folder", "file2.txt", "file10.txt", "older.txt"])
        #expect(FileBrowserOptions().applying(to: entries).map(\.name) == ["Folder", "file2.txt", "file10.txt", "older.txt"])
        #expect(FileBrowserOptions(sort: .largest).applying(to: entries).map(\.name) == ["Folder", "older.txt", "file2.txt", "file10.txt"])
    }

    @Test func resetRestoresTheListingAndEmptyResultsAreLocal() {
        let entries = [FileEntry(name: "report.pdf", isFolder: false)]
        var options = FileBrowserOptions(query: "missing", kind: .images, sort: .largest)
        #expect(options.applying(to: entries).isEmpty)
        #expect(options.isFiltering)
        options = .init()
        #expect(options.applying(to: entries) == entries)
        #expect(!options.isFiltering)
    }
}
