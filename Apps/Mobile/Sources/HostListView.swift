import PDClientCore
import SwiftUI

/// Home: your Macs as big cards (connect in one tap), then Macs nearby that can be paired.
struct HostListView: View {
    let controller: SessionController
    let hosts: [DiscoveredHost]
    @State private var showingLinkEntry = false

    private var paired: [DiscoveredHost] { hosts.filter(\.isPaired) }
    private var nearby: [DiscoveredHost] { hosts.filter { !$0.isPaired } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if hosts.isEmpty {
                        SearchingCard()
                    }
                    if !paired.isEmpty {
                        section("Your Macs") {
                            ForEach(paired) { host in
                                PairedMacCard(host: host) {
                                    if host.isOnline { controller.select(host) } else { controller.wake(host) }
                                }
                                    .contextMenu {
                                        Button("Forget This Mac", systemImage: "trash", role: .destructive) {
                                            controller.forget(host)
                                        }
                                    }
                            }
                        }
                    }
                    if !nearby.isEmpty {
                        section("Nearby") {
                            ForEach(nearby) { host in
                                NearbyMacRow(host: host) { controller.select(host) }
                            }
                        }
                    }
                    SetupHint()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .animation(.smooth, value: hosts)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background { AppBackground() }
            .navigationTitle("PocketDesk")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Pair with Link", systemImage: "link") { showingLinkEntry = true }
                }
            }
            .sheet(isPresented: $showingLinkEntry) {
                PairWithLinkSheet(controller: controller) { showingLinkEntry = false }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)
            content()
        }
    }
}

private struct PairedMacCard: View {
    let host: DiscoveredHost
    let connect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                MacGlyph(kind: host.kind, size: 56, status: host.glyphStatus)
                VStack(alignment: .leading, spacing: 6) {
                    Text(host.name).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(status.text)
                        .font(.subheadline)
                        .foregroundStyle(status.color)
                }
                Spacer(minLength: 0)
            }
            Button(action: connect) {
                HStack(spacing: 8) {
                    if host.isWaking { ProgressView().tint(.white) }
                    Label(action.title, systemImage: action.symbol)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Brand.accent)
            .disabled(!host.isOnline && (!host.canWake || host.isWaking))
            if !host.isOnline && !host.canWake {
                Text("Open PocketDesk on this Mac. Once you've connected while it's awake, you can wake it from here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private var status: (text: String, color: Color) {
        if host.isOnline { ("Online", .secondary) }
        else if host.isWaking { ("Waking…", .orange) }
        else if host.canWake { ("Asleep", .secondary) }
        else { ("Offline", .secondary) }
    }

    private var action: (title: String, symbol: String) {
        if host.isOnline { ("Use This Mac", "play.fill") }
        else if host.isWaking { ("Waking…", "power") }
        else if host.canWake { ("Wake & Use", "power") }
        else { ("Not Available", "moon.zzz") }
    }
}

private struct NearbyMacRow: View {
    let host: DiscoveredHost
    let pair: () -> Void

    var body: some View {
        Button(action: pair) {
            HStack(spacing: 14) {
                MacGlyph(kind: host.kind, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text("Ready to pair").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("Pair")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassEffect(.regular.tint(Brand.accent.opacity(0.25)), in: .capsule)
            }
        }
        .buttonStyle(.plain)
        .card(interactive: true)
    }
}

/// Shown until the first Mac appears.
private struct SearchingCard: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Brand.accent)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
            Text("Looking for your Mac").font(.title3.weight(.semibold))
            Text("Make sure PocketDesk is open on your Mac and both are on the same Wi-Fi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .card()
    }
}

private struct SetupHint: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "menubar.arrow.up.rectangle")
                .font(.title3)
                .foregroundStyle(Brand.accent)
            Text("New Mac? Open PocketDesk from its menu bar icon and choose **Pair a Phone…**")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}
