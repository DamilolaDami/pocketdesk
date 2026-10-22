import PDClientCore
import SwiftUI
import VisionKit

/// Pairing with one Mac: scan its QR code (or paste the link), then confirm the code matches.
struct PairingView: View {
    let controller: SessionController
    let host: DiscoveredHost
    let code: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                StepIndicator(current: code == nil ? 1 : 2)
                if let code {
                    ConfirmCode(code: code, hostName: host.name)
                        .transition(.blurReplace)
                } else {
                    ScanOrPaste(controller: controller, hostName: host.name)
                        .transition(.blurReplace)
                }
            }
            .padding(20)
            .animation(.smooth, value: code)
        }
        .background { AppBackground() }
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") { controller.disconnect() }
            }
        }
    }
}

private struct StepIndicator: View {
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            step(1, "Scan")
            Capsule().fill(current > 1 ? Brand.accent : Color.secondary.opacity(0.3)).frame(width: 36, height: 3)
            step(2, "Confirm")
        }
        .font(.footnote.weight(.semibold))
    }

    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .frame(width: 22, height: 22)
                .background(Circle().fill(number <= current ? Brand.accent : Color.secondary.opacity(0.25)))
                .foregroundStyle(number <= current ? .white : .secondary)
            Text(title).foregroundStyle(number <= current ? .primary : .secondary)
        }
    }
}

private struct ScanOrPaste: View {
    let controller: SessionController
    let hostName: String

    var body: some View {
        VStack(spacing: 20) {
            if QRScanner.isAvailable {
                QRScanner { url in try? controller.pair(using: url) }
                    .frame(height: 340)
                    .clipShape(.rect(cornerRadius: Brand.cornerRadius))
                    .overlay { ViewfinderCorners().padding(40) }
                Text("Point your camera at the code shown on **\(hostName)**.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(Brand.accent)
                        .symbolEffect(.breathe, options: .repeating)
                    Text("Pair with a link").font(.title3.weight(.semibold))
                    Text("On **\(hostName)**, open PocketDesk → **Pair a Phone…** → **Copy Pairing Link**, then paste it here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .card()
            }
            PairingLinkEntry(controller: controller)
                .card()
        }
    }
}

private struct ViewfinderCorners: View {
    var body: some View {
        GeometryReader { geometry in
            let length: CGFloat = 34
            let rect = CGRect(origin: .zero, size: geometry.size)
            Path { path in
                for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                         (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                         (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                         (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
                    path.move(to: CGPoint(x: corner.x + dx * length, y: corner.y))
                    path.addLine(to: corner)
                    path.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * length))
                }
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
    }
}

/// Step 2: both screens show the same six digits; the person at the Mac accepts.
private struct ConfirmCode: View {
    let code: String
    let hostName: String

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 50))
                .foregroundStyle(Brand.accent.gradient)
                .symbolEffect(.breathe, options: .repeating)
            VStack(spacing: 6) {
                Text("Confirm on your Mac").font(.title2.weight(.bold))
                Text("Check **\(hostName)** shows the same code, then click **Accept** there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(Array(code.enumerated()), id: \.offset) { index, digit in
                        Text(String(digit))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 46, height: 60)
                            .glassEffect(.regular, in: .rect(cornerRadius: 14))
                            .padding(.leading, index == 3 ? 10 : 0)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for your Mac…").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }
}

/// Paste or type a `pocketdesk://pair?…` link (the simulator has no camera).
struct PairingLinkEntry: View {
    let controller: SessionController
    var onPaired: () -> Void = {}
    @State private var link = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            PasteButton(payloadType: String.self) { strings in
                if let first = strings.first { submit(first) }
            }
            .buttonBorderShape(.capsule)
            .tint(Brand.accent)
            HStack(spacing: 10) {
                TextField("pocketdesk://pair?…", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { submit(link) }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(.background.secondary, in: .capsule)
                Button("Pair") { submit(link) }
                    .buttonStyle(.glassProminent)
                    .tint(Brand.accent)
                    .disabled(link.isEmpty)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
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

struct PairWithLinkSheet: View {
    let controller: SessionController
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Paste the link from **Copy Pairing Link** in PocketDesk on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                PairingLinkEntry(controller: controller, onPaired: dismiss)
            }
            .padding(24)
            .navigationTitle("Pair with Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: dismiss)
                }
            }
        }
        .presentationDetents([.height(280)])
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
