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

    /// One JSON line: `{"title": …, "artist": …, "isPlaying": true}`, or `{}`.
    static func parseHelper(_ output: String) -> NowPlaying? {
        guard let line = output.split(whereSeparator: \.isNewline).last,
              let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let title = json["title"] as? String, !title.isEmpty else { return nil }
        return NowPlaying(title: title, artist: json["artist"] as? String,
                          isPlaying: (json["isPlaying"] as? Bool) ?? ((json["isPlaying"] as? Int) ?? 0 > 0))
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
