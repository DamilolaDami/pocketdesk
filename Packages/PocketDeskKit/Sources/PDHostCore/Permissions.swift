#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import ServiceManagement

/// The two TCC grants the host can't work without. Both are user-approved in System Settings;
/// the app can only check and prompt.
public struct HostPermissions: Sendable, Equatable {
    public enum Kind: Sendable, CaseIterable {
        case screenRecording, accessibility

        /// The Privacy & Security pane for this permission.
        var settingsURL: URL {
            switch self {
            case .screenRecording: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            }
        }
    }

    public var screenRecording: Bool
    public var accessibility: Bool

    public var allGranted: Bool { screenRecording && accessibility }

    public func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .screenRecording: screenRecording
        case .accessibility: accessibility
        }
    }

    public static func current() -> HostPermissions {
        HostPermissions(screenRecording: CGPreflightScreenCaptureAccess(),
                        accessibility: AXIsProcessTrusted())
    }

    /// Shows the system prompts for whatever is still missing.
    public static func request() {
        for kind in Kind.allCases { request(kind) }
    }

    /// Prompts once (which also adds the app to the list in System Settings), then opens
    /// the right pane so the toggle is one click away.
    public static func request(_ kind: Kind) {
        switch kind {
        case .screenRecording:
            if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        case .accessibility:
            if !AXIsProcessTrusted() {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
        }
        NSWorkspace.shared.open(kind.settingsURL)
    }
}

/// "Launch at Login", backed by the system's login items.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
#endif
