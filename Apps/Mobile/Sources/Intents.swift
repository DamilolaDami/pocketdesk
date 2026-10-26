import AppIntents
import PDClientCore
import PDProtocol
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
        #if DEBUG
        // Builds from Xcode get their push tokens from Apple's sandbox.
        controller.pushEnvironment = .sandbox
        #endif
        controller.nowPlayingPresenter = LiveActivityPresenter()
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
        // One set to ask first asks Siri's way. Asking for its words already counts.
        if AppModel.controller.store.shortcuts.first(where: { $0.id == shortcut.id })?.confirms == true, text == nil {
            try await requestConfirmation(result: .result(dialog: "Run “\(shortcut.name)” on your computer?"),
                                          confirmationActionName: .run)
        }
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

/// Runs one action that isn't a saved shortcut, for the intents below.
@MainActor
private func runOnComputer(_ name: String, _ action: MacAction) async -> String {
    let preferred = UserDefaults.standard.string(forKey: SettingsKey.defaultMac).flatMap(UUID.init(uuidString:))
    let shortcut = Shortcut(name: name, symbol: "bolt.fill", color: .gray, action: action, showsMac: false)
    do {
        let mac = try await AppModel.controller.runInBackground(shortcut, preferredHostID: preferred)
        return "Done on \(mac)."
    } catch {
        return error.description
    }
}

/// "Type on my computer with PocketDesk": dictate on the phone, the words appear at the
/// computer's cursor (or on its clipboard).
struct TypeOnComputerIntent: AppIntent {
    static let title: LocalizedStringResource = "Type on Computer"
    static let description = IntentDescription("Types text wherever the cursor is on your computer, or puts it on the computer's clipboard.")

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "What should I type?")
    var text: String

    @Parameter(title: "Copy Instead of Typing", default: false)
    var copies: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Type \(\.$text) on my computer") {
            \.$copies
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw $text.needsValueError("What should I type?") }
        let dialog = await runOnComputer(copies ? "Copy" : "Type", copies ? .copyText(trimmed) : .typeText(trimmed))
        return .result(dialog: "\(dialog)")
    }
}

enum ComputerCommand: String, AppEnum {
    case lockScreen, sleepDisplay, sleep, toggleDarkMode, screenshot

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Computer Command"
    static let caseDisplayRepresentations: [ComputerCommand: DisplayRepresentation] = [
        .lockScreen: DisplayRepresentation(title: "Lock Computer", image: .init(systemName: "lock.fill")),
        .sleepDisplay: DisplayRepresentation(title: "Sleep Display", image: .init(systemName: "display")),
        .sleep: DisplayRepresentation(title: "Sleep Computer", image: .init(systemName: "moon.zzz.fill")),
        .toggleDarkMode: DisplayRepresentation(title: "Toggle Dark Mode", image: .init(systemName: "circle.lefthalf.filled")),
        .screenshot: DisplayRepresentation(title: "Take a Screenshot", image: .init(systemName: "camera.viewfinder")),
    ]

    var command: MacCommand { MacCommand(rawValue: rawValue)! }
}

/// "Lock Computer with PocketDesk", "Sleep Display with PocketDesk"…
struct ComputerCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Control Computer"
    static let description = IntentDescription("Locks or sleeps your computer, turns its display off, switches dark mode or takes a screenshot.")

    @Parameter(title: "Command")
    var command: ComputerCommand

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$command)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(await runOnComputer(command.command.title, .system(command.command)))")
    }
}

/// "Set computer volume with PocketDesk".
struct SetComputerVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Computer Volume"
    static let description = IntentDescription("Sets your computer's sound volume.")

    @Parameter(title: "Volume", inclusiveRange: (0, 100), requestValueDialog: "What volume, from 0 to 100?")
    var level: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set computer volume to \(\.$level)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(await runOnComputer("Volume", .setVolume(min(max(level, 0), 100))))")
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
        AppShortcut(
            intent: TypeOnComputerIntent(),
            phrases: [
                "Type on my computer with \(.applicationName)",
                "Dictate to my computer with \(.applicationName)",
            ],
            shortTitle: "Type on Computer",
            systemImageName: "keyboard.fill"
        )
        AppShortcut(
            intent: ComputerCommandIntent(),
            phrases: [
                "\(\.$command) with \(.applicationName)",
                "\(.applicationName) \(\.$command)",
            ],
            shortTitle: "Control Computer",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: SetComputerVolumeIntent(),
            phrases: ["Set computer volume with \(.applicationName)"],
            shortTitle: "Computer Volume",
            systemImageName: "speaker.wave.2.fill"
        )
    }
}
