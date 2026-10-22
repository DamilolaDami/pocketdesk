import AppIntents
import PDClientCore
import WidgetKit

/// The app's one controller, shared with intents: Siri can run a shortcut through a stream
/// that's already up, and the app can be launched in the background to run one.
@MainActor
enum AppModel {
    static let controller: SessionController = {
        let controller = SessionController()
        controller.onShortcutsChanged = {
            WidgetCenter.shared.reloadAllTimelines()
            ControlCenter.shared.reloadAllControls()
            PocketDeskShortcuts.updateAppShortcutParameters()
        }
        return controller
    }()
}

/// "Open Netflix on my Mac with PocketDesk": runs a saved shortcut without opening the app.
struct RunShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Shortcut on Mac"
    static let description = IntentDescription("Runs one of your PocketDesk shortcuts on your Mac, like opening Netflix or a favorite app.")

    @Parameter(title: "Shortcut")
    var shortcut: ShortcutEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$shortcut) on my Mac")
    }

    init() {}

    init(shortcut: ShortcutEntity) {
        self.shortcut = shortcut
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let preferred = UserDefaults.standard.string(forKey: SettingsKey.defaultMac).flatMap(UUID.init(uuidString:))
        do {
            let mac = try await AppModel.controller.runInBackground(shortcut.id, preferredHostID: preferred)
            return .result(dialog: "Done: \(shortcut.name) on \(mac).")
        } catch {
            return .result(dialog: "\(error.description)")
        }
    }
}

struct PocketDeskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunShortcutIntent(),
            phrases: [
                "Open \(\.$shortcut) on my Mac with \(.applicationName)",
                "Run \(\.$shortcut) on my Mac with \(.applicationName)",
                "\(.applicationName) \(\.$shortcut)",
            ],
            shortTitle: "Run on Mac",
            systemImageName: "macbook.gen2"
        )
    }
}
