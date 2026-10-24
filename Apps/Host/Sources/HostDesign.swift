import SwiftUI

/// Shared look for the Mac app, matching the phone's.
enum HostBrand {
    static let accent = Color(red: 0.26, green: 0.47, blue: 1.0)
    static let gradient = LinearGradient(colors: [accent, .purple.opacity(0.85)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The app's own icon.
struct AppGlyph: View {
    var size: CGFloat = 34

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A rounded section with an optional title.
struct Panel<Content: View>: View {
    var title: String?
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.map { AnyShapeStyle($0.opacity(0.12)) } ?? AnyShapeStyle(.quaternary.opacity(0.6)))
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
                    .font(.system(size: size * 0.75, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: size, height: size * 1.3)
                    .background(.background, in: .rect(cornerRadius: size * 0.25))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(.separator)
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
        Circle().fill(color).frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}
