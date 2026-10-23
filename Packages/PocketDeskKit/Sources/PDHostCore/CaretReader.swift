#if os(macOS)
import ApplicationServices
import CoreGraphics
import PDProtocol

/// Where the text caret is, so a zoomed-in phone can keep it on screen while typing.
public protocol CaretSource: Sendable {
    /// The caret of the focused text field, in global display points (top-left origin, like
    /// `CGDisplayBounds`), or `nil` when nothing with a caret has focus or it can't be read.
    func caretFrame() async -> CGRect?
}

extension Caret {
    /// `frame` (global display points) as a point of the streamed picture at `source`;
    /// `nil` when it isn't on that picture (another display, another window).
    public init?(frame: CGRect, in source: CGRect) {
        guard source.width > 0, source.height > 0,
              source.contains(CGPoint(x: frame.minX, y: frame.midY)) else { return nil }
        self.init(x: Float((frame.minX - source.minX) / source.width),
                  y: Float((frame.midY - source.minY) / source.height),
                  height: Float(frame.height / source.height))
    }
}

/// Reads the caret through the Accessibility API (the grant input already needs). Apps that
/// don't expose text ranges (some terminals, games) just report none.
public struct AccessibilityCaret: CaretSource {
    /// How long one Accessibility call may wait on a busy app.
    static let timeout: Float = 0.25

    public init() {}

    public func caretFrame() async -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        return await Task.detached { Self.read() }.value
    }

    private static func read() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        guard let focused = attribute(kAXFocusedUIElementAttribute, of: system),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        guard let rangeValue = attribute(kAXSelectedTextRangeAttribute, of: element),
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }
        // An empty range has no bounds in many apps: measure the character before the caret
        // and stand at its end instead.
        let caret = CFRange(location: range.location + range.length, length: 0)
        if let frame = bounds(of: caret, in: element), frame.height > 0 { return frame }
        guard caret.location > 0,
              let before = bounds(of: CFRange(location: caret.location - 1, length: 1), in: element),
              before.height > 0 else { return nil }
        return CGRect(x: before.maxX, y: before.minY, width: 0, height: before.height)
    }

    private static func bounds(of range: CFRange, in element: AXUIElement) -> CGRect? {
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
#endif
