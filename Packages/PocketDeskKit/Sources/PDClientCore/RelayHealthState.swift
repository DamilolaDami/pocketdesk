import Foundation
import PDProtocol

/// A check of this phone's relay path, separate from whether any Mac is available there.
public struct RelayHealthState: Equatable, Sendable {
    public enum Status: Equatable, Sendable { case unchecked, checking, reachable, unreachable }
    public private(set) var status: Status = .unchecked
    public private(set) var server: RelayServer?
    public private(set) var checkedAt: Date?
    private var checkID: UUID?

    public init() {}

    public mutating func begin(server: RelayServer) -> UUID {
        let id = UUID()
        self.server = server
        checkID = id
        checkedAt = nil
        status = .checking
        return id
    }

    public mutating func finish(checkID: UUID, reachable: Bool, now: Date = .now) {
        guard self.checkID == checkID else { return }
        self.checkID = nil
        checkedAt = now
        status = reachable ? .reachable : .unreachable
    }
}
