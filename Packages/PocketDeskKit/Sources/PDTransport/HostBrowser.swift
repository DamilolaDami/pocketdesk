import Foundation
import Network
import PDProtocol

/// A PocketDesk host seen on the local network.
public struct BrowsedHost: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// From the TXT record; matches `PairingInvite.hostID`.
    public var hostID: UUID?
    public var protocolVersion: UInt16?
    public var endpoint: NWEndpoint
}

public enum HostBrowser {
    /// The current set of hosts, re-emitted whenever it changes. Cancel iteration to stop.
    public static func hosts() -> AsyncThrowingStream<[BrowsedHost], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let browser = NetworkBrowser(for: .bonjour(bonjourServiceType, includeTxtRecord: true))
                    try await browser.run { endpoints in
                        continuation.yield(endpoints.map { endpoint in
                            BrowsedHost(id: endpoint.id, name: endpoint.name,
                                        hostID: endpoint.txtRecord["id"].flatMap(UUID.init(uuidString:)),
                                        protocolVersion: endpoint.txtRecord["v"].flatMap { UInt16($0) },
                                        endpoint: endpoint.nwEndpoint)
                        })
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
