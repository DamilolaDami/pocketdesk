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
final class StreamUIView: UIView, UIKeyInput {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    var videoSize: CGSize = .zero
    var onInput: (InputEvent) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }

    private static let returnKey: UInt16 = 0x24
    private static let deleteKey: UInt16 = 0x33
    /// Mac pixels scrolled per point of finger travel.
    private static let scrollScale: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed))
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        tap.require(toFail: longPress)
        for recognizer in [tap, longPress, drag, scroll] { addGestureRecognizer(recognizer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func point(_ recognizer: UIGestureRecognizer, clamped: Bool = false) -> (x: Float, y: Float)? {
        VideoGeometry.normalized(recognizer.location(in: self), videoSize: videoSize, in: bounds.size, clamped: clamped)
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
        guard recognizer.state == .changed else { return }
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
