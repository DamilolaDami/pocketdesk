import PDHostCore
import SwiftUI

/// Menu bar app (LSUIElement): status, pairing, connected and paired phones.
@main
struct PocketDeskHostApp: App {
    @State private var controller: HostController

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.store.state.connected.isEmpty ? "iphone" : "iphone.radiowaves.left.and.right")
        }
        .menuBarExtraStyle(.window)

        Window("Pair a Phone", id: PairingWindow.id) {
            PairingWindow(controller: controller)
        }
        .windowResizability(.contentSize)
    }

    init() {
        let controller = HostController()
        _controller = State(initialValue: controller)
        controller.start()
    }
}
