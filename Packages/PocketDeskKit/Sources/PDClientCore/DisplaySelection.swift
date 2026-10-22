import Foundation
import PDProtocol

/// Confirmed selection from the host, never an optimistic picker value.
public struct DisplaySelection: Sendable, Equatable {
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var selectedID: UInt32?
    public init() {}

    public enum Event: Sendable {
        case available([DisplayInfo])
        case streaming(UInt32?)
        case reset
    }

    public func reduce(_ event: Event) -> Self {
        var next = self
        switch event {
        case .available(let displays):
            next.displays = displays
            if let selectedID, !displays.contains(where: { $0.id == selectedID }) { next.selectedID = nil }
        case .streaming(let id):
            // Window streams don't replace the last whole-display choice.
            if let id { next.selectedID = id }
        case .reset:
            next = Self()
        }
        return next
    }
}

/// Keyed by the paired Mac's stable host UUID, not its Bonjour name or endpoint.
struct DisplayPreferences: Codable, Sendable, Equatable {
    private var selections: [String: String] = [:]

    func displayID(for host: UUID?) -> String? { host.flatMap { selections[$0.uuidString] } }
    mutating func remember(_ display: String, for host: UUID) { selections[host.uuidString] = display }
    mutating func forget(_ host: UUID) { selections.removeValue(forKey: host.uuidString) }

    static func load(from url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
