#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import CoreVideo
import Foundation
import PDHostCore
import PDProtocol
import PDVirtualDisplayProbeBackend

struct Options {
    var report: URL
    var cycles = 3
    var hold = 0
    var unavailable = false
    var inventory = false
    var surfaceDisplay: UInt32?

    init(_ arguments: [String]) throws {
        report = URL(fileURLWithPath: "/private/tmp/pocketdesk-display-probe.json")
        var args = arguments.makeIterator()
        while let argument = args.next() {
            switch argument {
            case "--report":
                guard let path = args.next(), path.hasPrefix("/") else { throw ProbeError("--report needs an absolute path") }
                report = URL(fileURLWithPath: path)
            case "--cycles":
                guard let value = args.next().flatMap(Int.init), (1...10).contains(value) else { throw ProbeError("--cycles must be 1…10") }
                cycles = value
            case "--hold-seconds":
                guard let value = args.next().flatMap(Int.init), (0...120).contains(value) else { throw ProbeError("--hold-seconds must be 0…120") }
                hold = value
            case "--simulate-unavailable": unavailable = true
            case "--inventory": inventory = true
            case "--surface-display":
                guard let id = args.next().flatMap(UInt32.init), id != 0 else { throw ProbeError("--surface-display needs a display ID") }
                surfaceDisplay = id
            default: throw ProbeError("Unknown argument: \(argument)")
            }
        }
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct DisplaySnapshot: Codable, Equatable {
    var id: UInt32
    var bounds: [Double]
    var pixels: [Int]
    var main: Bool
    var mirrorOf: UInt32
    var builtIn: Bool

    static func current() throws -> [Self] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { throw ProbeError("Cannot enumerate displays") }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { throw ProbeError("Cannot enumerate displays") }
        return ids.prefix(Int(count)).map { id in
            let rect = CGDisplayBounds(id)
            let mode = CGDisplayCopyDisplayMode(id)
            return Self(id: id, bounds: [rect.minX, rect.minY, rect.width, rect.height],
                        pixels: [mode?.pixelWidth ?? CGDisplayPixelsWide(id), mode?.pixelHeight ?? CGDisplayPixelsHigh(id)],
                        main: CGDisplayIsMain(id) != 0, mirrorOf: CGDisplayMirrorsDisplay(id), builtIn: CGDisplayIsBuiltin(id) != 0)
        }.sorted { $0.id < $1.id }
    }
}

struct Cycle: Codable {
    var displayID: UInt32
    var appeared = false
    var extended = false
    var capturedPixels: [Int] = []
    var windowOnVirtualDisplay = false
    var mappedClickReceived = false
    var removed = false
    var windowRehomed = false
    var captureActiveDuringHold = false
}

struct Report: Codable {
    var os = ProcessInfo.processInfo.operatingSystemVersionString
    var processID = ProcessInfo.processInfo.processIdentifier
    var backend = "Undocumented CoreGraphics runtime — developer probe only"
    var available = false
    var screenRecording = CGPreflightScreenCaptureAccess()
    var accessibility = AXIsProcessTrusted()
    var baseline: [DisplaySnapshot] = []
    var cycles: [Cycle] = []
    var final: [DisplaySnapshot] = []
    var physicalFallbackCaptured = false
    var error: String?
}

/// Only the probe's own scratch window is moved/clicked. No user window is manipulated.
@MainActor
final class Surface: NSObject {
    let window: NSWindow
    let button = NSButton(title: "Mapped input target", target: nil, action: nil)
    private(set) var clicks = 0
    private let originalFrame: NSRect

    override init() {
        window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 360, height: 180),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        originalFrame = window.frame
        super.init()
        window.title = "PocketDesk Phase 0 — scratch window"
        window.isReleasedWhenClosed = false
        button.frame = NSRect(x: 65, y: 65, width: 230, height: 50)
        button.target = self
        button.action = #selector(clicked)
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func clicked() { clicks += 1 }

