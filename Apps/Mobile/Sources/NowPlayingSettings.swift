import ActivityKit
import PDClientCore
import PDProtocol
import SwiftUI

/// Settings › Now Playing: the Live Activity, on or off, and how it looks. The preview shows
/// what the Mac is playing now when it can, and redraws as the settings change.
struct NowPlayingSettingsPage: View {
    let controller: SessionController
    @AppStorage(SettingsKey.defaultMac) private var defaultMacID = ""
    @AppStorage(SettingsKey.nowPlayingActivity) private var isEnabled = true
    @AppStorage(SettingsKey.nowPlayingDetailsInPushes) private var showsDetailsInPushes = true
    @AppStorage(SettingsKey.nowPlayingArtwork) private var showsArtwork = true
    @AppStorage(SettingsKey.nowPlayingSkipButtons) private var showsSkipButtons = true
    @AppStorage(SettingsKey.nowPlayingEndsWhenPaused) private var endsWhenPaused = false
    @AppStorage(SettingsKey.nowPlayingStyle) private var style = NowPlayingStyle.album
    @AppStorage(SettingsKey.nowPlayingStartsByPush) private var startsByPush = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var systemAllows = ActivityAuthorizationInfo().areActivitiesEnabled
    /// The live cover, decoded once per song.
    @State private var liveArtwork: (image: UIImage, tint: CardColor?)?
    /// The playing site's icon, when a browser is the player.
    @State private var siteIcon: (image: UIImage, tint: CardColor?)?

    private var playing: NowPlaying? { controller.store.macStatus?.nowPlaying }

    var body: some View {
        Form {
            Section {
                NowPlayingPreview(card: previewCard, artwork: previewArtwork, siteIcon: siteIcon?.image, isOn: isEnabled && systemAllows)
                    .listRowInsets(EdgeInsets())
            } footer: {
                Text(playing == nil ? "A preview. Play something on your Mac to see it here."
                                    : "Playing now on \(macName).")
            }
            .listRowBackground(Color.clear)

            if !systemAllows {
                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        HStack {
                            SettingsLabel("Allow Live Activities", symbol: "exclamationmark.triangle.fill", color: .orange)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                } footer: {
                    Text("Live Activities are off for PocketDesk in the Settings app.")
                }
            }

            Section {
                Toggle(isOn: $isEnabled) {
                    SettingsLabel("Lock Screen & Dynamic Island", symbol: "play.square.stack.fill", color: .red)
                }
            } footer: {
                Text("When your Mac plays music or video while PocketDesk is open, it stays on the Lock Screen and in the Dynamic Island, with buttons to play, pause and skip. It updates while PocketDesk is running and ends when playback stops or the Mac goes away.")
            }

            Section {
                Toggle(isOn: $startsByPush) {
                    SettingsLabel("Start When Music Plays", symbol: "bell.badge.fill", color: .orange)
                }
                Toggle("Show Details in Pushes", isOn: $showsDetailsInPushes)
                    .disabled(!startsByPush)
            } footer: {
                Text(showsDetailsInPushes
                     ? "Your Mac can start the card while PocketDesk is closed. Titles, artists and site names pass through the PocketDesk relay and Apple's push service, which can read them. Turn off Show Details in Pushes to keep them private."
                     : "Pushes show only Playing on your Mac, with no title, artist, site or artwork. PocketDesk restores the real details when it connects. The relay and Apple still receive the Mac name and playback state.")
                Text("Changes reach your Mac the next time PocketDesk connects.")
            }
            .disabled(!isEnabled)

            Section("Look") {
                Picker(selection: $style) {
                    ForEach(NowPlayingStyle.allCases, id: \.self) { Text($0.name).tag($0) }
                } label: {
                    SettingsLabel("Style", symbol: "paintpalette.fill", color: .purple)
                }
                Toggle(isOn: $showsArtwork) {
                    SettingsLabel("Album Art", symbol: "photo.fill", color: .blue)
                }
                Toggle(isOn: $showsSkipButtons) {
                    SettingsLabel("Skip Buttons", symbol: "forward.fill", color: .indigo)
                }
            }
            .disabled(!isEnabled)

            Section {
                Toggle(isOn: $endsWhenPaused) {
                    SettingsLabel("End When Paused", symbol: "pause.circle.fill", color: .gray)
                }
            } footer: {
                Text("Off keeps a paused song on the Lock Screen so you can carry on with one tap.")
            }
            .disabled(!isEnabled)
        }
        .settingsPage("Now Playing")
        .animation(.smooth, value: previewCard)
        .animation(.smooth, value: isEnabled)
        .onChange(of: isEnabled) { controller.nowPlayingPreferencesChanged() }
        .onChange(of: showsDetailsInPushes) { controller.nowPlayingPreferencesChanged() }
        .onChange(of: showsArtwork) { controller.nowPlayingPreferencesChanged() }
        .onChange(of: showsSkipButtons) { controller.nowPlayingPreferencesChanged() }
        .onChange(of: endsWhenPaused) { controller.nowPlayingPreferencesChanged() }
        .onChange(of: style) { controller.nowPlayingPreferencesChanged() }
        // The real thing in the preview while this page is up.
        .task(id: scenePhase) {
            systemAllows = ActivityAuthorizationInfo().areActivitiesEnabled
            guard scenePhase == .active else { return controller.stopWatchingStatus(watcher: "nowPlayingSettings") }
            controller.watchStatus(preferredHostID: UUID(uuidString: defaultMacID), watcher: "nowPlayingSettings")
        }
        .onDisappear { controller.stopWatchingStatus(watcher: "nowPlayingSettings") }
        .task(id: playing?.artwork) {
            guard let jpeg = playing?.artwork.flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: jpeg) else {
                liveArtwork = nil
                return
            }
            liveArtwork = (image, NowPlayingArtwork.averageColor(of: jpeg))
        }
        .task(id: playing?.site) {
            guard let site = playing?.site, let data = await FaviconLoader.shared.icon(for: "https://\(site)"),
                  let png = NowPlayingArtwork.icon(from: data), let image = UIImage(data: png) else {
                siteIcon = nil
                return
            }
            siteIcon = (image, NowPlayingArtwork.averageColor(of: png))
        }
    }

    private var macName: String {
        controller.shortcutTarget(preferredHostID: UUID(uuidString: defaultMacID))?.name ?? "your Mac"
    }

    private var previewCard: NowPlayingCard {
        let hasLiveArtwork = liveArtwork != nil && playing?.artwork != nil
        return NowPlayingCard(title: playing?.title ?? "Midnight City",
                              artist: playing == nil ? "M83" : playing?.artist,
                              appName: playing == nil ? "Music" : playing?.app?.name,
                              macName: macName,
                              isPlaying: playing?.isPlaying ?? true,
                              artworkID: showsArtwork ? "preview" : nil,
                              tint: hasLiveArtwork ? liveArtwork?.tint
                                  : siteIcon?.tint ?? CardColor(red: 0.55, green: 0.3, blue: 0.85),
                              style: style, showsSkipButtons: showsSkipButtons,
                              site: playing?.site.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 },
                              startedAt: playing?.startedAt, duration: playing?.duration, pausedElapsed: playing?.pausedElapsed)
    }

    private var previewArtwork: UIImage? {
        guard showsArtwork, playing?.artwork != nil else { return nil }
        return liveArtwork?.image
    }
}

