import AppIntents
import PDClientCore
import WidgetKit

/// The app's one controller, shared with intents: Siri can run a shortcut through a stream
/// that's already up, and the app can be launched in the background to run one.
@MainActor
enum AppModel {
    static let controller: SessionController = {
        let controller = SessionController()
        controller.authenticate = DeviceOwner.authenticate
        controller.onShortcutsChanged = {
            WidgetCenter.shared.reloadAllTimelines()
            ControlCenter.shared.reloadAllControls()
            PocketDeskShortcuts.updateAppShortcutParameters()
        }
        return controller
    }()
}

/// "Open Netflix with PocketDesk": runs a saved shortcut without opening the app.
/// App Review rejects intent metadata (titles, descriptions, phrases, symbol names) that
/// contains "mac" anywhere, so these strings say "computer" instead.
struct RunShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Run PocketDesk Shortcut"
    static let description = IntentDescription("Runs one of your PocketDesk shortcuts on your computer, like opening Netflix or a favorite app.")

    @Parameter(title: "Shortcut")
    var shortcut: ShortcutEntity

    /// For search shortcuts (`{text}` in the link). Siri asks for it when it's needed.
    @Parameter(title: "Text", requestValueDialog: "What should it look for?")
    var text: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$shortcut) on my computer")
    }

    init() {}

    init(shortcut: ShortcutEntity) {
        self.shortcut = shortcut
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let preferred = UserDefaults.standard.string(forKey: SettingsKey.defaultMac).flatMap(UUID.init(uuidString:))
        do {
            let mac = try await AppModel.controller.runInBackground(shortcut.id, preferredHostID: preferred, text: text)
            return .result(dialog: "Done: \(shortcut.name) on \(mac).")
        } catch .needsText {
            throw $text.needsValueError("What should “\(shortcut.name)” look for?")
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
                "Open \(\.$shortcut) with \(.applicationName)",
                "Run \(\.$shortcut) with \(.applicationName)",
                "\(.applicationName) \(\.$shortcut)",
            ],
            shortTitle: "Run Shortcut",
            systemImageName: "laptopcomputer"
        )
    }
}
