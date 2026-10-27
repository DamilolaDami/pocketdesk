#if os(macOS)
import AppKit
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
        let mode: VirtualDisplayMode
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
        let baseline = try await Self.displays()
        guard baseline.contains(where: { $0.main }) else {
            throw VirtualDisplayError.unavailable("Wake and unlock the Mac and keep a physical display available before creating a workspace.")
        }
        let digest = SHA256.hash(data: Data(logicalID.utf8))
        let serial = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        var message = [CChar](repeating: 0, count: 512)
        let token = PDVDCreateScaled(UInt32(mode.width), UInt32(mode.height), UInt32(mode.scale), Double(mode.refreshRate), max(1, serial), &message, message.count)
        guard token != 0 else { throw VirtualDisplayError.unavailable(Self.text(message)) }
        let resource = VirtualDisplayResource(displayID: PDVDCaptureID(token))
        resources[resource.id] = Owned(token: token, resource: resource, mode: mode)
        do {
            try await Self.waitFor(resource.displayID, mode: mode, physical: baseline, creationToken: token)
            return resource
        } catch {
            // Cleanup continues even when the requesting task was cancelled.
            do { try await destroy(resource) }
            catch { throw VirtualDisplayCreationFailure(resource: resource) }
            throw error
        }
    }

    public func configure(_ resource: VirtualDisplayResource, mode: VirtualDisplayMode) async throws {
        guard mode.isValid else { throw VirtualDisplayError.invalidMode }
        guard let owned = resources[resource.id], owned.resource == resource else { throw VirtualDisplayError.notViewing }
        if mode == owned.mode { return }
        let physical = try await Self.displays().filter { $0.id != resource.displayID }
        do {
            try await Self.select(token: owned.token, mode: mode)
            guard PDVDCaptureID(owned.token) == resource.displayID else { throw VirtualDisplayConfigurationFailure() }
            try await Self.waitFor(resource.displayID, mode: mode, physical: physical, creationToken: owned.token)
            resources[resource.id] = Owned(token: owned.token, resource: resource, mode: mode)
        } catch {
            let restored = await Task.detached {
                do {
                    try await Self.select(token: owned.token, mode: owned.mode)
                    try await Self.waitFor(resource.displayID, mode: owned.mode, physical: physical, creationToken: owned.token)
                    return true
                } catch { return false }
            }.value
            guard restored else { throw VirtualDisplayConfigurationFailure() }
            throw error
        }
    }

    private nonisolated static func select(token: UInt64, mode: VirtualDisplayMode) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        var message = [CChar](repeating: 0, count: 512)
        repeat {
            try Task.checkCancellation()
            if PDVDConfigure(token, UInt32(mode.width), UInt32(mode.height), UInt32(mode.scale), Double(mode.refreshRate), &message, message.count) { return }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw VirtualDisplayError.unavailable(Self.text(message))
    }

    private nonisolated static func waitFor(_ id: UInt32, mode: VirtualDisplayMode, physical: [Display], creationToken: UInt64? = nil) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        repeat {
            try Task.checkCancellation()
            let current = try await displays()
            if let display = current.first(where: { $0.id == id }) {
                if !display.main, display.mirrorOf == 0,
                   Int(display.bounds.width) == mode.width, Int(display.bounds.height) == mode.height,
                   display.pixelsWide == mode.pixelWidth, display.pixelsHigh == mode.pixelHeight,
                   (CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0) == 0 || abs((CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0) - Double(mode.refreshRate)) < 0.1,
                   current.filter({ $0.id != id }) == physical { return }
            }
            if let token = creationToken {
                var message = [CChar](repeating: 0, count: 512)
                _ = PDVDConfigure(token, UInt32(mode.width), UInt32(mode.height), UInt32(mode.scale), Double(mode.refreshRate), &message, message.count)
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        throw VirtualDisplayError.unavailable("macOS couldn't apply that size while preserving the existing screen layout. Try another size or reconnect the workspace.")
    }

    public func destroy(_ resource: VirtualDisplayResource) async throws {
        guard let owned = resources[resource.id], owned.resource == resource else { return }
        PDVDDestroy(owned.token)
        let id = resource.displayID
        let gone = await Task.detached {
            let deadline = ContinuousClock.now + .seconds(3)
            repeat {
                if let displays = try? await Self.displays(), !displays.contains(where: { $0.id == id }) { return true }
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

    private nonisolated static func displays() async throws -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { throw VirtualDisplayError.unavailable("macOS couldn't list displays.") }
        var ids = [UInt32](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { throw VirtualDisplayError.unavailable("macOS couldn't list displays.") }
        let scales = await MainActor.run {
            Dictionary(uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (UInt32, Double)? in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return (id.uint32Value, Double(screen.backingScaleFactor))
            })
        }
        return ids.prefix(Int(count)).map { id in
            let mode = CGDisplayCopyDisplayMode(id)
            // Virtual screens may not expose a CGDisplayMode object. Match the existing
            // capture engine's documented size-query fallback instead of treating nil as 0×0.
            let bounds = CGDisplayBounds(id)
            var width = mode?.pixelWidth ?? Int(bounds.width * (scales[id] ?? 1))
            var height = mode?.pixelHeight ?? Int(bounds.height * (scales[id] ?? 1))
            if let mode, (mode.width > mode.height) != (bounds.width > bounds.height) { swap(&width, &height) }
            return Display(id: id, bounds: bounds, pixelsWide: width, pixelsHigh: height,
                           main: CGDisplayIsMain(id) != 0, mirrorOf: CGDisplayMirrorsDisplay(id))
        }.sorted { $0.id < $1.id }
    }

    private static func text(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
