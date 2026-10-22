#if os(macOS)
// Uses the macOS host engines (encoder, capture, HostService).
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import PDProtocol
import PDTransport
@testable import PDHostCore

/// NV12 frame filled with a flat luma value, the format ScreenCaptureKit hands us.
func makePixelBuffer(width: Int, height: Int, luma: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)!
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        memset(base, Int32(plane == 0 ? luma : 128), bytes)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

/// NV12 frame of random pixels.
func makeNoiseBuffer(width: Int, height: Int) -> CVPixelBuffer {
    let pixelBuffer = makePixelBuffer(width: width, height: height, luma: 0)
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        arc4random_buf(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)!, bytes)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

/// Builds a decoder format description from a keyframe's parameter sets, proving the
/// payload is something a phone can decode.
func formatDescription(fromKeyframe payload: [UInt8]) throws -> CMVideoFormatDescription {
    let parameterSets = try NALUnits.split(payload)
        .filter { [32, 33, 34].contains(NALUnits.hevcType(of: $0) ?? 0) }
        .map(Array.init)
    var description: CMFormatDescription?
    let status = parameterSets.withUnsafeBufferPointers { pointers, sizes in
        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: nil, parameterSetCount: pointers.count, parameterSetPointers: pointers,
            parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &description)
    }
    guard status == noErr, let description else { throw CocoaError(.coderInvalidValue) }
    return description
}

extension Array where Element == [UInt8] {
    func withUnsafeBufferPointers<R>(_ body: ([UnsafePointer<UInt8>], [Int]) -> R) -> R {
        let copies = map { bytes -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        return body(copies.map { UnsafePointer($0) }, map(\.count))
    }
}

/// `FrameSource` that emits flat frames with a changing luma at ~30 fps.
actor SyntheticFrameSource: FrameSource {
    let displaySize = (width: 1920, height: 1080)
    /// Random pixels instead of flat frames: incompressible, so the encoder fills its bitrate.
    private(set) var noisy: Bool
    init(noisy: Bool = false) { self.noisy = noisy }
    func setNoisy(_ noisy: Bool) { self.noisy = noisy }
    let window = WindowInfo(id: 42, appName: "Notes", bundleID: "com.apple.Notes", title: "Shopping", width: 800, height: 600)
    private var task: Task<Void, Never>?
    private(set) var audioConfigurations: [(Bool, UInt32)] = []
    func configureAudio(enabled: Bool, generation: UInt32) { audioConfigurations.append((enabled, generation)) }
    private(set) var startedSources: [CaptureSource] = []

    func displays() -> [DisplayInfo] {
        [DisplayInfo(id: 1, width: displaySize.width, height: displaySize.height, name: "Built-in", isMain: true, persistentID: "builtin"),
         DisplayInfo(id: 2, width: 2560, height: 1440, name: "External", persistentID: "external")]
    }
    func windows() -> [WindowInfo] { [window] }

    func resolve(_ source: CaptureSource?) throws -> ResolvedSource {
        switch source {
        case .display(2):
            ResolvedSource(source: .display(2), pixelWidth: 2560, pixelHeight: 1440,
                           screenFrame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
        case nil, .display(1):
            ResolvedSource(source: .display(1), pixelWidth: displaySize.width, pixelHeight: displaySize.height,
                           screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        case .display:
            throw CaptureError.sourceNotFound
        case .window(let id):
            ResolvedSource(source: .window(id), pixelWidth: 1600, pixelHeight: 1200,
                           screenFrame: CGRect(x: 100, y: 50, width: 800, height: 600), window: window)
        }
    }

    func start(_ source: ResolvedSource, width: Int, height: Int, fps: Int) -> AsyncStream<CapturedFrame> {
        task?.cancel()
        startedSources.append(source.source)
        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        task = Task {
            var frame: Int64 = 0
            while !Task.isCancelled {
                let buffer = noisy ? makeNoiseBuffer(width: width, height: height)
                    : makePixelBuffer(width: width, height: height, luma: UInt8(truncatingIfNeeded: frame * 8))
                continuation.yield(CapturedFrame(pixelBuffer: buffer, presentationTime: CMTime(value: frame, timescale: 30)))
                frame += 1
                try? await Task.sleep(for: .milliseconds(33))
            }
            continuation.finish()
        }
        return stream
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// The phone's end of the control stream: answers the host's link pings and skips link
/// reports, so tests see only the replies they asked for.
struct PhoneControl {
    let session: any PeerSession
    var messages: AsyncThrowingStream<ControlMessage, any Error>.AsyncIterator

    init(_ session: any PeerSession) {
        self.session = session
        messages = session.controlMessages.makeAsyncIterator()
    }

    mutating func next() async throws -> ControlMessage? {
        while let message = try await messages.next() {
            switch message {
            case .ping(let value): try await session.send(.pong(value))
            case .linkQuality: continue
            default: return message
            }
        }
        return nil
    }
}

/// Records injected input.
final class RecordingInputSink: InputSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [InputEvent] = []
    private var _text: [String] = []
    private var _frames: [CGRect] = []

    var events: [InputEvent] { lock.withLock { _events } }
    var text: [String] { lock.withLock { _text } }
    var sourceFrames: [CGRect] { lock.withLock { _frames } }

    func setSourceFrame(_ frame: CGRect) { lock.withLock { _frames.append(frame) } }
    func inject(_ event: InputEvent) { lock.withLock { _events.append(event) } }
    func insertText(_ text: String) { lock.withLock { _text.append(text) } }

    private var _actions: [MacAction] = []
    var actions: [MacAction] { lock.withLock { _actions } }

    /// Fails `openApp` for "Missing" so tests can check the error reaches the phone.
    func perform(_ action: MacAction) async throws {
        if case .openApp(_, "Missing") = action { throw MacActionError.appNotFound("Missing") }
        lock.withLock { _actions.append(action) }
    }
}
#endif
