import PDClientCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "PocketDesk" in the share sheet: sends what's shared to a Mac's Downloads folder.
final class ShareViewController: UIViewController {
    private let controller = SessionController()

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let shareView = ShareView(controller: controller, providers: providers) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: shareView)
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

private struct ShareView: View {
    let controller: SessionController
    let providers: [NSItemProvider]
    let done: () -> Void
    let cancel: () -> Void
    @State private var files: [OutgoingFile]?
    @State private var chosen: UUID?
    @State private var sending = false
    @State private var problem: String?

    private var macs: [DiscoveredHost] {
        guard case .discovering(let hosts) = controller.store.state else { return [] }
        return hosts.filter { $0.isPaired && $0.isOnline && $0.needsUpdate == nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if macs.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for your Macs…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(macs) { mac in
                        Button {
                            chosen = mac.hostID
                        } label: {
                            HStack {
                                Image(systemName: "laptopcomputer")
                                Text(mac.name).foregroundStyle(.primary)
                                Spacer()
                                if mac.hostID == chosen { Image(systemName: "checkmark").fontWeight(.semibold) }
                            }
                        }
                    }
                } header: {
                    Text("Send to")
                } footer: {
                    Text("It goes to the Downloads folder on the Mac. Open PocketDesk on your Mac if it isn't listed.")
                }
                if let transfer = controller.store.transfers.last {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(transfer.count > 1 ? "Sending \(transfer.position) of \(transfer.count)…" : "Sending…")
                            ProgressView(value: transfer.fraction)
                            Text(transfer.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send", action: send)
                        .disabled(chosen == nil || files?.isEmpty != false || sending)
                }
            }
        }
        .task {
            controller.startDiscovery()
            files = await Self.copy(providers)
        }
        .onChange(of: macs) {
            // The Mac used most recently, until another is picked.
            if chosen == nil || !macs.contains(where: { $0.hostID == chosen }) {
                chosen = macs.filter { $0.lastUsed != nil }.max { $0.lastUsed! < $1.lastUsed! }?.hostID ?? macs.first?.hostID
            }
        }
    }

    private var title: String {
        guard let files else { return "PocketDesk" }
        return files.count == 1 ? files[0].name : "\(files.count) Items"
    }

    private func send() {
        guard let files, let chosen else { return }
        sending = true
        problem = nil
        Task {
            do {
                try await controller.send(files, to: chosen)
                for file in files where file.isTemporary { try? FileManager.default.removeItem(at: file.url) }
                done()
            } catch {
                problem = String(describing: error)
                sending = false
            }
        }
    }

    /// Copies what was shared somewhere it can be read while it's sent.
    private static func copy(_ providers: [NSItemProvider]) async -> [OutgoingFile] {
        var files: [OutgoingFile] = []
        for provider in providers {
            let type = [UTType.movie, .image, .pdf, .item].first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
            guard let type else { continue }
            let file: OutgoingFile? = await withCheckedContinuation { done in
                _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                    guard let url else { return done.resume(returning: nil) }
                    let folder = URL.temporaryDirectory.appending(path: "Outgoing/\(UUID().uuidString)")
                    let name = provider.suggestedName.map { name in
                        url.pathExtension.isEmpty || name.hasSuffix(".\(url.pathExtension)") ? name : "\(name).\(url.pathExtension)"
                    } ?? url.lastPathComponent
                    let copy = folder.appending(path: name)
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: url, to: copy)
                        done.resume(returning: OutgoingFile(url: copy, isTemporary: true))
                    } catch {
                        done.resume(returning: nil)
                    }
                }
            }
            if let file { files.append(file) }
        }
        return files
    }
}
