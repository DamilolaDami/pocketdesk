import Foundation

/// Requested desktop mode. The Mac advertises and validates the accepted modes.
public struct VirtualDisplayMode: Codable, Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    public var scale: Int
    public var refreshRate: Int
    public init(width: Int, height: Int, scale: Int = 1, refreshRate: Int = 60) {
        self.width = width; self.height = height; self.scale = scale; self.refreshRate = refreshRate
    }
    public static let standard = Self(width: 1280, height: 800)
    public static let presets = [(1024, 768), (1280, 800), (1280, 960)]
    public static var supported: [Self] {
        presets.flatMap { width, height in
            [false, true].flatMap { portrait in
                [1, 2].flatMap { scale in [30, 60].map { hz in
                    Self(width: portrait ? height : width, height: portrait ? width : height, scale: scale, refreshRate: hz)
                } }
            }
        }.filter { $0.isValid }
    }
    public var pixelWidth: Int { isValid ? width * scale : 0 }
    public var pixelHeight: Int { isValid ? height * scale : 0 }
    public var isPortrait: Bool { height > width }
    public var rotated: Self { Self(width: height, height: width, scale: height < width ? 2 : scale, refreshRate: refreshRate) }
    public var isValid: Bool {
        [1, 2].contains(scale) && [30, 60].contains(refreshRate) && (width >= height || scale == 2)
            && Self.presets.contains { (width == $0.0 && height == $0.1) || (height == $0.0 && width == $0.1) }
    }
    public var isBoundedRequest: Bool {
        (480...4096).contains(width) && (480...4096).contains(height) && [1, 2].contains(scale) && [30, 60].contains(refreshRate)
    }
    /// Ask for the device's aspect ratio without allocating at the device's Retina scale.
    public static func preferred(for viewport: Viewport) -> Self {
        guard viewport.width.isFinite, viewport.height.isFinite else { return .standard }
        let width = max(1, min(4096, viewport.width)), height = max(1, min(4096, viewport.height))
        let factor = 1280.0 / Double(max(width, height))
        return Self(width: max(480, Int(Double(width) * factor)), height: max(480, Int(Double(height) * factor)))
    }
}

public struct VirtualDisplayRequest: Codable, Sendable, Equatable {
    public var id: UUID
    public var mode: VirtualDisplayMode
    public init(id: UUID = UUID(), mode: VirtualDisplayMode) { self.id = id; self.mode = mode }
}

public struct VirtualDisplayEnd: Codable, Sendable, Equatable {
    public var id: UUID
    public var leaseID: UUID
    public init(id: UUID = UUID(), leaseID: UUID) { self.id = id; self.leaseID = leaseID }
}

public struct VirtualDisplayReport: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case idle, creating, configuring, active, ending, cleanupFailed }
    public enum Problem: String, Codable, Sendable { case disabled, unsupported, busy, invalidMode, notOwner, cancelled, failed }
    public struct Geometry: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public var pixelWidth: Int
        public var pixelHeight: Int
        public init(x: Double, y: Double, width: Double, height: Double, pixelWidth: Int, pixelHeight: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
            self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        }
    }
    public struct Workspace: Codable, Sendable, Equatable {
        public var leaseID: UUID
        public var logicalID: String
        public var displayID: UInt32
        public var ownerName: String
        public var isOwner: Bool
        public var geometry: Geometry?
        public var acceptedMode: VirtualDisplayMode
        public init(leaseID: UUID, logicalID: String, displayID: UInt32, ownerName: String, isOwner: Bool, acceptedMode: VirtualDisplayMode, geometry: Geometry? = nil) {
            self.leaseID = leaseID; self.logicalID = logicalID; self.displayID = displayID
            self.ownerName = ownerName; self.isOwner = isOwner; self.acceptedMode = acceptedMode; self.geometry = geometry
        }
    }
    public var revision: UInt64
    public var supported: Bool
    public var allowed: Bool
    public var suspended: Bool
    public var modes: [VirtualDisplayMode]
    public var phase: Phase
    public var workspace: Workspace?
    public var requestID: UUID?
    public var requestedMode: VirtualDisplayMode?
    public var problem: Problem?
    public var message: String?
    public init(revision: UInt64 = 0, supported: Bool = false, allowed: Bool = false, suspended: Bool = false,
                modes: [VirtualDisplayMode] = [], phase: Phase = .idle, workspace: Workspace? = nil,
                requestID: UUID? = nil, requestedMode: VirtualDisplayMode? = nil, problem: Problem? = nil, message: String? = nil) {
        self.revision = revision; self.supported = supported; self.allowed = allowed; self.suspended = suspended
        self.modes = modes; self.phase = phase; self.workspace = workspace; self.requestID = requestID
        self.requestedMode = requestedMode; self.problem = problem; self.message = message
    }
    public var canCreate: Bool { supported && allowed && !suspended && phase == .idle && workspace == nil }
}

public struct VirtualDisplayConfiguration: Codable, Sendable, Equatable {
    public var id: UUID
    public var leaseID: UUID
    public var mode: VirtualDisplayMode
    public var viewport: Viewport?
    public init(id: UUID = UUID(), leaseID: UUID, mode: VirtualDisplayMode, viewport: Viewport? = nil) {
        self.id = id; self.leaseID = leaseID; self.mode = mode; self.viewport = viewport
    }
}
