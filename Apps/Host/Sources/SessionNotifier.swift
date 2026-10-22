import PDHostCore
import PDSecurity
import UserNotifications

/// Connecting is never silent: a notification when a phone starts viewing this Mac (with
/// Disconnect), and for anything waiting on the person at the Mac (with Allow and Deny for
/// connection requests). The menu bar panel may be closed when these happen.
@MainActor
final class SessionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let controller: HostController
    private let center = UNUserNotificationCenter.current()
    /// Notification ID → what its buttons act on.
    private var sessions: [String: Fingerprint] = [:]
    private var approvals: [String: UUID] = [:]

    private enum Category {
        static let session = "session"
        static let connectionRequest = "connection-request"
    }

    private enum Action {
        static let disconnect = "disconnect"
        static let allow = "allow"
        static let deny = "deny"
    }

    init(controller: HostController) {
        self.controller = controller
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Category.session, actions: [
                UNNotificationAction(identifier: Action.disconnect, title: "Disconnect", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.connectionRequest, actions: [
                UNNotificationAction(identifier: Action.allow, title: "Allow"),
                UNNotificationAction(identifier: Action.deny, title: "Deny", options: [.destructive]),
            ], intentIdentifiers: []),
        ])
        Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }

    func handle(_ event: HostEvent) {
        switch event {
        case .sessionStarted(let peer, let deviceName):
            let id = "session-\(peer)"
            sessions[id] = peer
            post(id: id, category: Category.session, title: "“\(deviceName)” is now viewing this Mac",
                 body: "It can see your screen and use the mouse and keyboard.")
        case .sessionEnded(let peer):
            let id = "session-\(peer)"
            sessions[id] = nil
            center.removeDeliveredNotifications(withIdentifiers: [id])
        case .approvalRequested(let approval):
            let id = "approval-\(approval.id)"
            approvals[id] = approval.id
            if approval.isConnectionRequest {
                post(id: id, category: Category.connectionRequest, title: "“\(approval.deviceName)” wants to view this Mac",
                     body: "Allow it to see your screen and use the mouse and keyboard?")
            } else if let code = approval.code {
                post(id: id, category: nil, title: "“\(approval.deviceName)” wants to pair",
                     body: "Accept in the PocketDesk menu only if the phone shows \(code).")
            }
        case .approvalResolved(let id):
            approvals["approval-\(id)"] = nil
            center.removeDeliveredNotifications(withIdentifiers: ["approval-\(id)"])
        default:
            break
        }
    }

    private func post(id: String, category: String?, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category { content.categoryIdentifier = category }
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A menu bar app is often "frontmost" while its panel is open; show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        await respond(to: action, on: id)
    }

    private func respond(to action: String, on id: String) async {
        switch action {
        case Action.disconnect:
            if let peer = sessions[id] { await controller.disconnect(peer) }
        case Action.allow, Action.deny:
            if let approval = approvals[id] { await controller.resolveApproval(approval, accepted: action == Action.allow) }
        default:
            break
        }
    }
}
