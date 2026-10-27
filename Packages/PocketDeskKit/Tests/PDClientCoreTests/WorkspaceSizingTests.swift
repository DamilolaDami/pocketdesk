import Testing
import PDProtocol
@testable import PDClientCore

struct WorkspaceSizingTests {
    @Test func logicalDesktopBackingAndStreamCeilingAreIndependent() {
        var sizing = WorkspaceSizing()
        sizing.desktop = .largerText; sizing.scale = 2; sizing.refreshRate = 30
        #expect(sizing.mode == .init(width: 1024, height: 768, scale: 2, refreshRate: 30))
        #expect(sizing.mode.pixelWidth == 2048)
        sizing.portrait = true
        #expect(sizing.mode == .init(width: 768, height: 1024, scale: 2, refreshRate: 30))
        var restored = WorkspaceSizing()
        restored.accept(sizing.mode)
        #expect(restored == sizing)
    }
    @Test func rotationIsOptInAndRepeatedSceneLayoutsDoNotRequestChanges() {
        var sizing = WorkspaceSizing()
        let result1 = !sizing.observeOrientation(portrait: true); #expect(result1)
        #expect(!sizing.portrait)
        sizing.followsRotation = true
        let result2 = sizing.observeOrientation(portrait: true); #expect(result2)
        for _ in 0..<30 { let result3 = !sizing.observeOrientation(portrait: true); #expect(result3) }
        #expect(sizing.mode == .standard.rotated)
        let result4 = sizing.observeOrientation(portrait: false); #expect(result4)
        #expect(sizing.mode == .init(width: 1280, height: 800, scale: 2))
    }
}
