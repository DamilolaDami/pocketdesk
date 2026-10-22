#if os(macOS)
import AppKit
import PDProtocol

/// The Mac's apps, for the phone's shortcut editor.
public protocol AppCatalogSource: Sendable {
    func apps() async -> [MacApp]
    /// A square PNG of the app's icon, or `nil` if no app has that bundle ID.
    func iconPNG(bundleID: String) async -> Data?
}

/// Apps in the usual folders (not every helper bundle on disk), named as Finder shows them.
public struct InstalledApps: AppCatalogSource {
    public static let iconSize = 128

    public init() {}

    public func apps() async -> [MacApp] {
        let files = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     URL.homeDirectory.appending(path: "Applications").path(percentEncoded: false)].map { URL(filePath: $0) }
        // Not `.skipsHiddenFiles`: /Applications/Safari.app is a symlink with the hidden flag set.
        func contents(of folder: URL) -> [URL] {
            ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
        }
        var bundles: [URL] = []
        for root in roots {
            for item in contents(of: root) {
                if item.pathExtension == "app" {
                    bundles.append(item)
                } else if !roots.contains(item) {
                    // One level of folders, e.g. /Applications/Utilities or a vendor folder.
                    bundles += contents(of: item).filter { $0.pathExtension == "app" }
                }
            }
        }
        var seen: Set<String> = []
        return bundles.compactMap { url -> MacApp? in
            // Safari and a few others are symlinks into the system cryptex.
            guard let bundle = Bundle(url: url.resolvingSymlinksInPath()), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier, seen.insert(id).inserted else { return nil }
            var name = files.displayName(atPath: url.path(percentEncoded: false))
            if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
            return MacApp(name: name, bundleID: id)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func iconPNG(bundleID: String) async -> Data? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return await Self.render(NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
    }

    @MainActor private static func render(_ icon: NSImage) -> Data? {
        let side = iconSize
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let image = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:])
    }
}
#endif
