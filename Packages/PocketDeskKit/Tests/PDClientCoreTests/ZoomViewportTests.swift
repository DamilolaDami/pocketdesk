import CoreGraphics
import Testing
@testable import PDClientCore

struct ZoomViewportTests {
    let size = CGSize(width: 400, height: 800)

    @Test func unzoomedPanScrollsTheMacWithAllOfIt() {
        var viewport = ZoomViewport(viewSize: size)
        let rest = viewport.pan(by: CGVector(dx: 30, dy: -50))
        #expect(rest == CGVector(dx: 30, dy: -50))
        #expect(viewport.offset == .zero)
    }

    @Test func zoomedPanMovesTheViewFirst() {
        var viewport = ZoomViewport(viewSize: size)
        viewport.zoom(to: 2, about: CGPoint(x: 200, y: 400))
        #expect(viewport.offset == CGPoint(x: -200, y: -400))
        let rest = viewport.pan(by: CGVector(dx: 50, dy: -100))
        #expect(rest == CGVector(dx: 0, dy: 0))
        #expect(viewport.offset == CGPoint(x: -150, y: -500))
    }

    @Test func zoomedPanPastTheEdgeScrollsTheMacWithTheRest() {
        var viewport = ZoomViewport(viewSize: size)
        viewport.zoom(to: 2, about: CGPoint(x: 200, y: 400))
        // 400 points to the top edge, 400 to the bottom one.
        let rest = viewport.pan(by: CGVector(dx: 0, dy: 450))
        #expect(rest == CGVector(dx: 0, dy: 50))
        #expect(viewport.offset.y == 0)
        #expect(viewport.pan(by: CGVector(dx: 0, dy: -900)) == CGVector(dx: 0, dy: -100))
        #expect(viewport.offset.y == -800)
    }

    @Test func zoomKeepsTheAnchorOverTheSameSpot() {
        var viewport = ZoomViewport(viewSize: size)
        let anchor = CGPoint(x: 100, y: 300)
        viewport.zoom(to: 3, about: anchor)
        // The picture's spot under the anchor is (anchor - offset) / zoom: still the anchor.
        #expect(viewport.offset == CGPoint(x: -200, y: -600))
        #expect(viewport.zoom == 3)
    }

    @Test func zoomIsBounded() {
        var viewport = ZoomViewport(viewSize: size)
        viewport.scale(by: 0.5, about: .zero)
        #expect(viewport.zoom == 1)
        viewport.scale(by: 100, about: .zero)
        #expect(viewport.zoom == ZoomViewport.maxZoom)
    }

    @Test func toggleZoomsInThenBackOut() {
        var viewport = ZoomViewport(viewSize: size)
        viewport.toggle(about: CGPoint(x: 200, y: 400))
        #expect(viewport.zoom == ZoomViewport.comfortableZoom)
        viewport.toggle(about: CGPoint(x: 10, y: 10))
        #expect(viewport.zoom == 1)
        #expect(viewport.offset == .zero)
    }

    @Test func shrinkingTheViewKeepsThePictureCovered() {
        var viewport = ZoomViewport(viewSize: size)
        viewport.zoom(to: 2, about: CGPoint(x: 400, y: 800))
        #expect(viewport.offset == CGPoint(x: -400, y: -800))
        viewport.viewSize = CGSize(width: 200, height: 400)
        #expect(viewport.offset == CGPoint(x: -200, y: -400))
    }
}
