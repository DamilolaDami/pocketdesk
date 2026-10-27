/// Frozen maintenance v1 envelope. Keep these cases/fields compatible across stream versions.
public let maintenanceALPN = "pocketdesk-maintenance/1"

public struct HostUpdateRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case status, install }
    public var action: Action
    public var deviceName: String
    public init(action: Action, deviceName: String) { self.action = action; self.deviceName = deviceName }
}

public struct HostUpdateStatus: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable {
        case unavailable, idle, checking, downloading, installing, upToDate, failed
    }
    public var phase: Phase
    public var version: String
    public var build: String
    public var hostProtocol: UInt16
    public var message: String?
    public var progress: Double?
    public init(phase: Phase, version: String = "", build: String = "", hostProtocol: UInt16 = protocolVersion,
                message: String? = nil, progress: Double? = nil) {
        self.phase = phase; self.version = version; self.build = build; self.hostProtocol = hostProtocol
        self.message = message; self.progress = progress
    }
    public var isBusy: Bool { phase == .checking || phase == .downloading || phase == .installing }
}
