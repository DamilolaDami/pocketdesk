#if os(macOS)
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import PDHostCore
import PDProtocol

/// The signed NSApplication wrapper supplies fresh screen/backing-scale notifications.
enum SizingProof {
    struct Result: Codable {
        var mode: VirtualDisplayMode
        var displayID: UInt32
        var startedAtUnixSeconds: Double
        var transitionMilliseconds: Double
        var backingPixels: [Int]
        var capturedPixels: [Int]
        var frameCount: Int
        var observedFramesPerSecond: Double
        var meanCaptureDeliveryMillis: Double?
        var maxCaptureDeliveryMillis: Double?
        var observationSeconds: Double
        var processCPUPercentOfOneCore: Double
        var processPeakRSSBytes: Int64
    }
    struct Evidence: Codable {
        var os: String
        var processID = ProcessInfo.processInfo.processIdentifier
        var baseline: [DisplaySnapshot]
        var results: [Result] = []
        var final: [DisplaySnapshot] = []
        var portraitCreationVerified = false
        var error: String?
    }
    struct CaptureStats: Sendable {
        var pixels: [Int] = []
        var frames = 0
        var first: Double?
        var last: Double?
        var deliveryMillis: [Double] = []
    }
    static func run(report: URL) async throws {
        let backend = RuntimeVirtualDisplayBackend(), source = ScreenCaptureSource(includingOwnWindows: true)
        var evidence = Evidence(os: ProcessInfo.processInfo.operatingSystemVersionString, baseline: try DisplaySnapshot.current())
        var resource: VirtualDisplayResource?
        let surface = await Surface()
        await surface.animate()
        do {
            let owned = try await backend.create(logicalID: "pocketdesk-sizing-native-qualification", mode: .standard)
            resource = owned
            for mode in VirtualDisplayMode.supported {
                let began = ContinuousClock.now, unix = Date().timeIntervalSince1970
                try await backend.configure(owned, mode: mode)
                let resolved = try await source.resolve(.display(owned.displayID))
                guard resolved.pixelWidth == mode.pixelWidth, resolved.pixelHeight == mode.pixelHeight else {
                    throw ProbeError("Capture metadata did not match the backing pixels for \(mode)")
                }
                await surface.move(to: resolved.screenFrame)
                let transition = Double((ContinuousClock.now - began) / .microseconds(1)) / 1000
                let cpuBefore = usage(), samplingBegan = ContinuousClock.now
                let frames = try await source.start(resolved, width: resolved.pixelWidth, height: resolved.pixelHeight, fps: mode.refreshRate)
                let measured = await collect(frames)
                await source.stop()
                let seconds = Double((ContinuousClock.now - samplingBegan) / .microseconds(1)) / 1_000_000
                let cpuAfter = usage()
                guard measured.pixels == [mode.pixelWidth, mode.pixelHeight] else { throw ProbeError("No correctly sized native capture") }
                let rate = measured.frames > 1 ? Double(measured.frames - 1) / max(0.001, (measured.last ?? 0) - (measured.first ?? 0)) : 0
                evidence.results.append(.init(mode: mode, displayID: owned.displayID, startedAtUnixSeconds: unix,
                    transitionMilliseconds: transition, backingPixels: [resolved.pixelWidth, resolved.pixelHeight], capturedPixels: measured.pixels,
                    frameCount: measured.frames, observedFramesPerSecond: rate,
                    meanCaptureDeliveryMillis: measured.deliveryMillis.isEmpty ? nil : measured.deliveryMillis.reduce(0, +) / Double(measured.deliveryMillis.count),
                    maxCaptureDeliveryMillis: measured.deliveryMillis.max(), observationSeconds: seconds,
                    processCPUPercentOfOneCore: max(0, (cpuAfter.seconds - cpuBefore.seconds) / max(0.001, seconds) * 100),
                    processPeakRSSBytes: cpuAfter.peakRSS))
                print("MODE \(mode.width)×\(mode.height) @\(mode.scale)x \(mode.refreshRate)Hz; \(measured.pixels); same display \(owned.displayID); received \(rate) fps")
                fflush(stdout)
                try save(evidence, to: report)
            }
            await surface.close()
            try await backend.destroy(owned)
            resource = nil
            // Creation can also start in portrait, without first establishing a landscape lease.
            let portrait = VirtualDisplayMode(width: 800, height: 1280, scale: 2, refreshRate: 30)
            let second = try await backend.create(logicalID: "pocketdesk-sizing-native-portrait", mode: portrait)
            resource = second
            let resolved = try await source.resolve(.display(second.displayID))
            guard resolved.pixelWidth == portrait.pixelWidth, resolved.pixelHeight == portrait.pixelHeight else {
                throw ProbeError("Portrait creation metadata didn't match")
            }
            try await backend.destroy(second); resource = nil
            evidence.portraitCreationVerified = true
            evidence.final = try DisplaySnapshot.current()
            guard evidence.final == evidence.baseline else { throw ProbeError("Original layout was not restored") }
        } catch {
            await surface.close(); await source.stop()
            if let resource { try? await backend.destroy(resource) }
            evidence.final = (try? DisplaySnapshot.current()) ?? []
            evidence.error = String(describing: error)
            try save(evidence, to: report)
            throw error
        }
        try save(evidence, to: report)
    }
    private static func collect(_ frames: AsyncStream<CapturedFrame>) async -> CaptureStats {
        await withTaskGroup(of: CaptureStats?.self) { group in
            group.addTask {
                var result = CaptureStats()
                for await frame in frames {
                    result.pixels = [CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer)]
                    let timestamp = frame.presentationTime.seconds
                    let age = (CMClockGetTime(CMClockGetHostTimeClock()).seconds - timestamp) * 1000
                    if age.isFinite && age >= 0 { result.deliveryMillis.append(age) }
                    if result.first == nil { result.first = timestamp }
                    result.last = timestamp; result.frames += 1
                    if let first = result.first, timestamp - first >= 2 { return result }
                }
                return result
            }
            group.addTask { try? await Task.sleep(for: .milliseconds(2400)); return nil }
            while let result = await group.next() {
                if let result { group.cancelAll(); return result }
                group.cancelAll()
            }
            return CaptureStats()
        }
    }
    private static func usage() -> (seconds: Double, peakRSS: Int64) {
        var result = rusage(); getrusage(RUSAGE_SELF, &result)
        return (Double(result.ru_utime.tv_sec + result.ru_stime.tv_sec) + Double(result.ru_utime.tv_usec + result.ru_stime.tv_usec) / 1_000_000,
                Int64(result.ru_maxrss))
    }
    private static func save(_ evidence: Evidence, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: url, options: .atomic)
    }
}
#endif
