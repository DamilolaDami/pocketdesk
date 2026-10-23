import AVFoundation
import GameController
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
        view.onTapKey = { [controller] in controller.tapKey($0, modifiers: $1) }
        view.onKey = { [controller] in controller.sendKey($0, isDown: $1, modifiers: $2) }
        view.onHideKeyboard = { keyboardShown = false }
        return view
    }

    func updateUIView(_ view: StreamUIView, context: Context) {
        view.videoSize = videoSize
        view.wantsKeyboard = keyboardShown
    }

    static func dismantleUIView(_ view: StreamUIView, coordinator: ()) {
        view.onInput = { _ in }
        view.onKey = { _, _, _ in }
        view.onTapKey = { _, _ in }
    }
}

/// Gestures → `InputEvent`s:
/// - tap: click · long press: right-click · one-finger drag: click-drag
/// - two-finger pan: scroll; zoomed in, it moves the picture first and scrolls the Mac
///   only with what's left past its edges
/// - keyboard (`UIKeyInput`): text, return, delete
/// - hardware keyboard (`pressesBegan`): every key as itself, modifiers included
/// - the key bar above the keyboard: Esc, Tab, arrows, F-keys and sticky ⌃ ⌥ ⇧ ⌘
/// - pinch: zoom the picture on the phone (pans with the fingers); nothing is sent to the Mac
/// - two-finger double-tap: toggle a comfortable zoom; nothing is sent to the Mac
final class StreamUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    /// Holds the video layer; pinch transforms it. Touch locations are read in its
    /// coordinate space, so input stays accurate at any zoom.
    private let content = VideoLayerView()
    var displayLayer: AVSampleBufferDisplayLayer { content.displayLayer }

    var videoSize: CGSize = .zero
    private var viewport = ZoomViewport()
    private var pinchCentroid: CGPoint = .zero
    private var isPinching = false
    var onInput: (InputEvent) -> Void = { _ in }
    var onText: (String) -> Void = { _ in }
    var onTapKey: (UInt16, MacModifiers) -> Void = { _, _ in }
    var onKey: (UInt16, Bool, MacModifiers) -> Void = { _, _, _ in }
    var onHideKeyboard: () -> Void = {}

    /// The on-screen keyboard is wanted. With a hardware keyboard attached the view takes
    /// keys regardless, so typing works without opening anything.
    var wantsKeyboard = false {
        didSet {
            if wantsKeyboard { putAway = false }
            if wantsKeyboard != oldValue { updateFirstResponder() }
        }
    }
    /// The on-screen keyboard was put away by hand: don't bring it back just because a
    /// hardware keyboard is attached too (an iPad can show both).
    private var putAway = false
    /// The bar's ⌃ ⌥ ⇧ ⌘, applied to the next key from anywhere.
    private var sticky = StickyModifiers() {
        didSet { if sticky != oldValue { accessory.sticky = sticky } }
    }
    private lazy var accessory = KeyBarAccessory(KeyBar(
        tapModifier: { [weak self] modifier in self?.sticky.tap(modifier) },
        tap: { [weak self] code in self?.tapKey(code) },
        dismiss: { [weak self] in self?.hideKeyboard() }))
    /// Hardware keys down now, with what each was sent as: the key-up must match.
    private var heldKeys: [UIKeyboardHIDUsage: UInt16] = [:]
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
        let zoomToggle = UITapGestureRecognizer(target: self, action: #selector(toggledZoom))
        zoomToggle.numberOfTouchesRequired = 2
        zoomToggle.numberOfTapsRequired = 2
        tap.require(toFail: longPress)
        for recognizer in [tap, longPress, drag, scroll, pinch, zoomToggle] { addGestureRecognizer(recognizer) }

        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardsChanged), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    /// The on-screen keyboard is showing, not just the key bar over a hardware keyboard.
    private var softKeyboardUp = false

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let screen = window?.windowScene?.screen.bounds else { return }
        softKeyboardUp = screen.intersection(frame).height > 150
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateFirstResponder()
    }

    @objc private func keyboardsChanged() {
        putAway = false
        updateFirstResponder()
    }

    private func updateFirstResponder() {
        guard window != nil else { return }
        let wanted = wantsKeyboard || (GCKeyboard.coalesced != nil && !putAway)
        if wanted, !isFirstResponder {
            becomeFirstResponder()
        } else if !wanted, isFirstResponder {
            resignFirstResponder()
        }
    }

    private func hideKeyboard() {
        onHideKeyboard()
        // With a hardware keyboard and only the bar showing, keep taking keys.
        if softKeyboardUp || GCKeyboard.coalesced == nil {
            putAway = true
            resignFirstResponder()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        viewport.viewSize = bounds.size
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
            // Zoom about the fingers, then follow them as they move.
            viewport.scale(by: recognizer.scale, about: pinchCentroid)
            recognizer.scale = 1
            _ = viewport.pan(by: CGVector(dx: centroid.x - pinchCentroid.x, dy: centroid.y - pinchCentroid.y))
            pinchCentroid = centroid
            applyZoom()
        default:
            isPinching = false
        }
    }

    @objc private func toggledZoom(_ recognizer: UITapGestureRecognizer) {
        viewport.toggle(about: recognizer.location(in: self))
        UIView.animate(withDuration: 0.25) { self.applyZoom() }
    }

    private func applyZoom() {
        content.layer.position = .zero
        content.transform = viewport.transform
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
        // Zoomed in, the picture moves first; the Mac scrolls with what's left past its edges.
        let rest = viewport.pan(by: CGVector(dx: delta.x, dy: delta.y))
        if viewport.isZoomed { applyZoom() }
        guard rest != .zero else { return }
        // Natural scrolling: content follows the fingers.
        onInput(.scroll(dx: Float(rest.dx * Self.scrollScale), dy: Float(rest.dy * Self.scrollScale)))
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    override var inputAccessoryView: UIView? { accessory }

    func insertText(_ text: String) {
        let held = sticky.active
        if text == "\n" {
            tapKey(MacKey.return)
        } else if !held.isEmpty, text.count == 1, let stroke = KeyMap.stroke(for: text.first!) {
            // ⌘ on the bar, then "c" on the keyboard: ⌘C, not the letter.
            tapKey(stroke.code, extra: stroke.shift ? .shift : [])
        } else {
            onText(text)
        }
    }

    func deleteBackward() {
        tapKey(MacKey.delete)
    }

    private func tapKey(_ code: UInt16, extra: MacModifiers = []) {
        onTapKey(code, sticky.consume().union(extra))
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let code = KeyMap.macKey(hidUsage: key.keyCode.rawValue) else {
                unhandled.insert(press)
                continue
            }
            var modifiers = MacModifiers(phoneFlags: key.modifierFlags.rawValue)
            if let own = KeyMap.modifier(forMacKey: code) {
                modifiers.insert(own)
            } else {
                modifiers.formUnion(sticky.consume())
            }
            heldKeys[key.keyCode] = code
            onKey(code, true, modifiers)
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses, with: event) { super.pressesEnded($0, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        release(presses, with: event) { super.pressesCancelled($0, with: event) }
    }

    private func release(_ presses: Set<UIPress>, with event: UIPressesEvent?, unhandled: (Set<UIPress>) -> Void) {
        var rest = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let code = heldKeys.removeValue(forKey: key.keyCode) else {
                rest.insert(press)
                continue
            }
            var modifiers = MacModifiers(phoneFlags: key.modifierFlags.rawValue)
            if let own = KeyMap.modifier(forMacKey: code) { modifiers.remove(own) }
            onKey(code, false, modifiers)
        }
        if !rest.isEmpty { unhandled(rest) }
    }
}

/// A view whose backing layer is the video layer.
private final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
