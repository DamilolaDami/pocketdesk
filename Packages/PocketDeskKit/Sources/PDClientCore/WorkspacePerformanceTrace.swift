#if DEBUG && os(iOS)
import Darwin
import Foundation
import PDProtocol
import UIKit

/// Opt-in, bounded developer trace. No screen pixels, host names, text or identifiers.
/// Enable with POCKETDESK_SIZING_TRACE=1 on a development launch; never uploads data.
@MainActor enum WorkspacePerformanceTrace {
    struct Sample: Codable {
        var seconds: Double
        var mode: VirtualDisplayMode?
        var quality: String
        var encodedWidth: Int
        var encodedHeight: Int
        var fpsCeiling: Int
        var receivedFramesPerSecond: Double
        var receivedVideoKbps: Double
        var controlRoundTripMs: Double
        var processCPUPercentOfOneCore: Double
        var processPeakRSSBytes: Int64
        var batteryFraction: Float?
        var lowPowerMode: Bool
        var thermalState: Int
    }
    struct Trace: Codable {
        var startedAtUnixSeconds = Date().timeIntervalSince1970
        var model: String
        var os: String
        var samples: [Sample] = []
    }
    static func start(_ controller: SessionController) -> Task<Void, Never>? {
        guard ProcessInfo.processInfo.environment["POCKETDESK_SIZING_TRACE"] == "1" else { return nil }
        return Task { [weak controller] in
            let device = UIDevice.current
            let wasMonitoring = device.isBatteryMonitoringEnabled
            device.isBatteryMonitoringEnabled = true
            defer { device.isBatteryMonitoringEnabled = wasMonitoring }
            var machine = utsname(); uname(&machine)
            let capacity = MemoryLayout.size(ofValue: machine.machine)
            let model = withUnsafePointer(to: &machine.machine) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            var trace = Trace(model: model, os: device.systemVersion)
            _ = controller?.sampleTraceStatistics()
            let began = ProcessInfo.processInfo.systemUptime
            var previousTime = began
            var previousCPU = cpuUsage().seconds
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appending(path: "PocketDesk-Workspace-Performance.json")
            for _ in 0..<120 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let controller, case .streaming(_, let config, _) = controller.store.state else { return }
                let now = ProcessInfo.processInfo.systemUptime, usage = cpuUsage()
                let battery = device.batteryLevel
                let stats = controller.sampleTraceStatistics()
                trace.samples.append(.init(seconds: now - began, mode: controller.store.virtualDisplay.report?.workspace?.acceptedMode,
                    quality: controller.store.quality.rawValue, encodedWidth: config.width, encodedHeight: config.height,
                    fpsCeiling: config.fps, receivedFramesPerSecond: stats.framesPerSecond, receivedVideoKbps: stats.bitrateKbps,
                    controlRoundTripMs: stats.roundTripMillis, processCPUPercentOfOneCore: max(0, (usage.seconds - previousCPU) / max(0.001, now - previousTime) * 100),
                    processPeakRSSBytes: usage.peakRSS, batteryFraction: battery >= 0 ? battery : nil,
                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState.rawValue))
                previousCPU = usage.seconds; previousTime = now
                if let data = try? JSONEncoder().encode(trace) { try? data.write(to: url, options: .atomic) }
            }
        }
    }
    private static func cpuUsage() -> (seconds: Double, peakRSS: Int64) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
                Int64(usage.ru_maxrss))
    }
}
#endif
