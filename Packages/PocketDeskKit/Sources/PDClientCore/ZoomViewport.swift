import CoreGraphics

/// The phone-side zoom of the stream: a scale and a translation of the picture inside a
/// view of `viewSize`. The zoomed picture always covers the view (no panning past its edges).
/// Nothing here reaches the Mac; the stream view sends only what `pan(by:)` leaves over.
public struct ZoomViewport: Equatable, Sendable {
    public static let maxZoom: CGFloat = 6
    /// What a two-finger double-tap zooms to.
    public static let comfortableZoom: CGFloat = 2.5

    public var viewSize: CGSize {
        didSet { clamp() }
    }
    public private(set) var zoom: CGFloat = 1
    public private(set) var offset: CGPoint = .zero

    public init(viewSize: CGSize = .zero) {
        self.viewSize = viewSize
    }

    public var isZoomed: Bool { zoom > 1 }

    /// Moves the picture with the fingers as far as its edges allow, and returns the part
    /// of `delta` it couldn't use: that much should scroll the Mac instead.
    public mutating func pan(by delta: CGVector) -> CGVector {
        let before = offset
        offset.x += delta.dx
        offset.y += delta.dy
        clamp()
        return CGVector(dx: delta.dx - (offset.x - before.x), dy: delta.dy - (offset.y - before.y))
    }

    /// Scales by `factor` keeping `anchor` (a point in the view) over the same spot of the picture.
    public mutating func scale(by factor: CGFloat, about anchor: CGPoint) {
        zoom(to: zoom * factor, about: anchor)
    }

    public mutating func zoom(to newZoom: CGFloat, about anchor: CGPoint) {
        let clamped = min(max(newZoom, 1), Self.maxZoom)
        let factor = clamped / zoom
        offset.x = anchor.x - factor * (anchor.x - offset.x)
        offset.y = anchor.y - factor * (anchor.y - offset.y)
        zoom = clamped
        clamp()
    }

    /// Zoomed in: back to the whole screen. Otherwise: a comfortable zoom about `anchor`.
    public mutating func toggle(about anchor: CGPoint) {
        zoom(to: isZoomed ? 1 : Self.comfortableZoom, about: anchor)
    }

    /// Pans just enough to bring `point` (in the unzoomed picture's coordinates) at least
    /// `margin` inside the view, as the zoomed view follows the pointer.
    public mutating func reveal(_ point: CGPoint, margin: CGFloat) {
        guard isZoomed else { return }
        let shown = screenPoint(point)
        let marginX = min(margin, viewSize.width / 2), marginY = min(margin, viewSize.height / 2)
        if shown.x < marginX { offset.x += marginX - shown.x }
        if shown.x > viewSize.width - marginX { offset.x -= shown.x - (viewSize.width - marginX) }
        if shown.y < marginY { offset.y += marginY - shown.y }
        if shown.y > viewSize.height - marginY { offset.y -= shown.y - (viewSize.height - marginY) }
        clamp()
    }

    /// Where a point of the unzoomed picture shows in the view.
    public func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + point.x * zoom, y: offset.y + point.y * zoom)
    }

    public var transform: CGAffineTransform {
        CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: zoom, y: zoom)
    }

    private mutating func clamp() {
        offset.x = min(0, max(viewSize.width - viewSize.width * zoom, offset.x))
        offset.y = min(0, max(viewSize.height - viewSize.height * zoom, offset.y))
    }
}
