import CoreGraphics

/// Trackpad mode's pointer: where the phone has put the Mac's pointer, in the normalized 0...1
/// coordinates `InputEvent` uses. Fingers move it relatively, with acceleration, like a laptop
/// trackpad: slow moves are precise, flicks cross the screen.
public struct TrackpadPointer: Equatable, Sendable {
    public private(set) var x: Float
    public private(set) var y: Float

    public init(x: Float = 0.5, y: Float = 0.5) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    /// Pointer travel per point of finger travel: `baseGain` for slow moves, rising with the
    /// speed of each step (points per event) up to `maxGain`.
    static let baseGain: CGFloat = 1.2
    static let maxGain: CGFloat = 3.5
    static let gainPerPoint: CGFloat = 0.25

    static func gain(for step: CGFloat) -> CGFloat {
        min(baseGain + step * gainPerPoint, maxGain)
    }

    /// Moves by a finger step `delta` (in view points) over a picture shown at `pictureSize`
    /// points. Pass the zoomed size, so a zoomed-in picture gets finer control.
    public mutating func move(by delta: CGVector, pictureSize: CGSize) {
        guard pictureSize.width > 0, pictureSize.height > 0 else { return }
        let gain = Self.gain(for: (delta.dx * delta.dx + delta.dy * delta.dy).squareRoot())
        self = TrackpadPointer(x: x + Float(delta.dx * gain / pictureSize.width),
                               y: y + Float(delta.dy * gain / pictureSize.height))
    }
}

/// Three-finger swipes, as the Mac's own trackpad does them (sent as their key equivalents).
public enum MacGesture: Equatable, Sendable {
    case missionControl, appExpose, spaceLeft, spaceRight

    /// How far three fingers must travel to count as a swipe.
    static let minimumTravel: CGFloat = 40

    /// The swipe a three-finger pan of `translation` makes, if any.
    public init?(swipe translation: CGVector) {
        let horizontal = abs(translation.dx), vertical = abs(translation.dy)
        guard max(horizontal, vertical) >= Self.minimumTravel else { return nil }
        if vertical > horizontal {
            self = translation.dy < 0 ? .missionControl : .appExpose
        } else {
            // Like the Mac: swipe left to bring in the Space on the right.
            self = translation.dx < 0 ? .spaceRight : .spaceLeft
        }
    }

    /// The key that does it with ⌃ (Mission Control's default shortcuts).
    public var key: UInt16 {
        switch self {
        case .missionControl: MacKey.up
        case .appExpose: MacKey.down
        case .spaceLeft: MacKey.left
        case .spaceRight: MacKey.right
        }
    }

    /// The system shortcuts only answer arrows that look like they came from a keyboard,
    /// which flags them fn and numeric-pad.
    public var modifiers: MacModifiers { [.control, .function, .numericPad] }
}
