import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import PDProtocol

extension NowPlayingActivityPreferences {
    public enum Key {
        public static let enabled = "nowPlayingActivity"
        public static let showsDetailsInPushes = "nowPlayingDetailsInPushes"
        public static let showsArtwork = "nowPlayingArtwork"
        public static let showsSkipButtons = "nowPlayingSkipButtons"
        public static let endsWhenPaused = "nowPlayingEndsWhenPaused"
        public static let style = "nowPlayingStyle"
        /// Let the Mac start the activity by push while PocketDesk isn't open.
        public static let startsByPush = "nowPlayingStartsByPush"
    }

    public init(defaults: UserDefaults) {
        self.init()
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        showsDetailsInPushes = defaults.object(forKey: Key.showsDetailsInPushes) as? Bool ?? true
        showsArtwork = defaults.object(forKey: Key.showsArtwork) as? Bool ?? true
        showsSkipButtons = defaults.object(forKey: Key.showsSkipButtons) as? Bool ?? true
        endsWhenPaused = defaults.bool(forKey: Key.endsWhenPaused)
        style = defaults.string(forKey: Key.style).flatMap(NowPlayingStyle.init(rawValue:)) ?? .album
    }
}

/// Covers for the Live Activity, as files in the App Group the widget extension can read.
public enum NowPlayingArtwork {
    public static var directory: URL { SharedStorage.url("NowPlaying") }

    public static func url(for id: String) -> URL {
        directory.appending(path: "\(id).image")
    }

    /// Names a cover by its bytes, so the same one is saved once.
    public static func id(for jpeg: Data) -> String {
        SHA256.hash(data: jpeg).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Saves the card's covers (by ID) and removes older ones: only one activity runs at a
    /// time. Site icons stay, so a card a Mac pushes can use one the phone saved before.
    public static func save(_ images: [String: Data], in directory: URL = directory) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = Set(images.keys.map { "\($0).image" })
        for old in (try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        where !names.contains(old) && !old.hasPrefix("site-") && old != siteTintsName {
            try? fileManager.removeItem(at: directory.appending(path: old))
        }
        for (id, data) in images {
            let url = directory.appending(path: "\(id).image")
            if !fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
                try data.write(to: url, options: .atomic)
            }
        }
    }

    private static let siteTintsName = "site-tints.json"

    /// Saves a site's icon under `NowPlayingCard.siteIconID(for:)`, and its color for the Mac.
    public static func saveSiteIcon(_ png: Data, tint: CardColor?, for host: String, in directory: URL = directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appending(path: "\(NowPlayingCard.siteIconID(for: host)).image"), options: .atomic)
        var tints = siteTints(in: directory)
        tints[host] = tint ?? CardColor(red: 0.5, green: 0.5, blue: 0.5)
        try JSONEncoder().encode(tints).write(to: directory.appending(path: siteTintsName), options: .atomic)
    }

    /// The sites with a saved icon, and their colors.
    public static func siteTints(in directory: URL = directory) -> [String: CardColor] {
        (try? JSONDecoder().decode([String: CardColor].self, from: Data(contentsOf: directory.appending(path: siteTintsName)))) ?? [:]
    }

    /// A site icon at most `maxPixels` on a side, as PNG: favicons come as anything from a
    /// 16 px .ico to a 512 px touch icon, and the Live Activity wants something small.
    public static func icon(from data: Data, maxPixels: Int = 96) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// The cover's average color: the image drawn small, then its pixels averaged.
    public static func averageColor(of imageData: Data) -> CardColor? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var sums = [0.0, 0.0, 0.0]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 { sums[channel] += Double(pixels[index + channel]) }
        }
        let count = Double(side * side) * 255
        return CardColor(red: sums[0] / count, green: sums[1] / count, blue: sums[2] / count)
    }
}
