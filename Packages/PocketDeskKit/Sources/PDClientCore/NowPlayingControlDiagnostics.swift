import Foundation
import PDProtocol

/// Only the latest media-button attempt, for diagnosing background failures. No media
/// titles, artwork, device tokens or fingerprints. Never sent to the relay or a third party.
actor NowPlayingControlDiagnostics {
    static let shared = NowPlayingControlDiagnostics()
    private let url: URL
    init(url: URL = URL.applicationSupportDirectory.appending(path: "PocketDesk/now-playing-control.json")) {
        self.url = url
    }
    private struct Entry: Encodable {
        var time: Date
        var stage: String
        var control: String
        var error: String?
    }

    func record(_ stage: String, control: MediaKey, error: String? = nil) {
        let entry = Entry(time: .now, stage: stage, control: control.rawValue, error: error)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: .atomic)
        #endif
    }
}
