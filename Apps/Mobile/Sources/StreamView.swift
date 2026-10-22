import AVFoundation
import PDClientCore
import PDProtocol
import SwiftUI
import UIKit

/// The video layer plus direct-touch input: touch where you want the Mac's pointer.
struct StreamView: UIViewRepresentable {
    let controller: SessionController
    let videoSize: CGSize
    @Binding var keyboardShown: Bool

    func makeUIView(context: Context) -> StreamUIView {
        let view = StreamUIView()
        controller.display.attach(view.displayLayer)
        view.onInput = { [controller] in controller.send($0) }
        view.onText = { [controller] in controller.insertText($0) }
        return view
    }

    func updateUIView(_ view: StreamUIView, context: Context) {
        view.videoSize = videoSize
        if keyboardShown, !view.isFirstResponder {
            view.becomeFirstResponder()
        } else if !keyboardShown, view.isFirstResponder {
            view.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ view: StreamUIView, coordinator: ()) {
        view.onInput = { _ in }
    }
}

/// Gestures → `InputEvent`s:
/// - tap: click · long press: right-click · one-finger drag: click-drag
/// - two-finger pan: scroll · keyboard (`UIKeyInput`): text, return, delete
/// - pinch: zoom the picture on the phone (pans with the fingers); nothing is sent to the Mac
final class StreamUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    /// Holds the video layer; pinch transforms it. Touch locations are read in its
    /// coordinate space, so input stays accurate at any zoom.
    private let content = VideoLayerView()
    var displayLayer: AVSampleBufferDisplayLayer { content.displayLayer }

    var videoSize: CGSize = .zero
    private var zoom: CGFloat = 1
    private var offset: CGPoint = .zero
    private var pinchCentroid: CGPoint = .zero
    private var isPinching = false
    private static let maxZoom: CGFloat = 6
    var onInput: (InputEvent) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }

    private static let returnKey: UInt16 = 0x24
    private static let deleteKey: UInt16 = 0x33
    /// Mac pixels scrolled per point of finger travel.
    private static let scrollScale: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        displayLayer.videoGravity = .resizeAspect
        content.layer.anchorPoint = .zero
        addSubview(content)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        scroll.delegate = self
        tap.require(toFail: longPress)
        for recognizer in [tap, longPress, drag, scroll, pinch] { addGestureRecognizer(recognizer) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        applyZoom()
    }

    /// Pinch and two-finger scroll both see the same fingers; `scrolled` stands down while
    /// a pinch is active.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        let centroid = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            isPinching = true
            pinchCentroid = centroid
        case .changed:
            let newZoom = min(max(zoom * recognizer.scale, 1), Self.maxZoom)
            let factor = newZoom / zoom
            recognizer.scale = 1
            // Zoom about the fingers, then follow them as they move.
            offset.x = centroid.x - factor * (pinchCentroid.x - offset.x)
            offset.y = centroid.y - factor * (pinchCentroid.y - offset.y)
            zoom = newZoom
            pinchCentroid = centroid
            applyZoom()
        default:
            isPinching = false
        }
    }

    private func applyZoom() {
        // Keep the zoomed picture covering the view: no panning past its edges.
        offset.x = min(0, max(bounds.width - bounds.width * zoom, offset.x))
        offset.y = min(0, max(bounds.height - bounds.height * zoom, offset.y))
        content.layer.position = .zero
        content.transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: zoom, y: zoom)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func point(_ recognizer: UIGestureRecognizer, clamped: Bool = false) -> (x: Float, y: Float)? {
        VideoGeometry.normalized(recognizer.location(in: content), videoSize: videoSize, in: content.bounds.size,
                                 clamped: clamped)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let (x, y) = point(recognizer) else { return }
        onInput(.pointerMove(x: x, y: y))
        onInput(.button(.left, isDown: true, x: x, y: y))
        onInput(.button(.left, isDown: false, x: x, y: y))
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let (x, y) = point(recognizer) else { return }
        onInput(.pointerMove(x: x, y: y))
        onInput(.button(.right, isDown: true, x: x, y: y))
        onInput(.button(.right, isDown: false, x: x, y: y))
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard let (x, y) = point(recognizer, clamped: true) else { return }
        switch recognizer.state {
        case .began:
            onInput(.pointerMove(x: x, y: y))
            onInput(.button(.left, isDown: true, x: x, y: y))
        case .changed:
            onInput(.pointerMove(x: x, y: y))
        case .ended, .cancelled, .failed:
            onInput(.button(.left, isDown: false, x: x, y: y))
        default:
            break
        }
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .changed, !isPinching else {
            recognizer.setTranslation(.zero, in: self)
            return
        }
        let delta = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        // Natural scrolling: content follows the fingers.
        onInput(.scroll(dx: Float(delta.x * Self.scrollScale), dy: Float(delta.y * Self.scrollScale)))
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func insertText(_ text: String) {
        if text == "\n" {
            press(Self.returnKey)
        } else {
            onText(text)
        }
    }

    func deleteBackward() {
        press(Self.deleteKey)
    }

    private func press(_ key: UInt16) {
        onInput(.key(code: key, isDown: true, modifiers: 0))
        onInput(.key(code: key, isDown: false, modifiers: 0))
    }
}

/// A view whose backing layer is the video layer.
private final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
