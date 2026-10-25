import PDClientCore
import SwiftUI

/// Setup uses the same backdrop, cards and nearby rows as Macs. Pairing stays in PairingView.
struct PhoneSetupView: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    @Binding var flow: PhoneOnboarding
    let finish: () -> Void
    @State private var showingLink = false

    private var nearby: [DiscoveredHost] { hosts.filter { !$0.isPaired } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    heading
                    page
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
            }
            .id(flow.step)
            .scrollBounceBehavior(.basedOnSize)
            .background { AppBackground() }
            .safeAreaInset(edge: .bottom) { actions }
            .navigationTitle("Set Up PocketDesk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if flow.step.previous != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left") { flow.back() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Skip", action: finish) }
            }
            .sheet(isPresented: $showingLink) {
                PairWithLinkSheet(controller: controller) { showingLink = false }
            }
        }
    }

    private var heading: some View {
        VStack(spacing: 16) {
            if flow.step == .welcome {
                Image("AppIconArtwork")
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                MacGlyph(size: 88)
            }
            VStack(spacing: 8) {
                Text(title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            Text("Step \(flow.step.rawValue + 1) of \(PhoneOnboarding.Step.allCases.count)")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var page: some View {
        switch flow.step {
        case .welcome:
            VStack(alignment: .leading, spacing: 20) {
                SetupInstruction(symbol: "laptopcomputer", title: "PocketDesk on both devices",
                                 text: "The Mac app shares its screen. This app puts it within reach.")
                SetupInstruction(symbol: "wifi", title: "Start on the same Wi-Fi",
                                 text: "Keep your Mac awake while you set up. Remote Access can come later.")
                SetupInstruction(symbol: "lock.shield", title: "Pair once, privately",
                                 text: "You approve this iPhone on your Mac. No account needed.")
            }
            .card()
        case .mac:
            VStack(alignment: .leading, spacing: 20) {
                SetupInstruction(symbol: "arrow.down.app", title: "Install the Mac app",
                                 text: "On your Mac, download PocketDesk, move it to Applications and open it. Requires macOS 26 or later.")
                ShareLink(item: AppInfo.macDownload) {
                    Label("Send Mac Download Link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                Divider()
                SetupInstruction(symbol: "checkmark.shield", title: "Follow the Mac’s setup",
                                 text: "Allow Screen Recording and Accessibility when PocketDesk asks. Those let your iPhone see the screen, click and type.")
                SetupInstruction(symbol: "menubar.arrow.up.rectangle", title: "Leave PocketDesk open",
                                 text: "Look for its iPhone icon in your Mac’s menu bar.")
            }
            .card()
        case .find:
            SetupInstruction(symbol: "qrcode", title: "On your Mac, choose Pair a Phone…",
                             text: "Open PocketDesk from the menu bar. Tap your Mac below, then scan the code it shows and confirm the same six digits on both devices.")
                .card()
            if nearby.isEmpty {
                if hosts.contains(where: \.isPaired) {
                    VStack(spacing: 12) {
                        Label("You already have a paired Mac", systemImage: "checkmark.circle.fill")
                            .font(.headline).foregroundStyle(Brand.accent)
                        Text("Continue to Macs to choose it, or pair another Mac with a link.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Continue to Macs", action: finish).buttonStyle(.glassProminent)
                    }.frame(maxWidth: .infinity).card()
                } else {
                    SearchingCard { showingLink = true }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nearby").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(nearby) { host in
                        NearbyMacRow(host: host) { controller.select(host) }
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            if flow.step == .find {
                Button("Pair with Link", systemImage: "link") { showingLink = true }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            } else {
                Button {
                    flow.advance()
                    if flow.step == .find { controller.startDiscovery() }
                } label: {
                    Text(flow.step == .welcome ? "Get Started" : "Find My Mac")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Brand.accent)
                if flow.step == .welcome {
                    Button("My Mac Is Already Ready") {
                        flow.findMac()
                        controller.startDiscovery()
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.vertical, 4)
                }
            }
        }
        .controlSize(.large)
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var title: String {
        switch flow.step {
        case .welcome: "Your Mac, in your pocket"
        case .mac: "Get your Mac ready"
        case .find: "Find your Mac"
        }
    }

    private var subtitle: String {
        switch flow.step {
        case .welcome: "Let’s connect this iPhone to your Mac. A few minutes here, then you’re ready to use it from the sofa."
        case .mac: "A quick setup on your Mac gives this iPhone permission to use it."
        case .find: "Keep both devices on the same Wi-Fi. Allow Local Network access so PocketDesk can find your Mac."
        }
    }
}

private struct SetupInstruction: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Brand.accent).frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Also available from Settings, so these instructions never have to interrupt a later session.
struct ControlsGuideView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 10) {
                    Image(systemName: "hand.tap").font(.system(size: 44, weight: .light)).foregroundStyle(Brand.accent)
                        .accessibilityHidden(true)
                    Text("Make yourself at home").font(.title2.weight(.bold))
                    Text("A few familiar gestures, with your Mac on the other end.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
                SetupInstruction(symbol: "hand.tap", title: "Tap to click",
                                 text: "In Touch Mode, tap what you want on the Mac’s screen. Hold to right-click, or drag to move things.").card()
                SetupInstruction(symbol: "hand.draw", title: "Two fingers to scroll",
                                 text: "Scroll with two fingers. Pinch to zoom when you want a closer look.").card()
                SetupInstruction(symbol: "keyboard", title: "Your keyboard is one tap away",
                                 text: "Tap Keyboard in the floating controls to type. Escape, Command and the other Mac keys sit above the keyboard.").card()
                Text("Prefer a trackpad? Switch modes in the floating controls. More has displays, files and Disconnect.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            .frame(maxWidth: 520).frame(maxWidth: .infinity)
            .padding(.horizontal, 20).padding(.bottom, 24)
        }
        .background { AppBackground() }
        .navigationTitle("Using Your Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}
