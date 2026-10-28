import PDClientCore
import PDProtocol
import SwiftUI
import UIKit

/// The colors a Now Playing card is drawn with, from its style and its cover.
struct NowPlayingPalette {
    let card: NowPlayingCard

    /// PocketDesk blue (the app's `Brand.accent`, which the widget extension can't see).
    static let brand = Color(red: 0.26, green: 0.47, blue: 1.0)

    /// `nil` for the system style: the Lock Screen's own material.
    var background: LinearGradient? {
        switch card.style {
        case .system:
            return nil
        case .brand:
            return LinearGradient(colors: [Self.brand, Color(red: 0.13, green: 0.25, blue: 0.72)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .album:
            let tint = card.tint ?? CardColor(red: 0.3, green: 0.32, blue: 0.4)
            return LinearGradient(colors: [color(tint, scaled: 0.62), color(tint, scaled: 0.3)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// What the system paints behind the card (and while it animates in).
    var backgroundTint: Color? {
        switch card.style {
        case .system: nil
        case .brand: Self.brand
        case .album: color(card.tint ?? CardColor(red: 0.3, green: 0.32, blue: 0.4), scaled: 0.45)
        }
    }

    var foreground: Color { card.style == .system ? .primary : .white }

    /// The bars and the Dynamic Island's outline: the cover's color, lifted to show on black.
    var accent: Color {
        guard card.style == .album, let tint = card.tint else { return Self.brand }
        return Color(red: lifted(tint.red), green: lifted(tint.green), blue: lifted(tint.blue))
    }

    private func color(_ tint: CardColor, scaled factor: Double) -> Color {
        Color(red: tint.red * factor, green: tint.green * factor, blue: tint.blue * factor)
    }

    private func lifted(_ value: Double) -> Double { value + (1 - value) * 0.45 }
}

/// The Lock Screen card, laid out like the system's own Now Playing: cover with "Title • Artist"
/// and where it's playing, then elapsed · bar · remaining, then the controls centered below.
struct NowPlayingLockScreenView: View {
    let card: NowPlayingCard
    let artwork: UIImage?
    var siteIcon: UIImage?
    var isStale = false

    private var palette: NowPlayingPalette { NowPlayingPalette(card: card) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 52, palette: palette)
                NowPlayingHeadline(card: card, palette: palette, isStale: isStale)
            }
            NowPlayingProgress(card: card, foreground: palette.foreground)
            NowPlayingControls(card: card)
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background { palette.background }
    }
}

/// "Title • Artist" over "Spotify on Studio" (or a note that the card may be out of date), with
/// the level bars at the end of the first line.
struct NowPlayingHeadline: View {
    let card: NowPlayingCard
    let palette: NowPlayingPalette
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text([card.title, card.artist].compactMap(\.self).joined(separator: " • "))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !isStale {
                    NowPlayingBars(isPlaying: card.isPlaying, color: palette.accent)
                        .frame(width: 16, height: 12)
                }
            }
            Text(source)
                .font(.subheadline)
                .opacity(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var source: String {
        if isStale { return "Open PocketDesk to refresh" }
        guard let app = card.site ?? card.appName else { return "Playing on \(card.macName)" }
        return "\(app) on \(card.macName)"
    }
}

/// Previous, play / pause and next as plain glyphs, centered. Skips can be hidden in Settings.
struct NowPlayingControls: View {
    let card: NowPlayingCard
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 44 * scale) {
            if card.showsSkipButtons {
                button(.previous, symbol: "backward.fill", label: "Previous", size: 22)
            }
            button(.playPause, symbol: card.isPlaying ? "pause.fill" : "play.fill",
                   label: card.isPlaying ? "Pause" : "Play", size: 30)
            if card.showsSkipButtons {
                button(.next, symbol: "forward.fill", label: "Next", size: 22)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func button(_ control: MediaControl, symbol: String, label: String, size: CGFloat) -> some View {
        Button(intent: NowPlayingControlIntent(control)) {
            Image(systemName: symbol)
                .font(.system(size: size * scale, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44 * scale, height: 34 * scale)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The cover, else the site's icon on a white tile (as on the Home Screen), else a note on
/// the card's accent. A cover from a site wears the site's icon as a badge, when there's room.
struct NowPlayingArtworkView: View {
    let image: UIImage?
    var siteIcon: UIImage?
    let size: CGFloat
    let palette: NowPlayingPalette

    var body: some View {
        tile
            .overlay(alignment: .bottomTrailing) {
                if image != nil, let siteIcon, size >= 40 {
                    SiteIconTile(icon: siteIcon, size: size * 0.4)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: size * 0.1, y: size * 0.1)
                }
            }
            .accessibilityHidden(true)
    }

    private var tile: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let siteIcon {
                SiteIconTile(icon: siteIcon, size: size)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.accent.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// A site's icon inset on white, rounded like an app icon.
private struct SiteIconTile: View {
    let icon: UIImage
    let size: CGFloat

    var body: some View {
        Image(uiImage: icon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size * 0.66, height: size * 0.66)
            .frame(width: size, height: size)
            .background(.white)
            .clipShape(.rect(cornerRadius: size * 0.22, style: .continuous))
    }
}

/// Four level bars: lively while playing, flat while paused. A Live Activity can't animate on
/// its own, so the shape says it.
struct NowPlayingBars: View {
    let isPlaying: Bool
    let color: Color

    private static let levels: [CGFloat] = [0.5, 1, 0.68, 0.86]

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(Self.levels.count * 2 - 1)
            HStack(alignment: .center, spacing: width) {
                ForEach(Self.levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(color)
                        .frame(width: width, height: geometry.size.height * (isPlaying ? Self.levels[index] : 0.22))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }
}

extension NowPlayingCard {
    /// The cover saved in the App Group for this card, if it has one.
    var savedArtwork: UIImage? {
        artworkID.flatMap { UIImage(contentsOfFile: NowPlayingArtwork.url(for: $0).path(percentEncoded: false)) }
    }

    /// The site icon saved for this card, when a browser is playing it.
    var savedSiteIcon: UIImage? {
        siteIconID.flatMap { UIImage(contentsOfFile: NowPlayingArtwork.url(for: $0).path(percentEncoded: false)) }
    }
}

extension NowPlayingCard {
    /// Whether there's a position to draw: a known length, and a start (playing) or a frozen
    /// position (paused).
    var hasTimeline: Bool {
        guard let duration, duration.isFinite, duration > 0 else { return false }
        if isPlaying { return startedAt.map { $0.timeIntervalSince1970.isFinite } ?? false }
        return pausedElapsed?.isFinite ?? false
    }
}

/// Elapsed · bar · remaining on one line. System timers keep it moving on the Lock Screen
/// while the app isn't running.
struct NowPlayingProgress: View {
    let card: NowPlayingCard
    let foreground: Color

    /// Wide enough for "-59:59"; a timer text is otherwise as wide as it can be.
    private static let timeWidth: CGFloat = 42

    var body: some View {
        if card.hasTimeline, let duration = card.duration {
            HStack(spacing: 8) {
                if card.isPlaying, let start = card.startedAt {
                    let interval = start...start.addingTimeInterval(duration)
                    Text(timerInterval: interval, countsDown: false)
                        .frame(width: Self.timeWidth, alignment: .leading)
                    ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .labelsHidden()
                        .thickBar()
                    HStack(spacing: 0) {
                        Text("-")
                        Text(timerInterval: interval, countsDown: true)
                    }
                    .frame(width: Self.timeWidth, alignment: .trailing)
                } else if let elapsed = card.pausedElapsed {
                    let position = min(max(elapsed, 0), duration)
                    Text(time(position))
                        .frame(width: Self.timeWidth, alignment: .leading)
                    ProgressView(value: position, total: duration)
                        .labelsHidden()
                        .thickBar()
                    Text("-" + time(duration - position))
                        .frame(width: Self.timeWidth, alignment: .trailing)
                }
            }
            .progressViewStyle(.linear)
            .tint(foreground)
            .foregroundStyle(foreground.opacity(0.6))
            .font(.caption.weight(.medium).monospacedDigit())
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Playback progress")
        }
    }

    private func time(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

private extension View {
    /// The linear bar is a fixed 4pt. Stretched, then clipped back to a capsule, it's the
    /// system player's 7pt and still animates on its own from a timer.
    func thickBar() -> some View {
        scaleEffect(x: 1, y: 1.75, anchor: .center)
            .frame(height: 7)
            .clipShape(.capsule)
    }
}
