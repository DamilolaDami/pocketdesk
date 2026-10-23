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
    let trackpad: Bool
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
        view.isTrackpad = trackpad
        view.wantsKeyboard = keyboardShown
    }

    static func dismantleUIView(_ view: StreamUIView, coordinator: ()) {
        view.onInput = { _ in }
        view.onKey = { _, _, _ in }
        view.onTapKey = { _, _ in }
    }
}

/// Gestures → `InputEvent`s. Direct touch (touch where you want the pointer):
/// - tap: click · long press: right-click · one-finger drag: click-drag
/// - two-finger pan: scroll; zoomed in, it moves the picture first and scrolls the Mac
///   only with what's left past its edges
/// - keyboard (`UIKeyInput`): text, return, delete
/// - hardware keyboard (`pressesBegan`): every key as itself, modifiers included
/// - the key bar above the keyboard: Esc, Tab, arrows, F-keys and sticky ⌃ ⌥ ⇧ ⌘
/// - pinch: zoom the picture on the phone (pans with the fingers); nothing is sent to the Mac
/// - two-finger double-tap: toggle a comfortable zoom; nothing is sent to the Mac
/// - two-finger tap: right-click · three-finger swipe: Mission Control, App Exposé, Spaces
///
/// Trackpad mode (`isTrackpad`) moves the pointer like a laptop trackpad instead, with a ring
/// showing where it is; a zoomed-in view follows it:
/// - one-finger drag: move the pointer · tap: click · two-finger tap: right-click
/// - press and hold, then drag: click-drag (select text, move windows)
final class StreamUIView: UIView, UIKeyInput, UIGestureRecognizerDelegate {
    /// Holds the video layer; pinch transforms it. Touch locations are read in its
    /// coordinate space, so input stays accurate at any zoom.
    private let content = VideoLayerView()
    var displayLayer: AVSampleBufferDisplayLayer { content.displayLayer }

    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { applyZoom() } }
    }
    private var viewport = ZoomViewport()
    private var pinchCentroid: CGPoint = .zero
    private var isPinching = false
    /// Where the phone last put the Mac's pointer, in either mode.
    private var pointer = TrackpadPointer()
    /// Shows trackpad mode's pointer at once, ahead of the Mac's own cursor in the video.
    private let cursorRing = UIView()
    private let longPress = UILongPressGestureRecognizer()
    /// The last finger position of a press-and-drag, which reports locations, not steps.
    private var lastPressLocation: CGPoint = .zero
    /// How close to the view's edge the pointer can get before a zoomed-in view follows it.
    private static let followMargin: CGFloat = 48

    var isTrackpad = false {
        didSet {
            guard isTrackpad != oldValue else { return }
            cursorRing.isHidden = !isTrackpad
            // Holding to start a drag should come sooner than a right-click needs to.
            longPress.minimumPressDuration = isTrackpad ? 0.3 : 0.5
            if isTrackpad { followPointer() }
        }
    }
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
        cursorRing.bounds = CGRect(x: 0, y: 0, width: 26, height: 26)
        cursorRing.layer.cornerRadius = 13
        cursorRing.layer.borderWidth = 2
        cursorRing.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
        cursorRing.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        cursorRing.layer.shadowColor = UIColor.black.cgColor
        cursorRing.layer.shadowOpacity = 0.5
        cursorRing.layer.shadowRadius = 3
        cursorRing.layer.shadowOffset = .zero
        cursorRing.isUserInteractionEnabled = false
        cursorRing.isHidden = true
        addSubview(cursorRing)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        longPress.addTarget(self, action: #selector(longPressed))
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
        let rightTap = UITapGestureRecognizer(target: self, action: #selector(rightTapped))
        rightTap.numberOfTouchesRequired = 2
        rightTap.require(toFail: zoomToggle)
        let swipe = UIPanGestureRecognizer(target: self, action: #selector(swiped))
        swipe.minimumNumberOfTouches = 3
        swipe.maximumNumberOfTouches = 3
        tap.require(toFail: longPress)
        for recognizer in [tap, longPress, drag, scroll, pinch, zoomToggle, rightTap, swipe] {
            addGestureRecognizer(recognizer)
        }

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
        case .changed where recognizer.numberOfTouches == 2:
            // Zoom about the fingers, then follow them as they move. Not with three: that's a Mac swipe.
            viewport.scale(by: recognizer.scale, about: pinchCentroid)
            recognizer.scale = 1
            _ = viewport.pan(by: CGVector(dx: centroid.x - pinchCentroid.x, dy: centroid.y - pinchCentroid.y))
            pinchCentroid = centroid
            applyZoom()
        case .changed:
            recognizer.scale = 1
            pinchCentroid = centroid
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
        cursorRing.center = viewport.screenPoint(pointerInContent)
    }

    /// The pointer in the unzoomed picture's coordinates (the content view's).
    private var pointerInContent: CGPoint {
        let rect = VideoGeometry.contentRect(videoSize: videoSize, in: content.bounds.size)
        return CGPoint(x: rect.minX + CGFloat(pointer.x) * rect.width, y: rect.minY + CGFloat(pointer.y) * rect.height)
    }

    /// Trackpad mode: moves the pointer by a finger step and keeps it in view.
    private func movePointer(by delta: CGPoint) {
        let rect = VideoGeometry.contentRect(videoSize: videoSize, in: content.bounds.size)
        pointer.move(by: CGVector(dx: delta.x, dy: delta.y),
                     pictureSize: CGSize(width: rect.width * viewport.zoom, height: rect.height * viewport.zoom))
        onInput(.pointerMove(x: pointer.x, y: pointer.y))
        followPointer()
    }

    private func followPointer() {
        viewport.reveal(pointerInContent, margin: Self.followMargin)
        applyZoom()
    }

    private func click(_ button: MouseButton, at point: (x: Float, y: Float)) {
        onInput(.pointerMove(x: point.x, y: point.y))
        onInput(.button(button, isDown: true, x: point.x, y: point.y))
        onInput(.button(button, isDown: false, x: point.x, y: point.y))
    }

    /// Where a gesture acts: the pointer in trackpad mode, under the fingers otherwise.
    private func target(_ recognizer: UIGestureRecognizer) -> (x: Float, y: Float)? {
        if isTrackpad { return (pointer.x, pointer.y) }
        guard let point = point(recognizer) else { return nil }
        pointer = TrackpadPointer(x: point.x, y: point.y)
        return point
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func point(_ recognizer: UIGestureRecognizer, clamped: Bool = false) -> (x: Float, y: Float)? {
        VideoGeometry.normalized(recognizer.location(in: content), videoSize: videoSize, in: content.bounds.size,
                                 clamped: clamped)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let point = target(recognizer) else { return }
        click(.left, at: point)
    }

    @objc private func rightTapped(_ recognizer: UITapGestureRecognizer) {
        guard let point = target(recognizer) else { return }
        click(.right, at: point)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard isTrackpad else {
            guard recognizer.state == .began, let point = target(recognizer) else { return }
            return click(.right, at: point)
        }
        // Press and hold, then drag: the button stays down until the finger lifts.
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            lastPressLocation = location
            onInput(.button(.left, isDown: true, x: pointer.x, y: pointer.y))
            if UserDefaults.standard.object(forKey: SettingsKey.haptics) as? Bool ?? true {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        case .changed:
            movePointer(by: CGPoint(x: location.x - lastPressLocation.x, y: location.y - lastPressLocation.y))
            lastPressLocation = location
        case .ended, .cancelled, .failed:
            onInput(.button(.left, isDown: false, x: pointer.x, y: pointer.y))
        default:
            break
        }
    }

    @objc private func swiped(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let translation = recognizer.translation(in: self)
        guard let gesture = MacGesture(swipe: CGVector(dx: translation.x, dy: translation.y)) else { return }
        onKey(MacKey.control, true, .control)
        onTapKey(gesture.key, gesture.modifiers)
        onKey(MacKey.control, false, [])
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        if isTrackpad {
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            if [.began, .changed].contains(recognizer.state) { movePointer(by: delta) }
            return
        }
        guard let (x, y) = point(recognizer, clamped: true) else { return }
        pointer = TrackpadPointer(x: x, y: y)
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
