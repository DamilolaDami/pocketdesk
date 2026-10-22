#if os(macOS)
import CoreGraphics
import PDProtocol

/// Replays client `InputEvent`s as real macOS events. Needs the Accessibility grant and a
/// non-sandboxed host, which is why the host ships outside the Mac App Store.
///
/// `@unchecked Sendable`: owned and only called by the `HostSession` actor, which serializes
/// access to the mutable button state.
public final class InputInjector: @unchecked Sendable {
    /// Screen-space rect (global display points) of the source being streamed.
    /// Normalized client coordinates map into it.
    public var sourceFrame: CGRect

    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var pressedButtons: Set<MouseButton> = []

    public init(sourceFrame: CGRect) {
        self.sourceFrame = sourceFrame
    }

    public func inject(_ event: InputEvent) {
        switch event {
        case let .pointerMove(x, y):
            let point = map(x, y)
            let type: CGEventType = pressedButtons.contains(.left) ? .leftMouseDragged
                : pressedButtons.contains(.right) ? .rightMouseDragged : .mouseMoved
            post(CGEvent(mouseEventSource: eventSource, mouseType: type,
                         mouseCursorPosition: point, mouseButton: .left))

        case let .button(button, isDown, x, y):
            if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            let (type, cgButton) = Self.mouseEvent(for: button, isDown: isDown)
            post(CGEvent(mouseEventSource: eventSource, mouseType: type,
                         mouseCursorPosition: map(x, y), mouseButton: cgButton))

        case let .scroll(dx, dy):
            post(CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                         wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0))

        case let .key(code, isDown, modifiers):
            let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: isDown)
            keyEvent?.flags = CGEventFlags(rawValue: UInt64(modifiers))
            post(keyEvent)
        }
    }

    private func map(_ x: Float, _ y: Float) -> CGPoint {
        CGPoint(x: sourceFrame.minX + CGFloat(min(max(x, 0), 1)) * sourceFrame.width,
                y: sourceFrame.minY + CGFloat(min(max(y, 0), 1)) * sourceFrame.height)
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    private static func mouseEvent(for button: MouseButton, isDown: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case .left: (isDown ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (isDown ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (isDown ? .otherMouseDown : .otherMouseUp, .center)
        }
    }
}
#endif
