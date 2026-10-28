import SwiftUI

/// Shared look for the Mac app, matching the phone's.
enum HostBrand {
    static let accent = Color(red: 0.26, green: 0.47, blue: 1.0)
}

/// Spacing the menu bar panel lines up on.
enum HostMetrics {
    /// Inside a card, and for section titles and footnotes, so all text shares one edge.
    static let inset: CGFloat = 10
    static let cornerRadius: CGFloat = 10
    static let rowHeight: CGFloat = 30
}

/// The app's own icon.
struct AppGlyph: View {
    var size: CGFloat = 34
    /// Draws the artwork's edge, not the icon canvas's, at the frame's edge: macOS icons sit
    /// inside a transparent margin of about a tenth of their size.
    var trimsMargin = false

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .padding(trimsMargin ? -size * 0.1 : 0)
            .accessibilityHidden(true)
    }
}

/// A grouped card, as in System Settings: an optional title above, rows separated by inset
/// hairlines, and an optional footnote below. Every row should be a `PanelRow` (or be padded
/// by `HostMetrics.inset`) so their edges line up.
struct Panel<Content: View>: View {
    var title: String?
    /// Quiet text after the title ("Experimental").
    var note: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let note {
                        Text(note).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, HostMetrics.inset)
            }
            Group(subviews: content) { rows in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        if row.id != rows.first?.id {
                            Divider().padding(.leading, HostMetrics.inset)
                        }
                        row
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: .rect(cornerRadius: HostMetrics.cornerRadius, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HostMetrics.inset)
            }
        }
    }
}

/// One row in a `Panel`: a title with an optional subtitle, and whatever goes on the trailing
/// edge. No leading icons, so every title in the panel starts on the same edge.
struct PanelRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: HostMetrics.rowHeight)
        .padding(.horizontal, HostMetrics.inset)
        .padding(.vertical, subtitle == nil ? 2 : 6)
    }
}

extension PanelRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// A `PanelRow` with a small switch on the trailing edge.
struct SwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        PanelRow(title: title, subtitle: subtitle) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// The six-digit code in separate tiles, like on the phone.
struct CodeTiles: View {
    let code: String
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: size * 0.18) {
            ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                Text(String(digit))
                    .font(.system(size: size * 0.75, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: size, height: size * 1.3)
                    .background(.background, in: .rect(cornerRadius: size * 0.25, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(.separator)
                    }
                    .padding(.leading, index == 3 ? size * 0.3 : 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}