    func move(to bounds: CGRect) {
        let height = NSScreen.screens.first { screenID($0) == CGMainDisplayID() }?.frame.maxY ?? 0
        window.setFrameOrigin(NSPoint(x: bounds.midX - 180, y: height - bounds.midY - 90))
        window.makeKeyAndOrderFront(nil)
    }

    func isOn(_ id: UInt32) -> Bool { window.screen.map { screenID($0) == id } ?? false }

    func target(in bounds: CGRect) -> (Float, Float) {
        let point = window.convertPoint(toScreen: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
        let height = NSScreen.screens.first { screenID($0) == CGMainDisplayID() }?.frame.maxY ?? 0
        return (Float((point.x - bounds.minX) / bounds.width), Float((height - point.y - bounds.minY) / bounds.height))
    }

    func visibleOn(_ ids: Set<UInt32>) -> Bool {
        NSScreen.screens.contains { ids.contains(screenID($0)) && window.frame.intersection($0.visibleFrame).width >= 40
            && window.frame.intersection($0.visibleFrame).height >= 40 }
    }

    func close() {
        window.setFrame(originalFrame, display: false)
        window.orderOut(nil)
    }

    private func screenID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

actor Probe {
    private var report = Report()
    private let options: Options
    private let source = ScreenCaptureSource()
    private var surface: Surface?
    private var liveDisplay: UInt32?

    init(options: Options) { self.options = options }

    func run() async -> Bool {
        do {
            report.baseline = try DisplaySnapshot.current()
            if options.inventory { report.final = report.baseline; try save(); return true }
            var error = [CChar](repeating: 0, count: 512)
            report.available = !options.unavailable && PDVDAvailable(&error, error.count)
            guard report.available else {
                report.error = options.unavailable ? "Simulated unavailable backend" : message(error)
                if report.screenRecording {
                    let display = try await source.resolve(nil)
                    report.physicalFallbackCaptured = try await capture(display).count == 2
                }
                report.final = try DisplaySnapshot.current()
                try save()
                return options.unavailable && report.final == report.baseline && report.physicalFallbackCaptured
            }
            surface = await Surface()
            for _ in 0..<options.cycles { try await cycle() }
            report.final = try DisplaySnapshot.current()
            guard report.final == report.baseline else { throw ProbeError("Original display layout changed") }
            await surface?.close()
            try save()
            return report.cycles.allSatisfy { $0.appeared && $0.extended && !$0.capturedPixels.isEmpty && $0.windowOnVirtualDisplay && $0.mappedClickReceived && $0.removed && $0.windowRehomed }
        } catch {
            report.error = String(describing: error)
            await source.stop()
            PDVDDestroy()
            liveDisplay = nil
            await surface?.close()
            report.final = (try? DisplaySnapshot.current()) ?? []
            try? save()
            return false
        }
    }

    private func cycle() async throws {
        var error = [CChar](repeating: 0, count: 512)
        let id = PDVDCreate(1280, 800, UInt32.random(in: 1...UInt32.max), &error, error.count)
        guard id != 0 else { throw ProbeError(message(error)) }
        liveDisplay = id
        report.cycles.append(Cycle(displayID: id))
        try save() // Checkpoint before capture/hold so a supervisor can verify crash cleanup.
        let deadline = ContinuousClock.now + .seconds(5)
        while !(try DisplaySnapshot.current()).contains(where: { $0.id == id }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let displays = try DisplaySnapshot.current()
        guard let created = displays.first(where: { $0.id == id }), displays.filter({ $0.id != id }) == report.baseline else {
            throw ProbeError("Display did not appear without changing original displays")
        }
        var cycle = Cycle(displayID: id)
        cycle.appeared = true
        cycle.extended = created.mirrorOf == 0 && !created.main
        guard cycle.extended else { throw ProbeError("Probe display is mirrored or primary") }
        let resolved = try await source.resolve(.display(id))
        await surface?.move(to: resolved.screenFrame)
        try await Task.sleep(for: .milliseconds(400))
        cycle.windowOnVirtualDisplay = await surface?.isOn(id) ?? false
        if report.screenRecording { cycle.capturedPixels = try await capture(resolved, stopAfter: options.hold == 0) }
        if report.accessibility, let surface {
            let clicksBefore = await surface.clicks
            let (x, y) = await surface.target(in: resolved.screenFrame)
            guard (0...1).contains(x), (0...1).contains(y) else { throw ProbeError("Scratch target is outside the virtual display") }
            let oldPointer = CGEvent(source: nil)?.location
            let injector = InputInjector()
            injector.setSourceFrame(resolved.screenFrame)
            injector.inject(.button(.left, isDown: true, x: x, y: y))
            injector.inject(.button(.left, isDown: false, x: x, y: y))
            try await Task.sleep(for: .milliseconds(300))
            cycle.mappedClickReceived = await surface.clicks == clicksBefore + 1
            if let oldPointer { CGWarpMouseCursorPosition(oldPointer) }
        }
        if options.hold > 0 {
            cycle.captureActiveDuringHold = !cycle.capturedPixels.isEmpty
            report.cycles[report.cycles.count - 1] = cycle
            try save()
            try await Task.sleep(for: .seconds(options.hold))
            await source.stop()
        }
        PDVDDestroy()
        liveDisplay = nil
        let cleanupDeadline = ContinuousClock.now + .seconds(5)
        while (try DisplaySnapshot.current()).contains(where: { $0.id == id }), ContinuousClock.now < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        cycle.removed = !(try DisplaySnapshot.current()).contains(where: { $0.id == id })
        try await Task.sleep(for: .milliseconds(500))
        cycle.windowRehomed = await surface?.visibleOn(Set(report.baseline.map(\.id))) ?? false
        report.cycles[report.cycles.count - 1] = cycle
        try save()
        guard cycle.removed else { throw ProbeError("Probe display still present after release") }
    }

    private func capture(_ resolved: ResolvedSource, stopAfter: Bool = true) async throws -> [Int] {
        let frames = try await source.start(resolved, width: 1280, height: 800, fps: 30)
        let dimensions = await withTaskGroup(of: [Int].self) { group in
            group.addTask {
                for await frame in frames { return [CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer)] }
                return []
            }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return [] }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
        if stopAfter { await source.stop() }
        guard dimensions.count == 2 else { throw ProbeError("No capture frame received before timeout") }
        return dimensions
    }

    private func message(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: options.report, options: .atomic)
    }
}

@main
struct Main {
    @MainActor static func main() {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            NSApplication.shared.setActivationPolicy(.accessory)
            Task {
                do {
                if let id = options.surfaceDisplay {
                    // Separate process: this window must survive termination of the process
                    // owning the virtual display, so crash rehoming can actually be observed.
                    let surface = Surface()
                    surface.move(to: CGDisplayBounds(id))
                    let others = Set((try DisplaySnapshot.current()).map(\.id)).subtracting([id])
                    for _ in 0..<120 {
                        try await Task.sleep(for: .milliseconds(500))
                        let result = ["onVirtualDisplay": surface.isOn(id), "visibleOnOtherDisplays": surface.visibleOn(others)]
                        try JSONEncoder().encode(result).write(to: options.report, options: .atomic)
                    }
                    surface.close()
                    exit(0)
                }
                let success = await Probe(options: options).run()
                print("Phase 0 report: \(options.report.path); complete: \(success)")
                exit(success ? 0 : 1)
                } catch {
                    fputs("\(error)\n", stderr)
                    exit(2)
                }
            }
            NSApplication.shared.run()
        } catch { fputs("\(error)\n", stderr); exit(2) }
    }
}
#endif
