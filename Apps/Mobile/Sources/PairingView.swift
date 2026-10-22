import PDClientCore
import SwiftUI
import VisionKit

/// Pairing with one Mac: scan its QR code (or paste the link), then confirm the code matches.
struct PairingView: View {
    let controller: SessionController
    let host: DiscoveredHost
    let code: String?

    var body: some View {
        Group {
            if let code {
                VStack(spacing: 20) {
                    Image(systemName: "checkmark.shield").font(.system(size: 48)).foregroundStyle(.tint)
                    Text("Confirm on your Mac").font(.title2.bold())
                    Text(code.prefix(3) + " " + code.dropFirst(3))
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                    Text("Check that \(host.name) shows the same code, then click Accept there.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    ProgressView()
                }
                .padding(32)
            } else {
                VStack(spacing: 16) {
                    if QRScanner.isAvailable {
                        QRScanner { url in try? controller.pair(using: url) }
                            .clipShape(.rect(cornerRadius: 20))
                            .frame(maxHeight: 360)
                        Text("Point your camera at the code in PocketDesk on \(host.name).")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 56)).foregroundStyle(.secondary)
                        Text("On \(host.name), choose “Pair a Phone…” and click “Copy Pairing Link”, then paste it here.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    PairingLinkEntry(controller: controller)
                }
                .padding()
            }
        }
        .navigationTitle("Pair with \(host.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Cancel", role: .cancel) { controller.disconnect() }
        }
    }
}

/// Paste or type a `pocketdesk://pair?…` link (the simulator has no camera).
struct PairingLinkEntry: View {
    let controller: SessionController
    var onPaired: () -> Void = {}
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            PasteButton(payloadType: String.self) { strings in
                if let first = strings.first { submit(first) }
            }
            .buttonBorderShape(.capsule)
            HStack {
                TextField("pocketdesk://pair?…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { submit(link) }
                Button("Pair") { submit(link) }.disabled(link.isEmpty)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func submit(_ text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            error = "That isn't a pairing link."
            return
        }
        do {
            try controller.pair(using: url)
            error = nil
            onPaired()
        } catch {
            self.error = "That isn't a PocketDesk pairing link."
        }
    }
}

/// Live QR scanning with VisionKit. Reports the first `pocketdesk://` link it sees.
struct QRScanner: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    @MainActor static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (URL) -> Void
        private var reported = false

        init(onFound: @escaping (URL) -> Void) { self.onFound = onFound }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in items {
                guard !reported, let value = barcode.payloadStringValue, let url = URL(string: value),
                      url.scheme == "pocketdesk" else { continue }
                reported = true
                scanner.stopScanning()
                onFound(url)
            }
        }
    }
}
