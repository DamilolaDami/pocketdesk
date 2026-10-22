import PDClientCore
import SwiftUI

/// "Start from…": every quick pick at a glance, by category, before the editor opens.
struct QuickPicksSheet: View {
    let controller: SessionController
    let pick: (ShortcutPreset) -> Void
    let startFromScratch: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(ShortcutPreset.Category.allCases, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(category.rawValue)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            FlowLayout(spacing: 8) {
                                ForEach(ShortcutPreset.all.filter { $0.category == category }) { preset in
                                    QuickPickChip(preset: preset, appIcon: preset.shortcut.appBundleID
                                        .flatMap { controller.store.appIcons[$0] }) {
                                        pick(preset)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            // Pinned, so it's there without scrolling past every pick; the picks blur away
            // under its bar instead of showing through the button.
            .scrollEdgeEffectStyle(.hard, for: .bottom)
            .safeAreaBar(edge: .bottom) {
                Button {
                    startFromScratch()
                } label: {
                    Label("Start from Scratch", systemImage: "square.and.pencil")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.accent)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .navigationTitle("New Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
            }
        }
    }
}

/// Lays chips out left to right, wrapping onto new rows like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if added > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// A quick pick, with the site's favicon or the app's icon when there is one, like its tile.
struct QuickPickChip: View {
    let preset: ShortcutPreset
    var appIcon: Data?
    let action: () -> Void
    @State private var favicon: UIImage?

    private var website: String? {
        if case .openURL(let url) = preset.shortcut.action { url } else { nil }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon.frame(width: 22, height: 22)
                Text(preset.shortcut.name)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(preset.shortcut.color.tint.gradient, in: .capsule)
        }
        .buttonStyle(.plain)
        .task(id: website) {
            guard let website, let data = await FaviconLoader.shared.icon(for: website) else { return }
            withAnimation(.smooth) { favicon = UIImage(data: data) }
        }
    }

    @ViewBuilder private var icon: some View {
        if let bundleID = preset.shortcut.appBundleID, let appIcon,
           let image = AppIconCache.image(for: bundleID, png: appIcon) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .padding(-2) // macOS icons carry a transparent margin
        } else if let favicon {
            Image(uiImage: favicon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(3)
                .background(.white, in: .circle)
        } else {
            Image(systemName: preset.shortcut.symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.22), in: .circle)
        }
    }
}
