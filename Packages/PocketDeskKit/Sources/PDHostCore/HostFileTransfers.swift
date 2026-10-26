#if os(macOS)
import CoreServices
import Foundation
import os
import PDProtocol
import PDSecurity
import PDTransport

/// One session's file transfers on the Mac: files the phone sends land in Downloads, and the
/// phone browses and fetches files from the shared folders.
actor HostFileTransfers {
    struct Folders: Sendable {
        /// Where received files go.
        var downloads: URL
        /// Where unfinished ones wait to be resumed.
        var incoming: URL
        var shared: @Sendable () -> SharedFolders
        var mutations: FileMutations = .shared

        static var standard: Folders {
            let files = FileManager.default
            return Folders(downloads: files.urls(for: .downloadsDirectory, in: .userDomainMask)[0],
                           incoming: URL.applicationSupportDirectory.appending(path: "PocketDesk/Incoming"),
                           shared: { SharedFolders.current })
        }
    }

    private let session: any PeerSession
    private let peer: Fingerprint
    private let folders: Folders
    /// A file arrived: where it was saved.
    private let onSaved: @Sendable (URL) -> Void
    private var receiving: [UInt64: (receiver: FileReceiver, name: String)] = [:]
    private var sending: [UInt64: (sender: FileSender, task: Task<Void, Never>)] = [:]

    init(session: any PeerSession, peer: Fingerprint, folders: Folders, onSaved: @escaping @Sendable (URL) -> Void) {
        self.session = session
        self.peer = peer
        self.folders = folders
        self.onSaved = onSaved
    }

    /// The file messages; anything else is the caller's.
    static func handles(_ message: ControlMessage) -> Bool {
        switch message {
        case .sendFile, .getFile, .fileProgress, .fileFailed, .listFiles, .mutateFile: true
        default: false
        }
    }

    func handle(_ message: ControlMessage) async {
        switch message {
        case .mutateFile(let request):
            let result = await folders.mutations.apply(request, folders: folders.shared)
            try? await session.send(.fileMutationResult(result))
        case .listFiles(let path):
            let list = folders.shared().list(path)
            try? await session.send(.fileList(list))
        case .sendFile(let offer):
            await receive(offer)
        case .getFile(let request):
            await send(request)
        case .fileProgress(let id, let received):
            await sending[id]?.sender.acknowledge(received)
        case .fileFailed(let id, _):
            if let transfer = sending.removeValue(forKey: id) {
                await transfer.sender.stop(.cancelled)
            }
            // A cancelled upload keeps its part file, so sending it again resumes.
            receiving[id] = nil
        default:
            break
        }
    }

    func handle(_ chunk: FileChunk) async {
        guard var transfer = receiving[chunk.id] else { return }
        do {
            switch try transfer.receiver.write(chunk) {
            case .more:
                receiving[chunk.id] = transfer
            case .acknowledge(let received):
                receiving[chunk.id] = transfer
                try? await session.send(.fileProgress(id: chunk.id, received: received))
            case .done:
                receiving[chunk.id] = nil
                let url = try transfer.receiver.finish(into: folders.downloads, name: transfer.name)
                Self.quarantine(url)
                try? await session.send(.fileProgress(id: chunk.id, received: transfer.receiver.size))
                try? await session.send(.fileSaved(id: chunk.id, name: url.lastPathComponent))
                onSaved(url)
            }
        } catch {
            receiving[chunk.id] = nil
            Self.log.error("Receiving \(transfer.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            try? await session.send(.fileFailed(id: chunk.id, reason: "The Mac couldn't save “\(transfer.name)”."))
        }
    }

    /// Stops what's sending when the session ends. Part files stay, to resume next time.
    func stop() async {
        for (_, transfer) in sending {
            await transfer.sender.stop(.cancelled)
            transfer.task.cancel()
        }
        sending = [:]
        receiving = [:]
    }

    private func receive(_ offer: FileOffer) async {
        let name = FileOffer.safeName(offer.name)
        let available = (try? folders.downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? nil
        if let available, offer.size > UInt64(max(available, 0)) {
            try? await session.send(.fileFailed(id: offer.id, reason: "The Mac doesn't have room for “\(name)”."))
            return
        }
        do {
            // Per phone, so one phone can't resume (or read back) another's upload.
            let part = folders.incoming.appending(path: "\(peer.description.prefix(16))-\(offer.id).part")
            let receiver = try FileReceiver(id: offer.id, size: offer.size, partURL: part)
            receiving[offer.id] = (receiver, name)
            try? await session.send(.fileAccepted(id: offer.id, offset: receiver.received))
        } catch {
            try? await session.send(.fileFailed(id: offer.id, reason: "The Mac couldn't save “\(name)”."))
        }
    }

    private func send(_ request: FileRequest) async {
        let url: URL
        do { url = try folders.shared().url(for: request.path) } catch {
            try? await session.send(.fileFailed(id: request.id, reason: error.description))
            return
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else {
            try? await session.send(.fileFailed(id: request.id, reason: SharedFolders.Problem.isFolder.description))
            return
        }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil,
              FileManager.default.isReadableFile(atPath: url.path) else {
            try? await session.send(.fileFailed(id: request.id, reason: SharedFolders.Problem.notAllowed.description))
            return
        }
        let sender = FileSender(id: request.id, url: url, size: size)
        let session = session
        try? await session.send(.fileOffer(FileOffer(id: request.id, name: url.lastPathComponent, size: size)))
        let task = Task {
            do {
                try await sender.run(from: request.offset) { chunk in try await session.send(chunk: chunk) }
            } catch FileTransferError.cancelled {
            } catch {
                try? await session.send(.fileFailed(id: request.id, reason: String(describing: error)))
            }
            self.finishedSending(request.id)
        }
        sending[request.id] = (sender, task)
    }

    private func finishedSending(_ id: UInt64) {
        sending[id] = nil
    }

    /// Like AirDrop: Gatekeeper checks anything received before it's opened.
    private static func quarantine(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "PocketDesk",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String]
        var url = url
        try? url.setResourceValues(values)
    }

    static let log = Logger(subsystem: "com.pocketdesk.host", category: "files")
}
#endif
