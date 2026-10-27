#if os(macOS)
import CoreGraphics
import Foundation
import PDProtocol

/// Replays client `InputEvent`s as real macOS events. Needs the Accessibility grant and a
/// non-sandboxed host, which is why the host ships outside the Mac App Store.
///
/// `@unchecked Sendable`: the mutable state (source frame, pressed buttons) is behind a lock.
public final class InputInjector: InputSink, @unchecked Sendable {
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private let lock = NSLock()
    /// Screen-space rect (global display points) of the source being streamed.
    /// Normalized client coordinates map into it.
    private var sourceFrame: CGRect = CGDisplayBounds(CGMainDisplayID())
    private var pressedButtons: Set<MouseButton> = []
    private var pressedKeys: Set<UInt16> = []

    public init() {}

    public func setSourceFrame(_ frame: CGRect) {
        lock.withLock { sourceFrame = frame }
    }

    public func inject(_ event: InputEvent) {
        lock.withLock { injectLocked(event) }
    }

    /// Types committed text (IME, dictation, paste) as Unicode key events, which works
    /// regardless of the Mac's keyboard layout.
    public func insertText(_ text: String) {
        let units = Array(text.utf16)
        // CGEvent carries at most 20 UTF-16 units per event.
        for start in stride(from: 0, to: units.count, by: 20) {
            let chunk = Array(units[start..<min(start + 20, units.count)])
            for isDown in [true, false] {
                let event = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: isDown)
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    private func injectLocked(_ event: InputEvent) {
        switch event {
        case .scoped: return // Transport envelopes must be validated/unwrapped by HostSession.
        case let .pointerMove(x, y):
            let type: CGEventType = pressedButtons.contains(.left) ? .leftMouseDragged
                : pressedButtons.contains(.right) ? .rightMouseDragged : .mouseMoved
            post(CGEvent(mouseEventSource: eventSource, mouseType: type,
                         mouseCursorPosition: map(x, y), mouseButton: .left))

        case let .button(button, isDown, x, y):
            if isDown { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
            let (type, cgButton) = Self.mouseEvent(for: button, isDown: isDown)
            post(CGEvent(mouseEventSource: eventSource, mouseType: type,
                         mouseCursorPosition: map(x, y), mouseButton: cgButton))

        case let .scroll(dx, dy):
            post(CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                         wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0))

        case let .key(code, isDown, modifiers):
            if isDown { pressedKeys.insert(code) } else { pressedKeys.remove(code) }
            let keyEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: isDown)
            keyEvent?.flags = CGEventFlags(rawValue: UInt64(modifiers))
            post(keyEvent)
        }
    }

    public func releaseKeys() {
        lock.withLock {
            for code in pressedKeys {
                post(CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: false))
            }
            pressedKeys = []
            let location = CGEvent(source: eventSource)?.location ?? sourceFrame.origin
            for button in pressedButtons {
                let (type, mouseButton) = Self.mouseEvent(for: button, isDown: false)
                post(CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: location, mouseButton: mouseButton))
            }
            pressedButtons = []
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
