import CoreGraphics

/// Maps touches on the (aspect-fit) stream view into the normalized 0...1 coordinates
/// `InputEvent` uses, so the Mac doesn't need to know anything about the phone's screen.
public enum VideoGeometry {
    /// Where an aspect-fit video of `videoSize` sits inside `viewSize`.
    public static func contentRect(videoSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Normalized position of `point` in the video. Points in the letterbox return `nil`,
    /// unless `clamped` (drags that wander off the edge keep tracking it).
    public static func normalized(_ point: CGPoint, videoSize: CGSize, in viewSize: CGSize,
                                  clamped: Bool = false) -> (x: Float, y: Float)? {
        let rect = contentRect(videoSize: videoSize, in: viewSize)
        guard rect.width > 0, rect.height > 0 else { return nil }
        var x = (point.x - rect.minX) / rect.width
        var y = (point.y - rect.minY) / rect.height
        if clamped {
            x = min(max(x, 0), 1)
            y = min(max(y, 0), 1)
        } else if !(0...1).contains(x) || !(0...1).contains(y) {
            return nil
        }
        return (Float(x), Float(y))
    }
}
