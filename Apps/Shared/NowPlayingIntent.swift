import AppIntents
import PDProtocol

/// The Live Activity's buttons. App Review rejects intent metadata that says "mac", so these
/// strings say "computer".
enum MediaControl: String, AppEnum {
    case playPause, next, previous

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playback Control"
    static let caseDisplayRepresentations: [MediaControl: DisplayRepresentation] = [
        .playPause: "Play or Pause",
        .next: "Next Track",
        .previous: "Previous Track",
    ]

    var key: MediaKey {
        switch self {
        case .playPause: .playPause
        case .next: .next
        case .previous: .previous
        }
    }
}

/// Play / pause or skip from the Lock Screen and the Dynamic Island. Compiled into the widget
/// extension too, so its buttons can name it, but a Live Activity intent always runs in the
/// app's process (launched in the background if need be), which holds the connection.
struct NowPlayingControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control Playback"
    static let description = IntentDescription("Plays, pauses or skips what's playing on your computer.")
    static let isDiscoverable = false

    @Parameter(title: "Control")
    var control: MediaControl

    init() {}

    init(_ control: MediaControl) {
        self.control = control
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        guard await AppModel.controller.pressNowPlaying(control.key) else {
            throw NowPlayingControlFailure()
        }
        #endif
        return .result()
    }
}

private struct NowPlayingControlFailure: LocalizedError {
    var errorDescription: String? {
        "Couldn’t control playback. Open PocketDesk and check the computer’s connection."
    }
}
