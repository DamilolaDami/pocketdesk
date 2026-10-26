import Foundation
import Testing
@testable import PDHostCore
import PDProtocol

struct NowPlayingTimelineTests {
    @Test func helperProducesStableOriginsAndFrozenPauses() throws {
        let first = try #require(NowPlayingReader.parseHelper(#"{"title":"Song","isPlaying":true,"rate":1,"elapsed":30,"duration":240,"timestamp":1700000030}"#))
        let later = try #require(NowPlayingReader.parseHelper(#"{"title":"Song","isPlaying":true,"rate":1,"elapsed":45,"duration":240,"timestamp":1700000045}"#))
        #expect(first.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(first == later)
        #expect(first.duration == 240 && first.pausedElapsed == nil)
        let paused = try #require(NowPlayingReader.parseHelper(#"{"title":"Song","isPlaying":false,"rate":0,"elapsed":45,"duration":240,"timestamp":1700000050}"#))
        #expect(paused.pausedElapsed == 45 && paused.startedAt == nil)
        let stillPaused = try #require(NowPlayingReader.parseHelper(#"{"title":"Song","isPlaying":false,"rate":0,"elapsed":45,"duration":240,"timestamp":1700000060}"#))
        #expect(paused == stillPaused)
        let sought = try #require(NowPlayingReader.parseHelper(#"{"title":"Song","isPlaying":true,"rate":1,"elapsed":120,"duration":240,"timestamp":1700000050}"#))
        #expect(sought.startedAt != first.startedAt)
    }

    @Test func frameworkDatesAndMissingOrInvalidTiming() throws {
        let playing = try #require(NowPlayingReader.parse([
            "kMRMediaRemoteNowPlayingInfoTitle": "Song",
            "kMRMediaRemoteNowPlayingInfoPlaybackRate": 1.0,
            "kMRMediaRemoteNowPlayingInfoElapsedTime": 30.2,
            "kMRMediaRemoteNowPlayingInfoDuration": 240.1,
            "kMRMediaRemoteNowPlayingInfoTimestamp": Date(timeIntervalSince1970: 1_700_000_030.4)
        ]))
        #expect(playing.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(playing.duration == 240)
        for data in [
            #"{"title":"Live","isPlaying":true,"duration":0,"elapsed":5,"timestamp":1700000030}"#,
            #"{"title":"Unknown","isPlaying":true,"duration":240,"elapsed":5}"#,
            #"{"title":"Bad","isPlaying":true,"duration":240,"elapsed":-5,"timestamp":1700000030}"#
        ] {
            #expect(NowPlayingReader.parseHelper(data)?.startedAt == nil)
        }
    }

    @Test func samplingDriftDoesNotChangeStatusButSeeksDo() {
        let first = NowPlaying(title: "Song", isPlaying: true, startedAt: Date(timeIntervalSince1970: 1000), duration: 240)
        var next = first
        next.startedAt = first.startedAt! + 0.8
        #expect(next.coalescingTimeline(with: first) == first)
        next.startedAt = first.startedAt! - 30
        #expect(next.coalescingTimeline(with: first) != first)
    }
}
