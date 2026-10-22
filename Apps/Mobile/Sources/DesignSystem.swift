import SwiftUI

/// PocketDesk's look: a soft tinted backdrop with Liquid Glass surfaces on top.
enum Brand {
    static let accent = Color(red: 0.26, green: 0.47, blue: 1.0)
    static let online = Color.green
    static let cornerRadius: CGFloat = 28
}

/// Full-screen backdrop: a gentle mesh gradient that gives the glass something to refract.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: colorScheme == .dark ? darkColors : lightColors
        )
        .ignoresSafeArea()
    }

    private var lightColors: [Color] {
        [.init(white: 0.97), Brand.accent.opacity(0.18), .init(white: 0.97),
         .purple.opacity(0.10), .init(white: 0.98), Brand.accent.opacity(0.12),
         .init(white: 0.97), .cyan.opacity(0.12), .init(white: 0.96)]
    }

    private var darkColors: [Color] {
        [.black, Brand.accent.opacity(0.35), .black,
         .purple.opacity(0.25), .init(white: 0.06), Brand.accent.opacity(0.2),
         .black, .cyan.opacity(0.18), .black]
    }
}

extension View {
    /// A Liquid Glass card.
    func card(cornerRadius: CGFloat = Brand.cornerRadius, interactive: Bool = false) -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(interactive), in: .rect(cornerRadius: cornerRadius))
    }
}

/// "● Online" style status capsule.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: .capsule)
    }
}

/// A Mac glyph in a tinted circle.
struct MacGlyph: View {
    var size: CGFloat = 52
    var dimmed = false

    var body: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
            .frame(width: size, height: size)
            .background {
                Circle().fill(dimmed ? AnyShapeStyle(.quaternary)
                              : AnyShapeStyle(LinearGradient(colors: [Brand.accent, .purple.opacity(0.85)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
    }
}
