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
            // The island is always black: draw the buttons as on a dark card.
            let dark = NowPlayingPalette(card: darkCard(card))
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 54, palette: palette)
                        .padding(.leading, 4)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NowPlayingPlayButton(card: darkCard(card), palette: dark, size: 42)
                        .padding(.trailing, 4)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.center) {
                    NowPlayingHeadline(card: card, palette: palette, isStale: context.isStale)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    NowPlayingTransport(card: darkCard(card), palette: dark, isStale: context.isStale, skipSize: 32)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.top, 8)
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
