import PDClientCore
import PDProtocol
import SwiftUI
import UniformTypeIdentifiers

extension ClipboardItem {
    /// The first text or image the paste button handed over; images go as PNG. On the main
    /// actor, where the button hands them over: item providers can't be sent between threads.
    @MainActor init?(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSString.self) {
                let text: String? = await withCheckedContinuation { done in
                    _ = provider.loadObject(ofClass: NSString.self) { object, _ in done.resume(returning: object as? String) }
                }
                if let text {
                    self.init(text: text)
                    return
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               let data: Data = await withCheckedContinuation({ done in
                   _ = provider.loadDataRepresentation(for: .image) { data, _ in done.resume(returning: data) }
               }),
               let png = UIImage(data: data)?.pngData() {
                self.init(png: png.base64EncodedString())
                return
            }
        }
        return nil
    }
}
