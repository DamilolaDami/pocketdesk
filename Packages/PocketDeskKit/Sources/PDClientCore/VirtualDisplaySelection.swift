import Foundation
import PDProtocol

/// Host-confirmed workspace state, with request correlation and connection-scoped reset.
public struct VirtualDisplaySelection: Sendable, Equatable {
    public private(set) var report: VirtualDisplayReport?
    public private(set) var pendingID: UUID?
    public private(set) var problem: String?
    public init() {}
    public enum Event: Sendable {
        case requested(UUID)
        case received(VirtualDisplayReport)
        case timedOut(UUID)
        case reset
    }
    public var isBusy: Bool {
        pendingID != nil || report?.phase == .creating || report?.phase == .ending
    }
    public func reduce(_ event: Event) -> Self {
        var next = self
        switch event {
        case .requested(let id):
            guard !isBusy else { return self }
            next.pendingID = id; next.problem = nil
        case .received(let report):
            if report.requestID == pendingID, pendingID != nil {
                next.pendingID = nil
                next.problem = report.problem == nil ? nil : report.message
            }
            guard self.report == nil || report.revision >= self.report!.revision else { return next }
            next.report = report
            if report.problem != nil { next.problem = report.message }
        case .timedOut(let id):
            guard pendingID == id else { return self }
            next.pendingID = nil
            next.problem = "The Mac hasn't confirmed this request. You can keep using a physical display; refresh to check the workspace."
        case .reset: next = Self()
        }
        return next
    }
}
