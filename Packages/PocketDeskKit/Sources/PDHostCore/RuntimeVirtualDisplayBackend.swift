#if os(macOS)
import CoreGraphics
import CryptoKit
import Foundation
import PDProtocol
import PDVirtualDisplayRuntime

/// The private API is confined here and in the C bridge. The iPhone dependency graph does
/// not include that bridge. Native references are process-local; no capture IDs are persisted.
public actor RuntimeVirtualDisplayBackend: VirtualDisplayBackend {
    private struct Owned: Sendable {
        let token: UInt64
        let resource: VirtualDisplayResource
    }
    private var resources: [UUID: Owned] = [:]
    public init() {}

    deinit {
        for owned in resources.values { PDVDDestroy(owned.token) }
    }

    public func unavailableReason() -> String? {
        var message = [CChar](repeating: 0, count: 512)
        return PDVDAvailable(&message, message.count) ? nil : Self.text(message)
    }

    public func create(logicalID: String, mode: VirtualDisplayMode) async throws -> VirtualDisplayResource {
        guard mode.isValid else { throw VirtualDisplayError.invalidMode }
        guard resources.isEmpty else { throw VirtualDisplayError.busy }
        if let reason = unavailableReason() { throw VirtualDisplayError.unavailable(reason) }
        try Task.checkCancellation()
        let baseline = try Self.displays()
        let digest = SHA256.hash(data: Data(logicalID.utf8))
        let serial = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var message = [CChar](repeating: 0, count: 512)
        let token = PDVDCreate(UInt32(mode.width), UInt32(mode.height), Double(mode.refreshRate), max(1, serial), &message, message.count)
        guard token != 0 else { throw VirtualDisplayError.unavailable(Self.text(message)) }
        let resource = VirtualDisplayResource(displayID: PDVDCaptureID(token))
        resources[resource.id] = Owned(token: token, resource: resource)
        do {
            let deadline = ContinuousClock.now + .seconds(3)
            var observed = "display not enumerated"
            repeat {
                try Task.checkCancellation()
                let current = try Self.displays()
                if let display = current.first(where: { $0.id == resource.displayID }) {
                    observed = "\(display.pixelsWide)×\(display.pixelsHigh), main=\(display.main), mirror=\(display.mirrorOf), originalLayoutMatches=\(current.filter { $0.id != resource.displayID } == baseline)"
                    if let previous = baseline.first(where: { old in current.first(where: { $0.id == old.id }) != old }) {
                        observed += "; changed from \(previous) to \(String(describing: current.first { $0.id == previous.id }))"
                    }
                }
                if let display = current.first(where: { $0.id == resource.displayID }),
                   !display.main, display.mirrorOf == 0, display.pixelsWide == mode.width, display.pixelsHigh == mode.height,
                   current.filter({ $0.id != resource.displayID }) == baseline {
                    return resource
                }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            throw VirtualDisplayError.unavailable("The requested display mode couldn't be applied safely (\(observed)).")
        } catch {
            // Cleanup continues even when the requesting task was cancelled.
            do { try await destroy(resource) }
            catch { throw VirtualDisplayCreationFailure(resource: resource) }
            throw error
        }
    }

    public func destroy(_ resource: VirtualDisplayResource) async throws {
        guard let owned = resources[resource.id], owned.resource == resource else { return }
        PDVDDestroy(owned.token)
        let id = resource.displayID
        let gone = await Task.detached {
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                if let displays = try? Self.displays(), !displays.contains(where: { $0.id == id }) { return true }
                try? await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            return false
        }.value
        guard gone else { throw VirtualDisplayError.cleanupFailed }
        resources[resource.id] = nil
    }

    private struct Display: Equatable, Sendable {
        let id: UInt32
        let bounds: CGRect
        let pixelsWide: Int
        let pixelsHigh: Int
        let main: Bool
        let mirrorOf: UInt32
    }

    private nonisolated static func displays() throws -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { throw VirtualDisplayError.unavailable("macOS couldn't list displays.") }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { throw VirtualDisplayError.unavailable("macOS couldn't list displays.") }
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            // Virtual screens may not expose a CGDisplayMode object. Match the existing
            // capture engine's documented size-query fallback instead of treating nil as 0×0.
            return Display(id: id, bounds: CGDisplayBounds(id), pixelsWide: mode?.pixelWidth ?? CGDisplayPixelsWide(id),
                           pixelsHigh: mode?.pixelHeight ?? CGDisplayPixelsHigh(id), main: CGDisplayIsMain(id) != 0,
                           mirrorOf: CGDisplayMirrorsDisplay(id))
        }.sorted { $0.id < $1.id }
    }

    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
