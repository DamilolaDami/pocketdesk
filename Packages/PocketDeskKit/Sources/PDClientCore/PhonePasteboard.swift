import Foundation
import PDProtocol
#if canImport(UIKit)
import UIKit
#endif

/// Where things copied on the Mac land on the phone. Writing never shows the paste prompt;
/// only reading does, which is why sending goes through the app's Paste button.
public protocol PhonePasteboard: Sendable {
    @MainActor func write(_ item: ClipboardItem)
}

public struct SystemPasteboard: PhonePasteboard {
    public init() {}

    @MainActor public func write(_ item: ClipboardItem) {
        #if canImport(UIKit)
        if let text = item.text {
            UIPasteboard.general.string = text
        } else if let image = item.png.flatMap({ Data(base64Encoded: $0) }).flatMap(UIImage.init(data:)) {
            UIPasteboard.general.image = image
        }
        #endif
    }
}
