import PDClientCore
import PDProtocol
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

/// The Mac itself, the way Apple draws devices: its own symbol on a quiet tile, with a
/// small status badge (online, asleep) where Find My or Messages would put one.
struct MacGlyph: View {
    enum Status { case none, online, asleep, waking }

    var kind: MacKind?
    var size: CGFloat = 52
    var status: Status = .none
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: kind.symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.46, weight: .light))
            .foregroundStyle(symbolColor)
            .symbolEffect(.pulse, options: .repeating, isActive: status == .waking)
            .frame(width: size, height: size)
            .background(tile, in: .rect(cornerRadius: size * 0.27, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0 : 0.07), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: size * 0.06, y: size * 0.02)
            .overlay(alignment: .bottomTrailing) { badge }
            .accessibilityHidden(true)
    }

    private var tile: Color { colorScheme == .dark ? Color(white: 0.17) : .white }

    private var symbolColor: Color {
        let ink = colorScheme == .dark ? Color(white: 0.86) : Color(white: 0.32)
        return status == .asleep ? ink.opacity(0.45) : ink
    }

    @ViewBuilder private var badge: some View {
        let diameter = max(9, size * 0.24)
        let ring = max(2, diameter * 0.2)
        switch status {
        case .online:
            Circle().fill(Brand.online)
                .frame(width: diameter, height: diameter)
                .padding(ring)
                .background(tile, in: .circle)
                .offset(x: diameter * 0.35, y: diameter * 0.35)
        case .asleep:
            Image(systemName: "moon.fill")
                .font(.system(size: diameter * 0.6, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter * 1.15, height: diameter * 1.15)
                .background(Color(white: 0.55), in: .circle)
                .padding(ring)
                .background(tile, in: .circle)
                .offset(x: diameter * 0.4, y: diameter * 0.4)
        case .none, .waking:
            EmptyView()
        }
    }
}

extension Optional where Wrapped == MacKind {
    /// Macs that don't say what they are are drawn as a MacBook, the most common Mac.
    var symbol: String {
        switch self {
        case .laptop, nil: "macbook.gen2"
        case .imac, .desktop: "desktopcomputer"
        case .mini: "macmini"
        case .studio: "macstudio"
        case .pro: "macpro.gen3"
        }
    }
}

extension DiscoveredHost {
    var glyphStatus: MacGlyph.Status {
        if isOnline { .online } else if isWaking { .waking } else { .asleep }
    }
}
