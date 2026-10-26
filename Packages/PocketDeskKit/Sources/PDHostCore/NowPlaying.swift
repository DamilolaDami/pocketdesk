#if os(macOS)
import Foundation
import PDProtocol

/// What's playing, from the private MediaRemote framework that Control Center uses. Since
/// macOS 15.4 it answers only Apple's processes, so the host app asks through its bundled
/// helper loaded into `/usr/bin/perl` (see `Apps/NowPlaying/NowPlaying.m`). `nil` can mean
/// "macOS won't say" as well as "nothing is playing"; live tiles then show volume alone.
enum NowPlayingReader {
    /// The helper inside the host app; absent in tests and command line builds.
    static let helper = Bundle.main.url(forResource: "PocketDeskNowPlaying", withExtension: "dylib")

    static func current() async -> NowPlaying? {
        if let helper { return await viaPerl(helper) }
        return await inProcess()
    }

    private static func viaPerl(_ helper: URL) async -> NowPlaying? {
        let script = """
            use DynaLoader;
            my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or exit 1;
            my $sym = DynaLoader::dl_find_symbol($lib, "pocketdesk_now_playing") or exit 1;
            DynaLoader::dl_install_xsub("main::now_playing", $sym);
            main::now_playing();
            """
        guard let result = try? await Subprocess.run("/usr/bin/perl", ["-e", script, helper.path(percentEncoded: false)],
                                                     timeout: .seconds(3)),
              result.status == 0 else { return nil }
        return parseHelper(result.output)
    }

    /// One JSON line: `{"title": …, "artist": …, "isPlaying": true, "artwork": base64 JPEG}`, or `{}`.
    static func parseHelper(_ output: String) -> NowPlaying? {
        guard let line = output.split(whereSeparator: \.isNewline).last,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let title = json["title"] as? String, !title.isEmpty else { return nil }
        let timing = timeline(elapsed: json["elapsed"] as? Double, duration: json["duration"] as? Double,
                              timestamp: (json["timestamp"] as? Double).map(Date.init(timeIntervalSince1970:)),
                              rate: json["rate"] as? Double ?? ((json["isPlaying"] as? Bool) == true ? 1 : 0))
        return NowPlaying(title: title, artist: json["artist"] as? String,
                          isPlaying: (json["isPlaying"] as? Bool) ?? ((json["isPlaying"] as? Int) ?? 0 > 0),
                          artwork: (json["artwork"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                          app: (json["app"] as? String).flatMap(app(at:)),
                          startedAt: timing.start, duration: timing.duration, pausedElapsed: timing.paused)
    }

    private static func timeline(elapsed: Double?, duration: Double?, timestamp: Date?, rate: Double)
        -> (start: Date?, duration: Double?, paused: Double?) {
        guard let elapsed, elapsed.isFinite, elapsed >= 0, let duration, duration.isFinite, duration >= 1,
              let timestamp, timestamp.timeIntervalSince1970.isFinite, rate == 0 || rate == 1 else { return (nil, nil, nil) }
        let position = min(elapsed, duration)
        return (rate == 1 ? Date(timeIntervalSince1970: (timestamp.timeIntervalSince1970 - elapsed).rounded()) : nil,
                duration.rounded(), rate == 0 ? position.rounded() : nil)
    }

    /// The app at a bundle path, by its ID and the name Finder shows.
    static func app(at path: String) -> PlayerApp? {
        guard let bundleID = Bundle(path: path)?.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: path)
        return PlayerApp(bundleID: bundleID, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name)
    }

    /// The player's cover shrunk to `NowPlaying.artworkSize` as base64 JPEG (covers can be
    /// megabytes, and this goes out every time the status changes).
    static func artwork(from data: Data) -> String? {
        JPEGThumbnail.base64(from: data, maxPixels: NowPlaying.artworkSize)
    }
    private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @Sendable (CFDictionary?) -> Void) -> Void

    private static let getInfo: GetInfo? = {
        let url = URL(filePath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url),
              let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString)
        else { return nil }
        return unsafeBitCast(pointer, to: GetInfo.self)
    }()

    private static let queue = DispatchQueue(label: "com.pocketdesk.now-playing")

    private static func inProcess() async -> NowPlaying? {
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
        let artwork = (info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).flatMap(Self.artwork)
        let timing = timeline(elapsed: info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double,
                              duration: info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double,
                              timestamp: info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date, rate: rate)
        return NowPlaying(title: title, artist: artist, isPlaying: rate > 0, artwork: artwork,
                          startedAt: timing.start, duration: timing.duration, pausedElapsed: timing.paused)
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
