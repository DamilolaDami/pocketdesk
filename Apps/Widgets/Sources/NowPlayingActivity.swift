import ActivityKit
import PDClientCore
import PDProtocol
import SwiftUI
import WidgetKit

/// What the Mac is playing, on the Lock Screen and in the Dynamic Island. The app starts,
/// updates and ends it (`LiveActivityPresenter`); this only draws it.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            let card = context.state
            NowPlayingLockScreenView(card: card, artwork: card.savedArtwork, siteIcon: card.savedSiteIcon, isStale: context.isStale)
                .activityBackgroundTint(NowPlayingPalette(card: card).backgroundTint)
                .activitySystemActionForegroundColor(NowPlayingPalette(card: card).foreground)
        } dynamicIsland: { context in
            let card = context.state
            let palette = NowPlayingPalette(card: card)
            let artwork = card.savedArtwork
            let siteIcon = card.savedSiteIcon
            let playing = card.isPlaying && !context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 52, palette: palette)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NowPlayingBars(isPlaying: playing, color: palette.accent)
                        .frame(width: 24, height: 20)
                        .padding(.trailing, 6)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title).font(.headline).lineLimit(1)
                        if let subtitle = card.artist ?? card.appName {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        NowPlayingProgress(card: card, foreground: .white)
                        HStack {
                            NowPlayingSource(card: card, isStale: context.isStale)
                            Spacer(minLength: 8)
                            // The island is always black: draw the buttons as on a dark card.
                            NowPlayingControls(card: darkCard(card), palette: NowPlayingPalette(card: darkCard(card)), size: 38)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                }
            } compactLeading: {
                NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 24, palette: palette)
            } compactTrailing: {
                NowPlayingBars(isPlaying: playing, color: palette.accent)
                    .frame(width: 16, height: 14)
            } minimal: {
                NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 22, palette: palette)
            }
            .keylineTint(palette.accent)
        }
    }

    /// The system style draws in the Lock Screen's colors, which on the island's black would
    /// vanish in light mode.
    private func darkCard(_ card: NowPlayingCard) -> NowPlayingCard {
        var card = card
        if card.style == .system { card.style = .brand }
        return card
    }
}
