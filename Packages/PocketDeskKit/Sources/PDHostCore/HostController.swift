#if os(macOS)
import Foundation
import PDSecurity

/// Wires `HostService` to `HostStore` for the Mac app, and owns the app-level choices:
/// where files live, the persistent host ID, the Mac's display name.
@MainActor
public final class HostController {
    public let store = HostStore()
    private var service: HostService?
    private var runTask: Task<Void, Never>?

    public init() {}

    public func start() {
        guard runTask == nil else { return }
        do {
            let store = store
            let service = try HostService(configuration: .init(
                hostID: Self.persistentHostID(),
                hostName: Host.current().localizedName ?? "Mac",
                trustStoreURL: Self.supportDirectory.appending(path: "trusted-phones.json")
            ), input: InputInjector()) { event in
                Task { @MainActor in store.send(event) }
            }
            self.service = service
            runTask = Task { try? await service.run() }
        } catch {
            store.send(.stopped(error: String(describing: error)))
        }
    }

    public func openInvite() async -> PairingInvite? {
        await service?.openInvite()
    }

    public func closeInvite() async {
        await service?.closeInvite()
    }

    public func resolveApproval(_ id: UUID, accepted: Bool) async {
        await service?.resolveApproval(id, accepted: accepted)
    }

    public func revoke(_ peer: Fingerprint) async {
        try? await service?.revoke(peer)
    }

    private static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "PocketDesk", directoryHint: .isDirectory)
    }

    /// Stable across launches; phones match Bonjour results to their pinned host by it.
    private static func persistentHostID() -> UUID {
        let key = "PocketDesk.hostID"
        if let stored = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: stored) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }
}
#endif
