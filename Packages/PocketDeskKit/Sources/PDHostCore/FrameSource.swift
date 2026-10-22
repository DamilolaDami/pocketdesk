#if os(macOS)
import CoreGraphics
import CoreMedia
import CoreVideo
import PDProtocol

/// What to stream. `nil` in `selectSource` means the main display.
public enum CaptureSource: Sendable, Equatable {
    case display(UInt32)
    case window(UInt32)
}

/// A source looked up and measured, ready to capture.
public struct ResolvedSource: Sendable, Equatable {
    public var source: CaptureSource
    /// Native size in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Where it sits on screen, in global display points (CGEvent coordinates). Input maps here.
    public var screenFrame: CGRect
    /// Set for windows.
    public var window: WindowInfo?

    public init(source: CaptureSource, pixelWidth: Int, pixelHeight: Int, screenFrame: CGRect, window: WindowInfo? = nil) {
        self.source = source
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.screenFrame = screenFrame
        self.window = window
    }
}

/// A captured frame with new pixels (idle frames are filtered out at the source).
///
/// `@unchecked Sendable`: the pixel buffer is handed off once from the capture queue to the
/// encoder and never written after capture.
public struct CapturedFrame: @unchecked Sendable {
    public var pixelBuffer: CVPixelBuffer
    public var presentationTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
    }
}

/// Screen capture, abstracted so `HostSession` runs against synthetic frames in tests.
public protocol FrameSource: Sendable {
    func displays() async throws -> [DisplayInfo]
    func windows() async throws -> [WindowInfo]
    func resolve(_ source: CaptureSource?) async throws -> ResolvedSource
    /// Starts (or restarts) capture. The stream ends when capture stops.
    func start(_ source: ResolvedSource, width: Int, height: Int, fps: Int) async throws -> AsyncStream<CapturedFrame>
    func stop() async
}

/// Where injected input goes. `InputInjector` in the app; a recorder in tests.
public protocol InputSink: AnyObject, Sendable {
    func setSourceFrame(_ frame: CGRect)
    func inject(_ event: InputEvent)
    func insertText(_ text: String)
    /// Runs a phone shortcut. Throws `MacActionError` with a reason worth showing on the phone.
    func perform(_ action: MacAction) async throws
}
#endif
