import Foundation
import Testing
@testable import PDProtocol

struct SourceGenerationTests {
    @Test func scopeRoundTripAndNestedScopeRejection() throws {
        let input = InputEvent.scoped(generation: 42, event: .button(.left, isDown: true, x: 0.2, y: 0.8))
        #expect(input.encoded().count == InputEvent.maxEncodedSize)
        #expect(try InputEvent(decoding: input.encoded()) == input)
        let nested = InputEvent.scoped(generation: 43, event: input)
        #expect(throws: WireError.invalidValue) { try InputEvent(decoding: nested.encoded()) }
        #expect(throws: WireError.truncated) { try InputEvent(decoding: [5, 1]) }
    }
    @Test func oldConfigsAndKeyframesCannotEnableInputForANewMode() {
        var epoch = SourceInputEpoch()
        let result1 = epoch.configure(UInt32.max); #expect(result1)
        #expect(!epoch.ready)
        let result2 = epoch.decodedKeyframe(UInt32.max); #expect(result2)
        let result3 = epoch.configure(0); #expect(result3) // Wraparound is a new generation.
        #expect(!epoch.accepts(UInt32.max))
        let result4 = !epoch.configure(UInt32.max); #expect(result4)
        let result5 = !epoch.decodedKeyframe(UInt32.max); #expect(result5)
        let result6 = epoch.decodedKeyframe(0); #expect(result6)
        #expect(epoch.accepts(0))
        let result7 = !epoch.configure(0); #expect(result7)
        #expect(epoch.ready) // A duplicate config does not suspend an already working picture.
    }
    @Test func modesAreABoundedCartesianSetAndWireMessagesRoundTrip() throws {
        #expect(VirtualDisplayMode.supported.count == 18)
        #expect(Set(VirtualDisplayMode.supported).count == 18)
        for mode in VirtualDisplayMode.supported {
            #expect(mode.isValid && mode.pixelWidth * mode.pixelHeight <= 4_915_200)
        }
        #expect(!VirtualDisplayMode(width: Int.max, height: 800, scale: Int.max).isValid)
        let config = StreamConfig(codec: .hevc, width: 1280, height: 800, fps: 30, bitrateKbps: 4000, sourceGeneration: 9)
        for message in [ControlMessage.configureVirtualDisplay(.init(leaseID: UUID(), mode: .init(width: 800, height: 1280, scale: 2, refreshRate: 30))),
                        .streamConfig(config), .setViewport(.init(width: 402, height: 874, scale: 3)),
                        .sourceReady(9), .sourceText(generation: 9, text: "typed")] {
            #expect(try JSONDecoder().decode(ControlMessage.self, from: JSONEncoder().encode(message)) == message)
        }
    }
}
