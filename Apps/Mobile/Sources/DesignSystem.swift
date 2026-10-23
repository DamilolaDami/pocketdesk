import PDClientCore
import PDProtocol
import SwiftUI

/// PocketDesk's look: a soft tinted backdrop with Liquid Glass surfaces on top.
enum Brand {
    static let accent = Color(red: 0.26, green: 0.47, blue: 1.0)
    static let online = Color.green
    static let cornerRadius: CGFloat = 28
}

/// Full-screen backdrop: in light mode a gentle mesh gradient that gives the glass something
/// to refract; in dark mode the plain system background.
struct AppBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                Color(.systemBackground)
            } else {
                MeshGradient(
                    width: 3, height: 3,
                    points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.6, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
                    colors: lightColors
                )
            }
        }
        .ignoresSafeArea()
    }

    private var lightColors: [Color] {
        [.init(white: 0.97), Brand.accent.opacity(0.18), .init(white: 0.97),
         .purple.opacity(0.10), .init(white: 0.98), Brand.accent.opacity(0.12),
         .init(white: 0.97), .cyan.opacity(0.12), .init(white: 0.96)]
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

/// The Mac itself, drawn: a MacBook, an iMac, or a display on a stand for Macs without a
/// screen, showing its own desktop picture. Asleep, the screen goes dark.
struct MacPreview: View {
    var kind: MacKind?
    /// The desktop picture, JPEG, as last seen.
    var wallpaper: Data?
    var status: MacGlyph.Status = .none
    var height: CGFloat = 120
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch kind {
            case .laptop, nil: laptop
            case .imac: imac
            case .mini, .studio, .pro, .desktop: display
            }
        }
        .frame(height: height)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.4 : 0.12), radius: height * 0.06, y: height * 0.03)
        .accessibilityHidden(true)
    }

    // MARK: Shapes

    private var laptop: some View {
        let screenHeight = height * 0.9
        let width = screenHeight * 1.5
        return VStack(spacing: 0) {
            screen(width: width, height: screenHeight, bezel: screenHeight * 0.045, corner: screenHeight * 0.06,
                   frame: Color(white: 0.12))
            // The base: wider than the lid, with the notch for opening it.
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: height * 0.05, bottomTrailingRadius: height * 0.05)
                    .fill(aluminium)
                    .frame(width: width * 1.16, height: height * 0.07)
                UnevenRoundedRectangle(bottomLeadingRadius: height * 0.02, bottomTrailingRadius: height * 0.02)
                    .fill(.black.opacity(0.18))
                    .frame(width: width * 0.16, height: height * 0.022)
            }
        }
    }

    private var imac: some View {
        let screenHeight = height * 0.62
        let width = screenHeight * 16 / 9 + height * 0.06
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                screen(width: width, height: screenHeight, bezel: height * 0.03, corner: height * 0.05,
                       frame: Color(white: colorScheme == .dark ? 0.9 : 0.97), roundBottom: false)
                // The chin, in the iMac's colour.
                UnevenRoundedRectangle(bottomLeadingRadius: height * 0.05, bottomTrailingRadius: height * 0.05)
                    .fill(Brand.accent.opacity(0.55).gradient)
                    .frame(width: width, height: height * 0.13)
            }
            stand(width: width * 0.22, neck: height * 0.17)
        }
    }

    private var display: some View {
        let screenHeight = height * 0.72
        let width = screenHeight * 16 / 9
        return VStack(spacing: 0) {
            screen(width: width, height: screenHeight, bezel: height * 0.03, corner: height * 0.04, frame: aluminium)
            stand(width: width * 0.24, neck: height * 0.2)
        }
        .overlay(alignment: .bottomTrailing) {
            // The Mac that drives it, beside the stand.
            Image(systemName: kind.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: height * 0.17, weight: .light))
                .foregroundStyle(Color(white: colorScheme == .dark ? 0.8 : 0.45))
                .offset(x: height * 0.22)
        }
    }

    private func stand(width: CGFloat, neck: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(aluminium.opacity(0.9)).frame(width: width * 0.8, height: neck)
            Capsule().fill(aluminium).frame(width: width * 1.25, height: max(3, height * 0.035))
        }
    }

    private func screen(width: CGFloat, height screenHeight: CGFloat, bezel: CGFloat, corner: CGFloat,
                        frame: Color, roundBottom: Bool = true) -> some View {
        let outer = UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: roundBottom ? corner : 0,
                                           bottomTrailingRadius: roundBottom ? corner : 0, topTrailingRadius: corner,
                                           style: .continuous)
        return outer
            .fill(frame)
            .frame(width: width, height: screenHeight)
            .overlay {
                picture
                    .frame(width: width - bezel * 2, height: screenHeight - bezel * 2)
                    .clipShape(.rect(cornerRadius: max(1, corner - bezel), style: .continuous))
            }
    }

    // MARK: The picture

    private var picture: some View {
        ZStack {
            if let image = wallpaper.flatMap(UIImage.init(data:)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                // Until the Mac has sent its own: something Mac-like.
                LinearGradient(colors: [Brand.accent, .purple, .orange.opacity(0.8)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            switch status {
            case .asleep:
                Color.black.opacity(0.82)
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: height * 0.16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            case .waking:
                Color.black.opacity(0.55)
                ProgressView().tint(.white)
            case .online, .none:
                EmptyView()
            }
        }
        .animation(.smooth, value: status)
    }

    private var aluminium: Color { Color(white: colorScheme == .dark ? 0.62 : 0.8) }
}
