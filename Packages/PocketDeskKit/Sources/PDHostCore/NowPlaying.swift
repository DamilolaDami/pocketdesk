#if os(macOS)
import Foundation
import PDProtocol

/// What's playing, from the private MediaRemote framework that Control Center uses. Since
/// macOS 15.4 it answers only some processes, so `nil` can mean "macOS won't say" as well
/// as "nothing is playing"; live tiles then show volume alone.
enum NowPlayingReader {
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @Sendable (CFDictionary?) -> Void) -> Void

    private static let getInfo: GetInfo? = {
        let url = URL(filePath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url),
              let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString)
        else { return nil }
        return unsafeBitCast(pointer, to: GetInfo.self)
    }()

    private static let queue = DispatchQueue(label: "com.pocketdesk.now-playing")

    static func current() async -> NowPlaying? {
        guard let getInfo else { return nil }
        return await withCheckedContinuation { done in
            // The callback can be skipped entirely when the process isn't allowed an answer.
            let once = Once()
            getInfo(queue) { dictionary in
                let playing = (dictionary as? [String: Any]).flatMap(Self.parse)
                once.run { done.resume(returning: playing) }
            }
            queue.asyncAfter(deadline: .now() + 0.5) { once.run { done.resume(returning: nil) } }
        }
    }

    static func parse(_ info: [String: Any]) -> NowPlaying? {
        guard let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty else { return nil }
        let artist = (info["kMRMediaRemoteNowPlayingInfoArtist"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        return NowPlaying(title: title, artist: artist, isPlaying: rate > 0)
    }
}

/// Runs its closure the first time only; both callers above race on one serial queue.
/// `@unchecked Sendable`: `done` is only touched on `NowPlayingReader.queue`.
private final class Once: @unchecked Sendable {
    private var done = false
    func run(_ body: () -> Void) {
        guard !done else { return }
        done = true
        body()
    }
}
#endif
