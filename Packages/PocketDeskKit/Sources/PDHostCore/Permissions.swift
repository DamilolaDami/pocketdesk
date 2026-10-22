#if os(macOS)
import ApplicationServices
import CoreGraphics

/// The two TCC grants the host can't work without. Both are user-approved in System Settings;
/// the app can only check and prompt.
public struct HostPermissions: Sendable, Equatable {
    public var screenRecording: Bool
    public var accessibility: Bool

    public var allGranted: Bool { screenRecording && accessibility }

    public static func current() -> HostPermissions {
        HostPermissions(screenRecording: CGPreflightScreenCaptureAccess(),
                        accessibility: AXIsProcessTrusted())
    }

    /// Shows the system prompts for whatever is still missing.
    public static func request() {
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
}
#endif
