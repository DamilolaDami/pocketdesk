import CoreImage.CIFilterBuiltins
import PDHostCore
import PDSecurity
import SwiftUI

/// Shows a one-time pairing QR code while open; closing it withdraws the invite.
struct PairingWindow: View {
    static let id = "pair"

    let controller: HostController
    @State private var invite: PairingInvite?

    var body: some View {
        VStack(spacing: 16) {
            if let approval = controller.store.state.pendingApprovals.first {
                ApprovalCard(approval: approval) { accepted in
                    Task { await controller.resolveApproval(approval.id, accepted: accepted) }
                }
            } else if let invite = controller.store.state.invite {
                Text("Scan with PocketDesk on your phone").font(.headline)
                if let image = Self.qrCode(for: invite.url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(.white, in: .rect(cornerRadius: 12))
                }
                Text("This code works once and expires in 5 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Copy Pairing Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                }
            } else if invite != nil {
                // The invite was used (or expired) while the window was open.
                Label("Phone paired", systemImage: "checkmark.circle.fill").font(.headline)
                Button("Pair Another") { Task { invite = await controller.openInvite() } }
            } else {
                ProgressView()
            }
        }
        .padding(24)
        .frame(width: 320)
        .task { invite = await controller.openInvite() }
        .onDisappear { Task { await controller.closeInvite() } }
    }

    private static func qrCode(for string: String) -> NSImage? {
        let filter: any CIFilter & CIQRCodeGenerator = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
