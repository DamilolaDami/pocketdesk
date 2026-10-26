import PDHostCore
import SwiftUI

/// Menu bar app (LSUIElement): status, pairing, connected and paired phones.
@main
struct PocketDeskHostApp: App {
    @State private var controller: HostController
    @State private var notifier: SessionNotifier

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.store.state.connected.isEmpty ? "iphone" : "iphone.radiowaves.left.and.right")
                if controller.store.state.keepAwake.isActive {
                    Image(systemName: "cup.and.saucer.fill")
                }
            }
            .accessibilityLabel(controller.store.state.keepAwake.isActive ? "PocketDesk, keeping Mac awake" : "PocketDesk")
        }
        .menuBarExtraStyle(.window)

        Window("Remote Access", id: RelaySettingsWindow.id) {
            RelaySettingsWindow(controller: controller)
        }
        .windowResizability(.contentSize)

        Window("Pair a Phone", id: PairingWindow.id) {
            PairingWindow(controller: controller)
        }
        .windowResizability(.contentSize)

        Window("Welcome to PocketDesk", id: OnboardingWindow.id) {
            OnboardingWindow(controller: controller)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: OnboardingWindow.finishedKey) ? .suppressed : .presented)
    }

    init() {
        let controller = HostController()
        let notifier = SessionNotifier(controller: controller)
        controller.onEvent = { notifier.handle($0) }
        _controller = State(initialValue: controller)
        _notifier = State(initialValue: notifier)
        controller.start()
    }
}
