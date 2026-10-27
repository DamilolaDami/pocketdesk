import Foundation
import Network
import PDProtocol
import PDSecurity
import PDTransport
import Synchronization

public enum HostUpdateClient {
    /// Dedicated stable ALPN; never sends a streaming hello or arbitrary feed/download URL.
    /// Install is sent once. Reconnects after a restart only query status.
    public static func watch(local: NWEndpoint?, relay: RelayServer?, identity: DeviceIdentity,
                             host: Fingerprint, deviceName: String, install: Bool,
                             onStatus: @escaping @Sendable (HostUpdateStatus) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await perform(local: local, relay: relay, identity: identity, host: host, deviceName: deviceName, install: install, onStatus: onStatus) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                onStatus(.init(phase: .failed, message: "The Mac didn't finish in time. Check PocketDesk on the Mac and try again."))
            }
            await group.next(); group.cancelAll()
        }
    }
    private static func perform(local: NWEndpoint?, relay: RelayServer?, identity: DeviceIdentity,
                                host: Fingerprint, deviceName: String, install: Bool,
                                onStatus: @escaping @Sendable (HostUpdateStatus) -> Void) async {
        let initialBuild = Mutex<String?>(nil)
        let sentInstall = Mutex(false)
        let reached = Mutex(false)
        let deadline = ContinuousClock.now + .seconds(180)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            do {
                try await PathFinder.connect(local: local, relay: relay, identity: identity, host: host,
                                             applicationProtocol: maintenanceALPN, onPath: { _ in }) { session in
                    var replies = session.controlMessages.makeAsyncIterator()
                    try await session.send(.hostUpdate(.init(action: .status, deviceName: deviceName)))
                    while let message = try await replies.next() {
                        guard case .hostUpdateStatus(let status) = message else { throw ClientError.unexpectedMessage }
                        reached.withLock { $0 = true }
                        let changedBuild = initialBuild.withLock { build in
                            if build == nil { build = status.build; return false }
                            return build != status.build
                        }
                        if changedBuild, install {
                            var completed = status
                            completed.phase = .upToDate
                            completed.message = status.hostProtocol == protocolVersion ? "PocketDesk updated. Close this screen and connect to your Mac." : "The Mac updated. Update this iPhone app too if versions still differ."
                            onStatus(completed)
                            return
                        }
                        onStatus(status)
                        if status.phase == .unavailable || (!install && !status.isBusy)
                            || (sentInstall.withLock({ $0 }) && (status.phase == .failed || status.phase == .upToDate)) {
                            return
                        }
                        try Task.checkCancellation()
                        let shouldInstall = install && sentInstall.withLock { sent in
                            guard !sent else { return false }; sent = true; return true
                        }
                        if shouldInstall {
                            try await session.send(.hostUpdate(.init(action: .install, deviceName: deviceName)))
                        } else {
                            try await Task.sleep(for: .seconds(1))
                            try await session.send(.hostUpdate(.init(action: .status, deviceName: deviceName)))
                        }
                    }
                    throw TransportError.closed
                }
                return
            } catch {
                if Task.isCancelled { return }
                guard reached.withLock({ $0 }) else {
                    onStatus(.init(phase: .unavailable, message: "Couldn't reach the Mac's update service. Older PocketDesk hosts need one manual update on the Mac first. Check the Mac is awake and reachable."))
                    return
                }
                onStatus(.init(phase: .installing, message: "Reconnecting to the Mac…"))
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        if !Task.isCancelled { onStatus(.init(phase: .failed, message: "The Mac didn't reconnect in time. Check PocketDesk on the Mac and try again.")) }
    }
}
