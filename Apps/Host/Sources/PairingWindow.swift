import CoreImage.CIFilterBuiltins
import PDHostCore
import PDSecurity
import SwiftUI

/// Shows a one-time pairing QR code while open; closing it withdraws the invite.
struct PairingWindow: View {
    static let id = "pair"
    private static let inviteLifetime: TimeInterval = 300

    let controller: HostController
    /// Inside the welcome window, which has its own padding.
    var compact = false
    @State private var opened = false
    @State private var openedAt = Date.now
    @State private var copied = false

    private var state: HostState { controller.store.state }

    var body: some View {
        VStack(spacing: 20) {
            if let approval = state.pendingApprovals.first {
                ApprovalCard(approval: approval) { accepted in
                    Task { await controller.resolveApproval(approval.id, accepted: accepted) }
                }
                .transition(.blurReplace)
            } else if let invite = state.invite {
                inviteView(invite).transition(.blurReplace)
            } else if opened {
                pairedView.transition(.blurReplace)
            } else {
                ProgressView().frame(height: 300)
            }
        }
        .padding(compact ? 8 : 28)
        .frame(width: 420)
        .animation(.smooth, value: state.invite?.token)
        .animation(.smooth, value: state.pendingApprovals.first?.id)
        .task { await openInvite() }
        .onDisappear { Task { await controller.closeInvite() } }
    }

    private func inviteView(_ invite: PairingInvite) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                if !compact { AppGlyph(size: 56) }
                Text("Pair your iPhone").font(.title2.weight(.bold))
                Text("Open PocketDesk on your iPhone, tap this Mac, then scan the code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let image = Self.qrCode(for: invite.url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(.white, in: .rect(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            }

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Self.inviteLifetime - context.date.timeIntervalSince(openedAt))
                VStack(spacing: 6) {
                    ProgressView(value: remaining, total: Self.inviteLifetime)
                        .tint(remaining < 60 ? .orange : HostBrand.accent)
                        .frame(width: 220)
                    Text(remaining > 0
                         ? "Works once · expires in \(Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)))"
                         : "Expired")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy Pairing Link", systemImage: copied ? "checkmark" : "link")
                }
                .buttonStyle(.glass)
                Button("New Code", systemImage: "arrow.clockwise") { Task { await openInvite() } }
                    .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
    }

    private var pairedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("iPhone paired").font(.title2.weight(.bold))
            Text("It can connect to this Mac any time PocketDesk is running.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Pair Another Phone") { Task { await openInvite() } }
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .frame(height: 300)
    }

    private func openInvite() async {
        _ = await controller.openInvite()
        openedAt = .now
        copied = false
        opened = true
    }

    private static func qrCode(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
