import PDProtocol
import SwiftUI

/// Settings › How It's Built: what happens between the iPhone and the Mac, in plain words,
/// with the real numbers. Everything here is in the open-source code.
struct HowItsBuiltView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Header()
                ForEach(BuildTopic.all) { topic in
                    TopicCard(topic: topic)
                }
                Links()
                Text("Protocol version \(protocolVersion) · \(version)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background { AppBackground() }
        .navigationTitle("How It's Built")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var version: String {
        "Version " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
    }
}

// MARK: - Header

private struct Header: View {
    var body: some View {
        VStack(spacing: 18) {
            Flow()
            VStack(spacing: 6) {
                Text("Your iPhone talks straight to your Mac")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Two native apps sharing one Swift package. No servers, no accounts, nothing in between: the picture, sound and your touches go directly over your own network, encrypted end to end.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            FactChips(facts: ["QUIC", "TLS 1.3", "HEVC", "60 fps", "Pinned keys", "Open source"])
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Brand.cornerRadius))
    }
}

/// iPhone ⇄ Mac, with what goes each way.
private struct Flow: View {
    var body: some View {
        HStack(spacing: 10) {
            device("iphone", "iPhone")
            VStack(spacing: 8) {
                lane("Touches, keys, files", systemImage: "arrow.right")
                lane("Picture, sound, status", systemImage: "arrow.left")
            }
            .frame(maxWidth: .infinity)
            device("macbook", "Mac")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your iPhone sends touches, keys and files to your Mac; the Mac sends back its picture, sound and status.")
    }

    private func device(_ symbol: String, _ name: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Brand.accent)
                .frame(width: 58, height: 58)
                .background(Brand.accent.opacity(0.12), in: .rect(cornerRadius: 16, style: .continuous))
            Text(name).font(.caption.weight(.semibold))
        }
    }

    private func lane(_ text: String, systemImage: String) -> some View {
        VStack(spacing: 2) {
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 0) {
                if systemImage == "arrow.left" { Image(systemName: "chevron.left").font(.caption2.weight(.bold)) }
                Rectangle().frame(height: 1.5)
                if systemImage == "arrow.right" { Image(systemName: "chevron.right").font(.caption2.weight(.bold)) }
            }
            .foregroundStyle(Brand.accent.opacity(0.7))
        }
    }
}

private struct FactChips: View {
    let facts: [String]

    var body: some View {
        // Wraps like text so it fits any width.
        FlowLayout(spacing: 6) {
            ForEach(facts, id: \.self) { fact in
                Text(fact)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Brand.accent.opacity(0.12), in: .capsule)
                    .foregroundStyle(Brand.accent)
            }
        }
    }
}

// MARK: - Topics

private struct BuildTopic: Identifiable {
    struct Fact: Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    let title: String
    let symbol: String
    let color: Color
    let summary: String
    let facts: [Fact]
    var id: String { title }

