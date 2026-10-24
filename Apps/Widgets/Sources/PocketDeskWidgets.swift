import AppIntents
import PDClientCore
import SwiftUI
import WidgetKit

@main
struct PocketDeskWidgets: WidgetBundle {
    var body: some Widget {
        ShortcutsWidget()
        RunShortcutControl()
    }
}

// MARK: Home Screen and Lock Screen

struct ShortcutsEntry: TimelineEntry {
    let date: Date
    let shortcuts: [Shortcut]
}

struct ShortcutsProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShortcutsEntry {
        ShortcutsEntry(date: .now, shortcuts: ShortcutLibrary.starters)
    }

    func getSnapshot(in context: Context, completion: @escaping (ShortcutsEntry) -> Void) {
        completion(entry())
    }

    /// Shortcuts only change in the app, which reloads the timeline when they do.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShortcutsEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> ShortcutsEntry {
        let library = (try? ShortcutLibrary.load(from: ShortcutLibrary.sharedURL)) ?? ShortcutLibrary()
        return ShortcutsEntry(date: .now, shortcuts: library.shortcuts)
    }
}

struct ShortcutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Shortcuts", provider: ShortcutsProvider()) { entry in
            ShortcutsWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("PocketDesk Shortcuts")
        .description("Your first PocketDesk shortcuts, one tap away.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular])
    }
}

struct ShortcutsWidgetView: View {
    let entry: ShortcutsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            if let shortcut = entry.shortcuts.first {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: shortcut.symbol).font(.title2.weight(.semibold))
                }
                .widgetURL(shortcut.runURL)
            }
        case .accessoryRectangular:
            if let shortcut = entry.shortcuts.first {
                Label(shortcut.name, systemImage: shortcut.symbol)
                    .font(.headline)
                    .widgetURL(shortcut.runURL)
            }
        case .systemSmall:
            // A small widget has a single tap target.
            if let shortcut = entry.shortcuts.first {
                WidgetTile(shortcut: shortcut).widgetURL(shortcut.runURL)
            } else {
                EmptyWidget()
            }
        default:
            let count = family == .systemLarge ? 8 : 4
            let shortcuts = Array(entry.shortcuts.prefix(count))
            if shortcuts.isEmpty {
                EmptyWidget()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: family == .systemLarge ? 2 : 2),
                          spacing: 8) {
                    ForEach(shortcuts) { shortcut in
                        Link(destination: shortcut.runURL) { WidgetTile(shortcut: shortcut, compact: true) }
                    }
                }
            }
        }
    }
}

/// The app's tile, sized for a widget.
private struct WidgetTile: View {
    let shortcut: Shortcut
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: shortcut.symbol)
                .font(.system(size: compact ? 16 : 26, weight: .semibold))
            Spacer(minLength: 4)
            Text(shortcut.name)
                .font(compact ? .caption.weight(.semibold) : .headline)
                .lineLimit(1)
            if !compact {
                Text(shortcut.action.summary).font(.caption2).opacity(0.75).lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(shortcut.color.tint.gradient, in: .rect(cornerRadius: compact ? 14 : 20, style: .continuous))
    }
}

private struct EmptyWidget: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.grid.2x2.fill").font(.title2).foregroundStyle(.secondary)
            Text("Add shortcuts in PocketDesk").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

// MARK: Control Center

/// Which shortcut a Control Center control runs; picked when adding the control.
struct ShortcutControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "PocketDesk Shortcut"

    @Parameter(title: "Shortcut")
    var shortcut: ShortcutEntity?

    func perform() async throws -> some IntentResult { .result() }
}

struct RunShortcutControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "RunShortcut", intent: ShortcutControlConfiguration.self) { configuration in
            ControlWidgetButton(action: OpenURLIntent(configuration.shortcut.map { Shortcut.runURL(for: $0.id) }
                                                      ?? URL(string: "pocketdesk://")!)) {
                Label(configuration.shortcut?.name ?? "PocketDesk",
                      systemImage: configuration.shortcut?.symbol ?? "laptopcomputer")
            }
        }
        .displayName("Run Shortcut")
        .description("Runs a PocketDesk shortcut on your computer.")
    }
}