extension NowPlayingStyle {
    var name: String {
        switch self {
        case .album: "Album Colors"
        case .brand: "PocketDesk Blue"
        case .system: "Classic"
        }
    }
}

/// A small Lock Screen: the Dynamic Island's compact look at the top, the clock, and the card.
private struct NowPlayingPreview: View {
    let card: NowPlayingCard
    let artwork: UIImage?
    var siteIcon: UIImage?
    let isOn: Bool

    private var palette: NowPlayingPalette { NowPlayingPalette(card: card) }

    var body: some View {
        VStack(spacing: 0) {
            island
                .padding(.top, 12)
            VStack(spacing: 0) {
                Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.subheadline.weight(.semibold))
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.top, 14)
            Spacer(minLength: 18)
            NowPlayingLockScreenView(card: card, artwork: artwork, siteIcon: siteIcon)
                .background {
                    // The system style sits on the Lock Screen's own frosted glass.
                    if card.style == .system { Rectangle().fill(.regularMaterial) }
                }
                .clipShape(.rect(cornerRadius: 22, style: .continuous))
                .environment(\.colorScheme, card.style == .system ? .light : .dark)
                .allowsHitTesting(false)
                .opacity(isOn ? 1 : 0.35)
                .overlay {
                    if !isOn {
                        Label("Off", systemImage: "eye.slash.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.5), in: .capsule)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
        .background {
            LinearGradient(colors: [Color(red: 0.18, green: 0.2, blue: 0.42), Color(red: 0.42, green: 0.22, blue: 0.5),
                                    Color(red: 0.08, green: 0.08, blue: 0.16)],
                           startPoint: .topLeading, endPoint: .bottom)
        }
        .clipShape(.rect(cornerRadius: Brand.cornerRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOn ? "Preview: \(card.title) on the Lock Screen" : "Off")
    }

    /// The compact presentation: cover on the left, level bars on the right.
    private var island: some View {
        HStack {
            NowPlayingArtworkView(image: artwork, siteIcon: siteIcon, size: 22, palette: palette)
            Spacer()
            NowPlayingBars(isPlaying: card.isPlaying, color: palette.accent)
                .frame(width: 16, height: 14)
        }
        .padding(.horizontal, 8)
        .frame(width: isOn ? 168 : 120, height: 36)
        .background(.black, in: .capsule)
        .overlay {
            if !isOn { Capsule().fill(.black) }
        }
    }
}