    static let all: [BuildTopic] = [
        BuildTopic(
            title: "The Connection", symbol: "point.3.connected.trianglepath.dotted", color: .blue,
            summary: "One QUIC connection, built on Apple's newest Network framework, with separate lanes so nothing waits behind anything else.",
            facts: [
                Fact(title: "Finding your Mac", detail: "Your Mac announces itself on the local network with Bonjour. The iPhone sees it appear and disappear, and knows its kind, name and version."),
                Fact(title: "Control lane", detail: "A reliable stream for everything that must arrive in order: keys, shortcuts, menus, the clipboard, file requests."),
                Fact(title: "Touch lane", detail: "Pointer moves go as tiny datagrams (11 bytes or less). A lost one is simply replaced by the next, so a busy network never makes the pointer lag behind your finger."),
                Fact(title: "Picture and sound lanes", detail: "Video and audio each get their own one-way stream, so a large frame can't hold up the sound, and neither holds up your typing."),
                Fact(title: "Files lane", detail: "File data never shares the control lane. It travels in 256 KB pieces with at most 4 MB in flight, and a cut-off transfer picks up where it stopped."),
            ]),
        BuildTopic(
            title: "Security & Pairing", symbol: "lock.shield.fill", color: .green,
            summary: "The code is public, so security rests on keys, not secrets. Only the phones you approve can ever connect.",
            facts: [
                Fact(title: "Keys that never leave the device", detail: "Your iPhone and your Mac each create their own P-256 key inside the Keychain, with a certificate over it. Its SHA-256 fingerprint is the device's identity."),
                Fact(title: "Pairing", detail: "The Mac shows a QR code holding its fingerprint and a 128-bit one-time token that expires after 5 minutes. Both screens then show the same 6-digit code, and you accept on the Mac. Each code works once."),
                Fact(title: "Every connection", detail: "TLS 1.3 with both sides proving who they are. Each side accepts only the exact key it pinned at pairing, so an impostor Mac or phone is refused before anything is sent."),
                Fact(title: "Locked Macs", detail: "Any Mac can be locked behind Face ID or your passcode, on this iPhone, before it can be opened, sent files or pasted to."),
                Fact(title: "You stay in charge", detail: "The Mac can ask before each connection, shows when a phone is connected, and can forget a phone at any time."),
            ]),
        BuildTopic(
            title: "The Picture", symbol: "play.rectangle.fill", color: .purple,
            summary: "The Mac's own hardware encodes the screen; your iPhone's hardware decodes it. The aim is under 60 ms from the Mac's screen to yours.",
            facts: [
                Fact(title: "Capture", detail: "ScreenCaptureKit grabs a display or a single window, sized to fit your iPhone and never upscaled. A still screen sends nothing at all."),
                Fact(title: "Encode", detail: "Hardware HEVC through VideoToolbox, tuned for low latency: real time, no frame reordering, and a fresh keyframe whenever one is needed."),
                Fact(title: "Never stale", detail: "At most two frames are in flight. If the network can't keep up, new frames are skipped before encoding, so what you see is always the latest, never a backlog."),
                Fact(title: "Adapts as you move", detail: "Every half second the Mac checks how the link is doing and steps the bitrate, then frame rate, then size down, and back up once it's calm."),
                Fact(title: "Quality modes", detail: "Best streams 1.5× your screen's pixels at 60 fps for crisp zooming. Balanced matches your screen. Battery Saver uses 0.75× at 30 fps, and turns on by itself in Low Power Mode."),
                Fact(title: "Display", detail: "Frames go straight to the system's video layer, decoded in hardware and in step with the screen's refresh."),
            ]),
        BuildTopic(
            title: "Sound", symbol: "speaker.wave.2.fill", color: .pink,
            summary: "The Mac's audio arrives in sync with the picture.",
            facts: [
                Fact(title: "Capture and encode", detail: "48 kHz stereo from ScreenCaptureKit, compressed to 128 kbps AAC on the Mac. Your microphone and PocketDesk's own sounds are never captured."),
                Fact(title: "In sync", detail: "Sound and picture share one clock on the iPhone, so lips match voices."),
            ]),
        BuildTopic(
            title: "Touch & Keyboard", symbol: "hand.point.up.left.fill", color: .orange,
            summary: "Your fingers become a mouse, a trackpad and a keyboard on the Mac.",
            facts: [
                Fact(title: "Touch mode", detail: "Tap to click, long-press to right-click, drag to drag, and two fingers to scroll, exactly where you touch."),
                Fact(title: "Trackpad mode", detail: "An accelerated pointer like a real trackpad, with the view following it as you zoom. Three-finger swipes switch spaces and open Mission Control."),
                Fact(title: "On the Mac", detail: "Clicks and keys are posted as real system events, mapped to the display or window you're viewing."),
                Fact(title: "Keys never get stuck", detail: "Key presses travel on the reliable lane: a lost key-up would leave ⌘ held down."),
            ]),
        BuildTopic(
            title: "Your Mac, Native", symbol: "macwindow.on.rectangle", color: .indigo,
            summary: "More than a mirror: parts of the Mac become native iPhone controls.",
            facts: [
                Fact(title: "Menus", detail: "The front app's menu bar is read through the Accessibility API, without opening anything on the Mac, and shown as native menus. Choosing an item chooses it on the Mac."),
                Fact(title: "Now playing", detail: "What's playing, its cover and the app playing it come from the same source as the Mac's Control Center, with the battery and volume alongside."),
                Fact(title: "No stream needed", detail: "Shortcuts, Paste, Copy, files and the Mac cards use short connections with no picture at all, so they're quick and light."),
                Fact(title: "Wake from sleep", detail: "The Mac shares its network address inside the encrypted session, so the iPhone can wake it later with Wake-on-LAN magic packets."),
            ]),
        BuildTopic(
            title: "Made With", symbol: "hammer.fill", color: .gray,
            summary: "Modern Swift from top to bottom, built in the open.",
            facts: [
                Fact(title: "Swift 6", detail: "Strict concurrency throughout: every side effect lives in an actor, and the compiler checks there are no data races."),
                Fact(title: "SwiftUI and Liquid Glass", detail: "Native interfaces on iOS 26 and macOS 26, using Apple's newest design language."),
                Fact(title: "One dependency", detail: "Apple's open-source swift-certificates, used only to make each device's certificate. Everything else is Apple's own frameworks."),
                Fact(title: "Tested", detail: "Around 180 automated tests, including real encrypted connections, run on every change."),
                Fact(title: "Open source", detail: "Apache 2.0 licensed. Anyone can read exactly what PocketDesk does with their Mac."),
            ]),
    ]
}

private struct TopicCard: View {
    let topic: BuildTopic
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.smooth) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: topic.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(topic.color.gradient, in: .rect(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(topic.title).font(.headline)
                        Text(topic.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .padding(.top, 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the details." : "Shows the details.")

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(topic.facts) { fact in
                        HStack(alignment: .top, spacing: 12) {
                            Circle()
                                .fill(topic.color)
                                .frame(width: 6, height: 6)
                                .padding(.top, 7)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(fact.title).font(.subheadline.weight(.semibold))
                                Text(fact.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.leading, 54)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card()
    }
}

private struct Links: View {
    private static let repo = "https://github.com/DamilolaDami/pocketdesk"

    var body: some View {
        VStack(spacing: 0) {
            link("Source Code", symbol: "chevron.left.forwardslash.chevron.right", url: Self.repo)
            Divider().padding(.leading, 52)
            link("Full Architecture Notes", symbol: "doc.text.fill", url: Self.repo + "/blob/main/docs/ARCHITECTURE.md")
            Divider().padding(.leading, 52)
            link("Security Policy", symbol: "checkmark.shield.fill", url: Self.repo + "/blob/main/SECURITY.md")
        }
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: Brand.cornerRadius))
    }

    private func link(_ title: String, symbol: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 24)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
    }
}
