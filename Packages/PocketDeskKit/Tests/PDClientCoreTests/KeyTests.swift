import PDClientCore
import PDProtocol
import Testing

@Suite struct KeyMapTests {
    @Test func hardwareKeysLandOnTheSameMacKeys() {
        #expect(KeyMap.macKey(hidUsage: 0x04) == 0x00)            // A
        #expect(KeyMap.macKey(hidUsage: 0x06) == 0x08)            // C
        #expect(KeyMap.macKey(hidUsage: 0x27) == 0x1D)            // 0
        #expect(KeyMap.macKey(hidUsage: 0x2B) == MacKey.tab)
        #expect(KeyMap.macKey(hidUsage: 0x29) == MacKey.escape)
        #expect(KeyMap.macKey(hidUsage: 0x50) == MacKey.left)
        #expect(KeyMap.macKey(hidUsage: 0x3A) == 0x7A)            // F1
        #expect(KeyMap.macKey(hidUsage: 0x45) == 0x6F)            // F12
        #expect(KeyMap.macKey(hidUsage: 0xE3) == MacKey.command)
        #expect(KeyMap.macKey(hidUsage: 0x39) == nil)             // Caps Lock travels as a flag
    }

    @Test func everyLetterAndDigitHasADistinctKey() {
        let codes = (0x04...0x27).compactMap { KeyMap.macKey(hidUsage: $0) }
        #expect(codes.count == 36)
        #expect(Set(codes).count == 36)
    }

    @Test func charactersBecomeStrokes() {
        #expect(KeyMap.stroke(for: "c")! == (0x08, false))
        #expect(KeyMap.stroke(for: "C")! == (0x08, true))
        #expect(KeyMap.stroke(for: "?")! == (0x2C, true))
        #expect(KeyMap.stroke(for: " ")! == (MacKey.space, false))
        #expect(KeyMap.stroke(for: "é") == nil)
    }

    @Test func phoneFlagsShareTheMacBits() {
        // UIKeyModifierFlags: .shift = 1 << 17, .command = 1 << 20.
        #expect(MacModifiers(phoneFlags: 1 << 17 | 1 << 20) == [.shift, .command])
        #expect(MacModifiers(phoneFlags: 1 << 30) == [])
        #expect(KeyMap.modifier(forMacKey: MacKey.rightOption) == .option)
        #expect(KeyMap.modifier(forMacKey: MacKey.tab) == nil)
    }
}

@Suite struct StickyModifierTests {
    private let start = ContinuousClock.now

    @Test func oneTapAppliesToTheNextKeyOnly() {
        var sticky = StickyModifiers()
        sticky.tap(.command, at: start)
        sticky.tap(.shift, at: start + .seconds(1))
        #expect(sticky.consume() == [.command, .shift])
        #expect(sticky.consume() == [])
    }

    @Test func doubleTapLocksUntilTappedAgain() {
        var sticky = StickyModifiers()
        sticky.tap(.option, at: start)
        sticky.tap(.option, at: start + .milliseconds(200))
        #expect(sticky.state(.option) == .locked)
        #expect(sticky.consume() == .option)
        #expect(sticky.consume() == .option)
        sticky.tap(.option, at: start + .seconds(2))
        #expect(sticky.active == [])
    }

    @Test func slowSecondTapTurnsItOff() {
        var sticky = StickyModifiers()
        sticky.tap(.control, at: start)
        sticky.tap(.control, at: start + .seconds(1))
        #expect(sticky.state(.control) == .off)
    }
}
