import PDProtocol

public struct WorkspaceSizing: Sendable, Equatable {
    public enum Desktop: String, CaseIterable, Sendable { case largerText, standard, tablet }
    public var desktop: Desktop = .standard
    public var scale = 1
    public var refreshRate = 60
    public var portrait = false
    public var followsRotation = false
    public init() {}
    public var mode: VirtualDisplayMode {
        let dimensions: (Int, Int)
        switch desktop {
        case .largerText: dimensions = (1024, 768)
        case .standard: dimensions = (1280, 800)
        case .tablet: dimensions = (1280, 960)
        }
        return .init(width: portrait ? dimensions.1 : dimensions.0, height: portrait ? dimensions.0 : dimensions.1,
                     scale: portrait ? 2 : scale, refreshRate: refreshRate)
    }
    public mutating func accept(_ mode: VirtualDisplayMode) {
        guard mode.isValid else { return }
        let long = max(mode.width, mode.height), short = min(mode.width, mode.height)
        desktop = long == 1024 ? .largerText : (short == 960 ? .tablet : .standard)
        portrait = mode.isPortrait; scale = mode.scale; refreshRate = mode.refreshRate
    }
    /// Called with UIWindowScene.interfaceOrientation, never keyboard/view bounds.
    @discardableResult public mutating func observeOrientation(portrait: Bool) -> Bool {
        guard followsRotation, self.portrait != portrait else { return false }
        self.portrait = portrait
        if portrait { scale = 2 }
        return true
    }
}
