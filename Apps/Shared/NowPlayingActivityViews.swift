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

/// The Lock Screen card: cover, title and artist, where it's playing, and the buttons.
struct NowPlayingLockScreenView: View {
    let card: NowPlayingCard
    let artwork: UIImage?
    var siteIcon: UIImage?
    var isStale = false

    private var palette: NowPlayingPalette { NowPlayingPalette(card: card) }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 56, palette: palette)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let subtitle = card.artist ?? card.appName {
                        Text(subtitle)
                            .font(.subheadline)
                            .opacity(0.72)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                NowPlayingBars(isPlaying: card.isPlaying && !isStale, color: palette.accent)
                    .frame(width: 22, height: 18)
            }
            NowPlayingProgress(card: card, foreground: palette.foreground)
            HStack(spacing: 10) {
                NowPlayingSource(card: card, isStale: isStale)
                Spacer(minLength: 8)
                NowPlayingControls(card: card, palette: palette, size: 40)
            }
        }
        .foregroundStyle(palette.foreground)
        .padding(16)
        .background { palette.background }
    }
}

/// "Spotify on Studio" ("netflix.com on Studio" from a browser), or a note that the card may
/// be out of date.
struct NowPlayingSource: View {
    let card: NowPlayingCard
    var isStale = false

    var body: some View {
        Label {
            Text(isStale ? "Open PocketDesk to refresh"
                         : [card.site ?? card.appName, card.macName].compactMap(\.self).joined(separator: " on "))
                .lineLimit(1)
        } icon: {
            Image(systemName: isStale ? "clock.arrow.circlepath" : "laptopcomputer")
        }
        .font(.caption.weight(.medium))
        .opacity(0.65)
        .labelStyle(.titleAndIcon)
    }
}

/// Previous, play / pause and next. Skips can be hidden in Settings.
struct NowPlayingControls: View {
    let card: NowPlayingCard
    let palette: NowPlayingPalette
    var size: CGFloat = 40

    var body: some View {
        HStack(spacing: 6) {
            if card.showsSkipButtons {
                skip(.previous, symbol: "backward.fill", label: "Previous")
            }
            Button(intent: NowPlayingControlIntent(.playPause)) {
                Image(systemName: card.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(card.style == .system ? Color(uiColor: .systemBackground) : .black)
                    .frame(width: size, height: size)
                    .background(palette.foreground, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(card.isPlaying ? "Pause" : "Play")
            if card.showsSkipButtons {
                skip(.next, symbol: "forward.fill", label: "Next")
            }
        }
    }

    private func skip(_ control: MediaControl, symbol: String, label: String) -> some View {
        Button(intent: NowPlayingControlIntent(control)) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.36, weight: .semibold))
                .frame(width: size, height: size)
                .background(palette.foreground.opacity(0.14), in: .circle)
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

/// System timers continue on the Lock Screen when the app isn't running.
struct NowPlayingProgress: View {
    let card: NowPlayingCard
    let foreground: Color

    var body: some View {
        if let duration = card.duration, duration.isFinite, duration > 0 {
            VStack(spacing: 4) {
                if card.isPlaying, let start = card.startedAt, start.timeIntervalSince1970.isFinite {
                    let interval = start...start.addingTimeInterval(duration)
                    ProgressView(timerInterval: interval, countsDown: false)
                        .labelsHidden()
                    Text(timerInterval: interval, countsDown: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !card.isPlaying, let elapsed = card.pausedElapsed, elapsed.isFinite {
                    ProgressView(value: min(max(elapsed, 0), duration), total: duration)
                    Text(Duration.seconds(min(max(elapsed, 0), duration)), format: .time(pattern: .minuteSecond))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .tint(foreground)
            .foregroundStyle(foreground.opacity(0.7))
            .font(.caption2.monospacedDigit())
            .accessibilityLabel("Playback progress")
        }
    }
}
