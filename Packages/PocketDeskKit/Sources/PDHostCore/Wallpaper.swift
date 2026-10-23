#if os(macOS)
import AppKit
import ImageIO
import PDProtocol

/// The main display's desktop picture, small, for the phone to draw this Mac with.
enum DesktopWallpaper {
    /// Read again only when the picture changes: it goes out with every connection.
    private static let cache = Cache()

    static func current() async -> String? {
        guard let url = await MainActor.run(body: { NSScreen.main.flatMap(NSWorkspace.shared.desktopImageURL(for:)) }) else {
            return nil
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path(percentEncoded: false))|\(modified?.timeIntervalSince1970 ?? 0)"
        if let hit = await cache.value(for: key) { return hit }
        let picture = await Task.detached { thumbnail(of: url) }.value
        await cache.set(picture, for: key)
        return picture
    }

    /// A picture file shrunk to `HelloAck.wallpaperSize` wide; `nil` for anything ImageIO can't
    /// read (a shuffle folder, say).
    static func thumbnail(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return JPEGThumbnail.base64(from: data, maxPixels: HelloAck.wallpaperSize)
    }

    private actor Cache {
        private var key: String?
        private var picture: String?

        func value(for key: String) -> String? { key == self.key ? picture : nil }
        func set(_ picture: String?, for key: String) {
            self.key = key
            self.picture = picture
        }
    }
}

/// Pictures shrunk to send to the phone, as base64 JPEG.
enum JPEGThumbnail {
    static func base64(from data: Data, maxPixels: Int, quality: Double = 0.75) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (jpeg as Data).base64EncodedString()
    }
}
#endif
