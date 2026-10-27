#if os(macOS)
import AppKit
import ColorSync
import CoreGraphics
import CoreMedia
import Foundation
import PDProtocol
@preconcurrency import ScreenCaptureKit

/// `FrameSource` backed by ScreenCaptureKit. Needs the Screen Recording permission.
public actor ScreenCaptureSource: FrameSource {
    private var audioEnabled = false
    private var generation: UInt32 = 0
    private var audio = AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error>.makeStream(bufferingPolicy: .bufferingNewest(8))

    public func configureAudio(enabled: Bool, generation: UInt32) {
        audioEnabled = enabled
        self.generation = generation
    }

    public func audioFrames() -> AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error> { audio.stream }

    private var stream: SCStream?
    private var output: StreamOutput?
    private let sampleQueue = DispatchQueue(label: "com.pocketdesk.capture", qos: .userInteractive)

    private let includingOwnWindows: Bool
    /// The developer capture proof includes only its own scratch surface. Production
    /// callers keep the default, which excludes the host's windows from display capture.
    public init(includingOwnWindows: Bool = false) { self.includingOwnWindows = includingOwnWindows }

    public func displays() async throws -> [DisplayInfo] {
        let screens = await MainActor.run {
            Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, (String, Double))? in
                guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (number.uint32Value, (screen.localizedName, Double(screen.backingScaleFactor)))
            })
        }
        return try await SCShareableContent.current.displays.map { display in
            let (width, height) = Self.pixelSize(of: display.displayID, scale: screens[display.displayID]?.1 ?? 1)
            let uuid = CGDisplayCreateUUIDFromDisplayID(display.displayID)?.takeRetainedValue()
            let persistentID = uuid.map { CFUUIDCreateString(nil, $0) as String }
            return DisplayInfo(id: display.displayID, width: width, height: height,
                               name: screens[display.displayID]?.0 ?? "Display", isMain: CGDisplayIsMain(display.displayID) != 0,
                               persistentID: persistentID)
        }
    }

    public func windows() async throws -> [WindowInfo] {
        let ownBundleID = Bundle.main.bundleIdentifier
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows
            .filter { window in
                window.windowLayer == 0 && window.isOnScreen && window.frame.width >= 80 && window.frame.height >= 60
                    && window.owningApplication != nil
                    && window.owningApplication?.bundleIdentifier != ownBundleID
            }
            .map(Self.info(for:))
    }

    public func resolve(_ source: CaptureSource?) async throws -> ResolvedSource {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        switch source {
        case nil:
            guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
            else { throw CaptureError.sourceNotFound }
            return await Self.resolved(display)
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceNotFound }
            return await Self.resolved(display)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.sourceNotFound }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = Double(filter.pointPixelScale)
            return ResolvedSource(source: .window(id),
                                  pixelWidth: Int(window.frame.width * scale), pixelHeight: Int(window.frame.height * scale),
                                  screenFrame: window.frame, window: Self.info(for: window))
        }
    }

    public func start(_ source: ResolvedSource, width: Int, height: Int, fps: Int) async throws -> AsyncStream<CapturedFrame> {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        switch source.source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceNotFound }
            // Leave our own UI (menu bar extra, pairing window) out of the stream.
            let ownApps = includingOwnWindows ? [] : content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.sourceNotFound }
            filter = SCContentFilter(desktopIndependentWindow: window)
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // NV12 is what the hardware encoder consumes natively; no conversion pass.
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        // Match the encoder's color tags (BT.709), and render in sRGB so text stays crisp.
        configuration.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = 4
        configuration.showsCursor = true
        // Capture from the Retina backing store, not 1x points scaled up: the biggest single
        // factor in how crisp text looks on the phone.
        configuration.captureResolution = .best
        configuration.preservesAspectRatio = true
        configuration.capturesAudio = audioEnabled
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = false

        let (frames, continuation) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        audio = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        let output = try StreamOutput(continuation: continuation, audio: audio.continuation,
                                      encoder: audioEnabled ? AACEncoder() : nil, generation: generation)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        if audioEnabled { try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue) }
        try await stream.startCapture()
        self.stream = stream
        self.output = output
        return frames
    }

    public func stop() async {
        if let stream { try? await stream.stopCapture() }
        output?.finish()
        stream = nil
        output = nil
    }

    private static func resolved(_ display: SCDisplay) async -> ResolvedSource {
        let id = display.displayID
        let scale = await MainActor.run {
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.backingScaleFactor ?? 1
        }
        let (width, height) = pixelSize(of: id, scale: scale)
        return ResolvedSource(source: .display(display.displayID), pixelWidth: width, pixelHeight: height,
                              screenFrame: CGDisplayBounds(display.displayID))
    }

    private static func pixelSize(of displayID: CGDirectDisplayID, scale: Double) -> (Int, Int) {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else {
            let bounds = CGDisplayBounds(displayID)
            return (Int(bounds.width * scale), Int(bounds.height * scale))
        }
        let bounds = CGDisplayBounds(displayID)
        if (mode.width > mode.height) != (bounds.width > bounds.height) { return (mode.pixelHeight, mode.pixelWidth) }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    private static func info(for window: SCWindow) -> WindowInfo {
        WindowInfo(id: window.windowID,
                   appName: window.owningApplication?.applicationName ?? "",
                   bundleID: window.owningApplication?.bundleIdentifier,
                   title: window.title ?? "",
                   width: Int(window.frame.width), height: Int(window.frame.height))
    }
}

public enum CaptureError: Error, Sendable {
    case sourceNotFound
    case audioEncoding
}

/// Receives sample buffers on the capture queue and forwards complete frames.
///
/// `@unchecked Sendable`: only touched from ScreenCaptureKit's sample queue after setup;
/// the continuation itself is thread-safe.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CapturedFrame>.Continuation

    private let audio: AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error>.Continuation
    private let encoder: AACEncoder?
    private let generation: UInt32

    init(continuation: AsyncStream<CapturedFrame>.Continuation,
         audio: AsyncThrowingStream<(AudioFrameHeader, [UInt8]), any Error>.Continuation,
         encoder: AACEncoder?, generation: UInt32) {
        self.audio = audio
        self.encoder = encoder
        self.generation = generation
        self.continuation = continuation
    }

    func finish() { continuation.finish(); audio.finish() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio, sampleBuffer.isValid, let encoder {
            do {
                for (time, payload) in try encoder.encode(sampleBuffer) {
                    audio.yield((AudioFrameHeader(captureTimeMicros: time, sourceGeneration: generation,
                                                 payloadLength: UInt32(payload.count)), payload))
                }
            } catch { audio.finish(throwing: error) }
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        continuation.yield(CapturedFrame(pixelBuffer: pixelBuffer,
                                         presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish()
        audio.finish(throwing: error)
    }
}
#endif
