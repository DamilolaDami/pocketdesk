import PDHostCore
import SwiftUI

/// Menu bar app (LSUIElement). Lives in the menu bar, launches at login via SMAppService.
@main
struct PocketDeskHostApp: App {
    @State private var permissions = HostPermissions.current()

    var body: some Scene {
        MenuBarExtra("PocketDesk", systemImage: "iphone.and.arrow.forward") {
            if permissions.allGranted {
                Text("Ready for connections")
            } else {
                Button("Grant permissions…") {
                    HostPermissions.request()
                    permissions = .current()
                }
            }
            Divider()
            Button("Quit PocketDesk") { NSApplication.shared.terminate(nil) }
        }
    }
}
