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

/// The Lock Screen card: cover, where it's playing, title and artist, and play / pause; then
/// previous · progress · next along the bottom.
struct NowPlayingLockScreenView: View {
    let card: NowPlayingCard
    let artwork: UIImage?
    var siteIcon: UIImage?
    var isStale = false

    private var palette: NowPlayingPalette { NowPlayingPalette(card: card) }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 58, palette: palette)
                NowPlayingHeadline(card: card, palette: palette, isStale: isStale)
                Spacer(minLength: 4)
                NowPlayingPlayButton(card: card, palette: palette, size: 42)
            }
            NowPlayingTransport(card: card, palette: palette, isStale: isStale)
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background { palette.background }
    }
}

/// Where it's playing (with the level bars), then the title and artist.
struct NowPlayingHeadline: View {
    let card: NowPlayingCard
    let palette: NowPlayingPalette
    var isStale = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            NowPlayingSource(card: card, palette: palette, isStale: isStale)
                .padding(.bottom, 2)
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
    }
}

/// "Spotify on Studio" ("netflix.com on Studio" from a browser), or a note that the card may
/// be out of date.
struct NowPlayingSource: View {
    let card: NowPlayingCard
    let palette: NowPlayingPalette
    var isStale = false

    var body: some View {
        HStack(spacing: 5) {
            if isStale {
                Image(systemName: "clock.arrow.circlepath")
            } else {
                NowPlayingBars(isPlaying: card.isPlaying, color: palette.accent)
                    .frame(width: 11, height: 9)
            }
            Text(isStale ? "Open PocketDesk to refresh"
                         : [card.site ?? card.appName, card.macName].compactMap(\.self).joined(separator: " on "))
                .lineLimit(1)
                .opacity(0.65)
        }
        .font(.caption2.weight(.semibold))
    }
}

/// Previous · progress · next. Without a timeline the middle says where it's playing from;
/// without skips (hidden in Settings) the progress runs the full width.
struct NowPlayingTransport: View {
    let card: NowPlayingCard
    let palette: NowPlayingPalette
    var isStale = false
    var skipSize: CGFloat = 34

    var body: some View {
        if card.hasTimeline || card.showsSkipButtons {
            HStack(spacing: 10) {
                if card.showsSkipButtons {
                    NowPlayingSkipButton(control: .previous, palette: palette, size: skipSize)
                }
                if card.hasTimeline {
                    NowPlayingProgress(card: card, foreground: palette.foreground)
                } else {
                    Spacer(minLength: 0)
                }
                if card.showsSkipButtons {
                    NowPlayingSkipButton(control: .next, palette: palette, size: skipSize)
                }
            }
        }
    }
}

/// The filled play / pause circle.
struct NowPlayingPlayButton: View {
    let card: NowPlayingCard
    let palette: NowPlayingPalette
    var size: CGFloat = 42

    var body: some View {
        Button(intent: NowPlayingControlIntent(.playPause)) {
            Image(systemName: card.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(card.style == .system ? Color(uiColor: .systemBackground) : .black)
                .frame(width: size, height: size)
                .background(palette.foreground, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(card.isPlaying ? "Pause" : "Play")
    }
}

/// Previous or next, as a soft circle either side of the progress.
struct NowPlayingSkipButton: View {
    let control: MediaControl
    let palette: NowPlayingPalette
    var size: CGFloat = 34

    var body: some View {
        Button(intent: NowPlayingControlIntent(control)) {
            Image(systemName: control == .next ? "forward.fill" : "backward.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .background(palette.foreground.opacity(0.14), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control == .next ? "Next" : "Previous")
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

/// A thin bar with the elapsed time under its left end and the length under its right. System
/// timers keep it moving on the Lock Screen while the app isn't running.
struct NowPlayingProgress: View {
    let card: NowPlayingCard
    let foreground: Color

    var body: some View {
        if card.hasTimeline, let duration = card.duration {
            VStack(spacing: 3) {
                if card.isPlaying, let start = card.startedAt {
                    let interval = start...start.addingTimeInterval(duration)
                    ProgressView(timerInterval: interval, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                        .labelsHidden()
                    HStack {
                        // A timer text is as wide as it can be; pin it so it can't push the length off.
                        Text(timerInterval: interval, countsDown: false)
                            .frame(width: 44, alignment: .leading)
                        Spacer(minLength: 4)
                        length(duration)
                    }
                } else if let elapsed = card.pausedElapsed {
                    let position = min(max(elapsed, 0), duration)
                    ProgressView(value: position, total: duration)
                        .labelsHidden()
                    HStack {
                        Text(Duration.seconds(position), format: .time(pattern: .minuteSecond))
                        Spacer(minLength: 4)
                        length(duration)
                    }
                }
            }
            .progressViewStyle(.linear)
            .tint(foreground)
            .foregroundStyle(foreground.opacity(0.62))
            .font(.caption2.weight(.medium).monospacedDigit())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Playback progress")
        }
    }

    private func length(_ duration: Double) -> some View {
        Text(Duration.seconds(duration), format: .time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}
