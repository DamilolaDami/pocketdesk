import CoreGraphics
import Testing
@testable import PDClientCore

struct TrackpadTests {
    let picture = CGSize(width: 400, height: 250)

    @Test func slowMovesArePrecise() {
        var pointer = TrackpadPointer()
        pointer.move(by: CGVector(dx: 1, dy: 0), pictureSize: picture)
        // 1 point at ~1.2x over 400 points.
        #expect(abs(pointer.x - (0.5 + 1.45 / 400)) < 0.000_1)
        #expect(pointer.y == 0.5)
    }

    @Test func fastMovesGoFurtherPerPoint() {
        var slow = TrackpadPointer(), fast = TrackpadPointer()
        for _ in 0..<10 { slow.move(by: CGVector(dx: 2, dy: 0), pictureSize: picture) }
        fast.move(by: CGVector(dx: 20, dy: 0), pictureSize: picture)
        #expect(fast.x - 0.5 > 2 * (slow.x - 0.5))
    }

    @Test func zoomingInGivesFinerControl() {
        var whole = TrackpadPointer(), zoomed = TrackpadPointer()
        whole.move(by: CGVector(dx: 5, dy: 5), pictureSize: picture)
        zoomed.move(by: CGVector(dx: 5, dy: 5), pictureSize: CGSize(width: 800, height: 500))
        #expect(abs((zoomed.x - 0.5) * 2 - (whole.x - 0.5)) < 0.000_1)
    }

    @Test func pointerStaysOnTheScreen() {
        var pointer = TrackpadPointer(x: 0.95, y: 0.05)
        pointer.move(by: CGVector(dx: 500, dy: -500), pictureSize: picture)
        #expect(pointer == TrackpadPointer(x: 1, y: 0))
    }

    @Test func threeFingerSwipes() {
        #expect(MacGesture(swipe: CGVector(dx: 5, dy: -80)) == .missionControl)
        #expect(MacGesture(swipe: CGVector(dx: -10, dy: 60)) == .appExpose)
        #expect(MacGesture(swipe: CGVector(dx: -90, dy: 20)) == .spaceRight)
        #expect(MacGesture(swipe: CGVector(dx: 90, dy: -20)) == .spaceLeft)
        #expect(MacGesture(swipe: CGVector(dx: 20, dy: -30)) == nil)
        #expect(MacGesture.missionControl.key == MacKey.up)
        #expect(MacGesture.spaceRight.modifiers.contains(.control))
    }

    @Test func zoomedViewFollowsThePointer() {
        var viewport = ZoomViewport(viewSize: CGSize(width: 400, height: 800))
        viewport.zoom(to: 2, about: .zero)
        #expect(viewport.offset == .zero)
        // Shown at (380, 100): past the right margin of 40, so the view moves 20 left.
        viewport.reveal(CGPoint(x: 190, y: 50), margin: 40)
        #expect(viewport.offset == CGPoint(x: -20, y: 0))
        #expect(viewport.screenPoint(CGPoint(x: 190, y: 50)) == CGPoint(x: 360, y: 100))
        // Already well inside: nothing moves.
        viewport.reveal(CGPoint(x: 100, y: 200), margin: 40)
        #expect(viewport.offset == CGPoint(x: -20, y: 0))
        // Never past the picture's edges.
        viewport.reveal(CGPoint(x: 400, y: 800), margin: 40)
        #expect(viewport.offset == CGPoint(x: -400, y: -800))
    }

    @Test func revealDoesNothingUnzoomed() {
        var viewport = ZoomViewport(viewSize: CGSize(width: 400, height: 800))
        viewport.reveal(CGPoint(x: 399, y: 799), margin: 40)
        #expect(viewport.offset == .zero)
    }
}
