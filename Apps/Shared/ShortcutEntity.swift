import AppIntents
import Foundation
import PDClientCore

/// A saved PocketDesk shortcut, as Siri, the Shortcuts app, widgets and controls see it.
/// Read from the shared App Group copy of the library, so the widget extension sees it too.
struct ShortcutEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "PocketDesk Shortcut"
    static let defaultQuery = ShortcutQuery()

    let id: UUID
    let name: String
    let symbol: String

    init(_ shortcut: Shortcut) {
        id = shortcut.id
        name = shortcut.name
        symbol = shortcut.symbol
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    static func all() -> [ShortcutEntity] {
        ((try? ShortcutLibrary.load(from: ShortcutLibrary.sharedURL)) ?? ShortcutLibrary()).shortcuts.map(ShortcutEntity.init)
    }
}

struct ShortcutQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [ShortcutEntity] {
        ShortcutEntity.all().filter { identifiers.contains($0.id) }
    }

    /// "Open Netflix on my Mac": matched by name, loosely.
    func entities(matching string: String) async throws -> [ShortcutEntity] {
        ShortcutEntity.all().filter { $0.name.localizedStandardContains(string) || string.localizedStandardContains($0.name) }
    }

    func suggestedEntities() async throws -> [ShortcutEntity] {
        ShortcutEntity.all()
    }
}

extension Shortcut {
    /// Opens PocketDesk and runs this shortcut (widgets and controls use this).
    var runURL: URL { Self.runURL(for: id) }

    static func runURL(for id: UUID) -> URL {
        URL(string: "pocketdesk://run?id=\(id.uuidString)")!
    }

    /// The shortcut a `runURL` names.
    static func id(fromRunURL url: URL) -> UUID? {
        guard url.scheme == "pocketdesk", url.host() == "run" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value.flatMap(UUID.init(uuidString:))
    }
}
