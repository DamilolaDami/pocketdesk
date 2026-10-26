#if os(macOS)
import Foundation
import AppKit
import PDSecurity
import PDProtocol

/// Wires `HostService` to `HostStore` for the Mac app, and owns the app-level choices:
/// where files live, the persistent host ID, the Mac's display name.
@MainActor
public final class HostController {
    public let store = HostStore()
    private var service: HostService?
    private var runTask: Task<Void, Never>?
    private var powerObservers: [any NSObjectProtocol] = []
    private lazy var keepAwake = KeepAwake(settings: .load()) { [store] state in
        Task { @MainActor in store.send(.keepAwakeChanged(state)) }
    }

    /// For the app's notifications; called after the store has the event.
    public var onEvent: ((HostEvent) -> Void)?

    public init() {
        store.send(.keepAwakeChanged(KeepAwakeState(settings: .load())))
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            powerObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    await self?.keepAwake.send(.sleep)
                    await self?.service?.prepareForSleep()
                }
            })
        }
        powerObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                await self?.keepAwake.send(.wake)
                await self?.service?.resumeAfterSleep()
            }
        })
    }

    public func setKeepAwakeSettings(_ settings: KeepAwakeSettings) async {
        settings.save()
        await keepAwake.send(.settings(settings))
    }

    public func keepAvailable(for seconds: Int) async {
        await keepAwake.send(.keepAvailable(seconds: seconds))
    }

    public func endKeepAwake() async { await keepAwake.send(.endNow) }

    public func stop() async {
        await keepAwake.stop()
        runTask?.cancel()
        runTask = nil
    }

    /// Ends every session of `peer` (the menu's Disconnect, or a notification action).
    public func disconnect(_ peer: Fingerprint) async {
        await service?.disconnect(peer)
    }

    public var askBeforeConnecting: Bool {
        get { UserDefaults.standard.bool(forKey: Self.askKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.askKey)
            Task { [service] in await service?.setAskBeforeConnecting(newValue) }
        }
    }

    private static let askKey = "PocketDesk.askBeforeConnecting"

    public var relayServer: RelayServer? {
        guard UserDefaults.standard.bool(forKey: RelayServer.enabledKey) else { return nil }
        return RelayServer(address: RelayServer.savedAddress())
    }

    /// Settings are applied without interrupting the LAN listener.
    public func relaySettingsChanged() {
        let server = relayServer
        Task { [service] in await service?.setRelayServer(server) }
    }

    public func start() {
        guard runTask == nil else { return }
        let keepAwake = keepAwake
        Task { await keepAwake.start() }
        do {
            let store = store
            let service = try HostService(configuration: .init(
                hostID: Self.persistentHostID(),
                hostName: Host.current().localizedName ?? "Mac",
                trustStoreURL: Self.supportDirectory.appending(path: "trusted-phones.json"),
                askBeforeConnecting: askBeforeConnecting, relayServer: relayServer,
                nowPlayingPushesURL: Self.supportDirectory.appending(path: "now-playing-pushes.json")
            ), input: InputInjector(), keepAwake: keepAwake) { [weak self] event in
                Task { @MainActor in
                    store.send(event)
                    self?.onEvent?(event)
                }
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
