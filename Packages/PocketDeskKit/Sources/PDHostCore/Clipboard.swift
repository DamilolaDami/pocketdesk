#if os(macOS)
import AppKit
import PDProtocol

/// The Mac's clipboard, abstracted so `HostSession` runs against a fake in tests.
public protocol ClipboardSink: Sendable {
    /// Bumps whenever anything copies.
    func changeCount() async -> Int
    func read() async -> ClipboardItem?
    /// Puts the phone's item on the clipboard; returns the new change count (so the session
    /// doesn't send it straight back).
    func write(_ item: ClipboardItem) async -> Int
}

/// `NSPasteboard.general`. Text wins when there's both (copying from a web page); images
/// go as PNG.
public struct MacPasteboard: ClipboardSink {
    public init() {}

    @MainActor public func changeCount() -> Int { NSPasteboard.general.changeCount }

    @MainActor public func read() -> ClipboardItem? {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return ClipboardItem(text: text)
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff).flatMap(Self.png(fromTIFF:)) {
            return ClipboardItem(png: data.base64EncodedString())
        }
        return nil
    }

    @MainActor public func write(_ item: ClipboardItem) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let text = item.text {
            pasteboard.setString(text, forType: .string)
        } else if let png = item.png.flatMap({ Data(base64Encoded: $0) }) {
            pasteboard.setData(png, forType: .png)
        }
        return pasteboard.changeCount
    }

    private static func png(fromTIFF tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
#endif
