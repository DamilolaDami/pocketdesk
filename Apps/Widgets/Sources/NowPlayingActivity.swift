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
                    NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 48, palette: palette)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    NowPlayingHeadline(card: card, palette: palette, isStale: context.isStale)
                        .padding(.leading, 4)
                        .padding(.trailing, 4)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // The island is always black: draw in white whatever the card's style.
                    VStack(spacing: 8) {
                        NowPlayingProgress(card: card, foreground: .white)
                        NowPlayingControls(card: card, scale: 0.9)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
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
}
