import PDClientCore
import PDProtocol
import SwiftUI

struct ConnectingView: View {
    let hostName: String
    var kind: MacKind?
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            MacGlyph(kind: kind, size: 96, status: .waking)
            VStack(spacing: 8) {
                Text("Connecting").font(.title2.weight(.bold))
                Text(hostName).font(.headline).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: cancel)
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .background { AppBackground() }
    }
}

struct FailedView: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void
    let back: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.orange.gradient)
                .symbolEffect(.bounce, options: .nonRepeating)
            VStack(spacing: 10) {
                Text(title).font(.title2.weight(.bold))
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .card()
            .padding(.horizontal, 20)
            Spacer()
            VStack(spacing: 12) {
                if canRetry {
                    Button(action: retry) {
                        Text("Try Again").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.accent)
                }
                Button(action: back) {
                    Text("Back to Macs").frame(maxWidth: .infinity).padding(.vertical, 4)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background { AppBackground() }
    }

    private var isPermissionProblem: Bool { message.localizedCaseInsensitiveContains("permission") }

    private var title: String {
        if isPermissionProblem { return "Your Mac needs a permission" }
        if message.localizedCaseInsensitiveContains("declined") { return "Pairing declined" }
        if message.localizedCaseInsensitiveContains("Update PocketDesk") { return "Update needed" }
        return "Connection lost"
    }

    private var symbol: String {
        if isPermissionProblem { return "lock.trianglebadge.exclamationmark.fill" }
        if message.localizedCaseInsensitiveContains("declined") { return "hand.raised.fill" }
        if message.localizedCaseInsensitiveContains("Update PocketDesk") { return "arrow.down.circle.fill" }
        return "wifi.exclamationmark"
    }
}
