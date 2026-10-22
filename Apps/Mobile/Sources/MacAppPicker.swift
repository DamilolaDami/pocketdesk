import PDClientCore
import PDProtocol
import SwiftUI

/// The apps installed on the Mac, with their real icons, to pick one for a shortcut.
struct MacAppPicker: View {
    let controller: SessionController
    let selected: String?
    let pick: (MacApp) -> Void
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var store: SessionStore { controller.store }

    private var apps: [MacApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? store.macApps : store.macApps.filter { $0.name.localizedStandardContains(trimmed) }
    }

    var body: some View {
        List(apps) { app in
            Button {
                pick(app)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    AppIconImage(bundleID: app.bundleID, png: store.appIcons[app.bundleID], size: 36)
                    Text(app.name)
                    Spacer()
                    if app.bundleID == selected {
                        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Brand.accent)
                    }
                }
            }
            .foregroundStyle(.primary)
        }
        .overlay { emptyState }
        .searchable(text: $query, prompt: "Search apps")
        .navigationTitle(macName.map { "Apps on \($0)" } ?? "Mac Apps")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { controller.loadApps(preferredHostID: UUID(uuidString: defaultMacID), force: true) }
        .task { controller.loadApps(preferredHostID: UUID(uuidString: defaultMacID)) }
    }

    private var macName: String? {
        controller.shortcutTarget(preferredHostID: UUID(uuidString: defaultMacID))?.name
    }

    @ViewBuilder private var emptyState: some View {
        if store.macApps.isEmpty {
            switch store.catalogStatus {
            case .idle, .loading:
                ProgressView("Asking your Mac…")
            case .unavailable:
                ContentUnavailableView("No Mac Online", systemImage: "laptopcomputer.slash",
                                       description: Text("Open PocketDesk on a paired Mac to see its apps."))
            case .failed(let reason):
                ContentUnavailableView("Couldn't Load Apps", systemImage: "exclamationmark.triangle",
                                       description: Text(reason))
            case .loaded:
                ContentUnavailableView.search(text: query)
            }
        } else if apps.isEmpty {
            ContentUnavailableView.search(text: query)
        }
    }
}

/// A Mac app icon from its PNG, or a placeholder while it loads.
struct AppIconImage: View {
    let bundleID: String
    let png: Data?
    var size: CGFloat = 36

    var body: some View {
        if let image = AppIconCache.image(for: bundleID, png: png) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(.quaternary)
                .frame(width: size * 0.82, height: size * 0.82)
                .frame(width: size, height: size)
        }
    }
}

/// Decoded icons, so long lists don't decode PNGs on every redraw.
@MainActor
enum AppIconCache {
    private static var images: [String: (byteCount: Int, image: UIImage)] = [:]

    static func image(for bundleID: String, png: Data?) -> UIImage? {
        guard let png else { return nil }
        if let cached = images[bundleID], cached.byteCount == png.count { return cached.image }
        guard let image = UIImage(data: png) else { return nil }
        images[bundleID] = (png.count, image)
        return image
    }
}
