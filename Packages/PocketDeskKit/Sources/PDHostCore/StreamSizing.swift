import PDProtocol

/// Picks the encode size: the source's aspect ratio, scaled down to fit the phone's screen in
/// pixels (in either orientation) times `zoomHeadroom`, never upscaled, and even in both
/// dimensions (4:2:0 chroma).
public enum StreamSizing {
    /// Extra resolution beyond the phone's screen so text stays sharp when pinch-zoomed.
    public static let defaultZoomHeadroom = 1.5

    public static func fit(sourceWidth: Int, sourceHeight: Int, into viewport: Viewport,
                           zoomHeadroom: Double = defaultZoomHeadroom,
                           maxPixels: Int = 3840 * 2160) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (0, 0) }
        // The phone can rotate, so fit within its long × short edge, matching the source's orientation.
        let longEdge = max(viewport.width, viewport.height) * viewport.scale * zoomHeadroom
        let shortEdge = min(viewport.width, viewport.height) * viewport.scale * zoomHeadroom
        let sourceIsLandscape = sourceWidth >= sourceHeight
        let boxWidth = sourceIsLandscape ? longEdge : shortEdge
        let boxHeight = sourceIsLandscape ? shortEdge : longEdge

        var scale = min(1, boxWidth / Double(sourceWidth), boxHeight / Double(sourceHeight))
        let pixels = Double(sourceWidth * sourceHeight) * scale * scale
        if pixels > Double(maxPixels) { scale *= (Double(maxPixels) / pixels).squareRoot() }

        return (even(Double(sourceWidth) * scale), even(Double(sourceHeight) * scale))
    }

    /// Bitrate heuristic for screen content: ~0.15 bits per pixel per frame, clamped. Text needs
    /// far more than camera video at the same size, and this is a LAN link.
    public static func bitrateKbps(width: Int, height: Int, fps: Int) -> Int {
        let kbps = Double(width * height * fps) * 0.15 / 1000
        return Int(min(max(kbps, 4_000), 50_000))
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int(value) & ~1)
    }
}
