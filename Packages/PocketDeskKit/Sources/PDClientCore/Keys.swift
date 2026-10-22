import Foundation
import PDProtocol

/// macOS virtual key codes (`kVK_*` from Carbon's Events.h) the phone sends.
public enum MacKey {
    public static let `return`: UInt16 = 0x24
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    public static let delete: UInt16 = 0x33
    public static let escape: UInt16 = 0x35
    public static let command: UInt16 = 0x37
    public static let shift: UInt16 = 0x38
    public static let option: UInt16 = 0x3A
    public static let control: UInt16 = 0x3B
    public static let rightCommand: UInt16 = 0x36
    public static let rightShift: UInt16 = 0x3C
    public static let rightOption: UInt16 = 0x3D
    public static let rightControl: UInt16 = 0x3E
    public static let function: UInt16 = 0x3F
    public static let home: UInt16 = 0x73
    public static let pageUp: UInt16 = 0x74
    public static let forwardDelete: UInt16 = 0x75
    public static let end: UInt16 = 0x77
    public static let pageDown: UInt16 = 0x79
    public static let left: UInt16 = 0x7B
    public static let right: UInt16 = 0x7C
    public static let down: UInt16 = 0x7D
    public static let up: UInt16 = 0x7E
    /// F1 through F12, in order.
    public static let functionKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
}

/// `CGEventFlags` modifier bits. iOS's `UIKeyModifierFlags` uses the same bit for each, since
/// both come from NeXTSTEP's event flags.
public struct MacModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let capsLock = MacModifiers(rawValue: 1 << 16)
    public static let shift = MacModifiers(rawValue: 1 << 17)
    public static let control = MacModifiers(rawValue: 1 << 18)
    public static let option = MacModifiers(rawValue: 1 << 19)
    public static let command = MacModifiers(rawValue: 1 << 20)
    public static let numericPad = MacModifiers(rawValue: 1 << 21)
    public static let function = MacModifiers(rawValue: 1 << 23)

    /// The bits worth passing on from a `UIKeyModifierFlags` raw value.
    public init(phoneFlags: Int) {
        self = MacModifiers(rawValue: UInt32(truncatingIfNeeded: phoneFlags))
            .intersection([.capsLock, .shift, .control, .option, .command, .numericPad])
    }
}

public enum KeyMap {
    /// A hardware keyboard key (USB HID usage, as `UIKey.keyCode` reports it) as the key in
    /// the same place on a Mac keyboard. Mac key codes are positional too, so layouts match
    /// as long as the phone and the Mac use the same one.
    public static func macKey(hidUsage: Int) -> UInt16? {
        if let code = hid[hidUsage] { return code }
        switch hidUsage {
        case 0x3A...0x45: return MacKey.functionKeys[hidUsage - 0x3A]  // F1–F12
        case 0x68...0x6F: return f13to20[hidUsage - 0x68]
        default: return nil
        }
    }

    /// The modifier a modifier key holds down, so its own down event carries it.
    public static func modifier(forMacKey code: UInt16) -> MacModifiers? {
        switch code {
        case MacKey.command, MacKey.rightCommand: .command
        case MacKey.shift, MacKey.rightShift: .shift
        case MacKey.option, MacKey.rightOption: .option
        case MacKey.control, MacKey.rightControl: .control
        case MacKey.function: .function
        default: nil
        }
    }

    /// The key that types `character` on a US keyboard, and whether it needs shift. Used
    /// when a sticky modifier turns on-screen typing into shortcuts (⌘ then "c" → ⌘C).
    public static func stroke(for character: Character) -> (code: UInt16, shift: Bool)? {
        if let code = unshifted[character] { return (code, false) }
        if let code = shifted[character] { return (code, true) }
        if character.isUppercase, let lower = character.lowercased().first, let code = unshifted[lower] {
            return (code, true)
        }
        return nil
    }

    private static let hid: [Int: UInt16] = [
        0x04: 0x00, 0x05: 0x0B, 0x06: 0x08, 0x07: 0x02, 0x08: 0x0E, 0x09: 0x03, 0x0A: 0x05,  // a–g
        0x0B: 0x04, 0x0C: 0x22, 0x0D: 0x26, 0x0E: 0x28, 0x0F: 0x25, 0x10: 0x2E, 0x11: 0x2D,  // h–n
        0x12: 0x1F, 0x13: 0x23, 0x14: 0x0C, 0x15: 0x0F, 0x16: 0x01, 0x17: 0x11, 0x18: 0x20,  // o–u
        0x19: 0x09, 0x1A: 0x0D, 0x1B: 0x07, 0x1C: 0x10, 0x1D: 0x06,                          // v–z
        0x1E: 0x12, 0x1F: 0x13, 0x20: 0x14, 0x21: 0x15, 0x22: 0x17, 0x23: 0x16, 0x24: 0x1A,  // 1–7
        0x25: 0x1C, 0x26: 0x19, 0x27: 0x1D,                                                  // 8, 9, 0
        0x28: MacKey.return, 0x29: MacKey.escape, 0x2A: MacKey.delete, 0x2B: MacKey.tab, 0x2C: MacKey.space,
        0x2D: 0x1B, 0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, 0x31: 0x2A, 0x32: 0x2A,              // - = [ ] \ #
        0x33: 0x29, 0x34: 0x27, 0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C,              // ; ' ` , . /
        0x49: 0x72, 0x4A: MacKey.home, 0x4B: MacKey.pageUp, 0x4C: MacKey.forwardDelete,       // insert → help
        0x4D: MacKey.end, 0x4E: MacKey.pageDown,
        0x4F: MacKey.right, 0x50: MacKey.left, 0x51: MacKey.down, 0x52: MacKey.up,
        0x53: 0x47, 0x54: 0x4B, 0x55: 0x43, 0x56: 0x4E, 0x57: 0x45, 0x58: 0x4C,              // keypad
        0x59: 0x53, 0x5A: 0x54, 0x5B: 0x55, 0x5C: 0x56, 0x5D: 0x57, 0x5E: 0x58, 0x5F: 0x59,
        0x60: 0x5B, 0x61: 0x5C, 0x62: 0x52, 0x63: 0x41, 0x67: 0x51,
        0x64: 0x0A,                                                                          // ISO §
        0x87: 0x5E, 0x89: 0x5D, 0x90: 0x68, 0x91: 0x66,                                      // JIS
        0xE0: MacKey.control, 0xE1: MacKey.shift, 0xE2: MacKey.option, 0xE3: MacKey.command,
        0xE4: MacKey.rightControl, 0xE5: MacKey.rightShift, 0xE6: MacKey.rightOption, 0xE7: MacKey.rightCommand,
    ]

    private static let f13to20: [UInt16] = [0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A]

    private static let unshifted: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        " ": MacKey.space, "\t": MacKey.tab, "\n": MacKey.return,
    ]

    private static let shifted: [Character: UInt16] = [
        "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "^": 0x16, "%": 0x17, "+": 0x18, "(": 0x19,
        "&": 0x1A, "_": 0x1B, "*": 0x1C, ")": 0x1D, "}": 0x1E, "{": 0x21, "\"": 0x27, ":": 0x29,
        "|": 0x2A, "<": 0x2B, "?": 0x2C, ">": 0x2F, "~": 0x32,
    ]
}

/// The special-keys bar's ⌃ ⌥ ⇧ ⌘: tap one and it applies to the next key; tap it twice
/// quickly and it stays on until tapped again (like Shift and Caps Lock on the iOS keyboard).
public struct StickyModifiers: Equatable, Sendable {
    public enum State: Sendable { case off, once, locked }

    public private(set) var states: [MacModifiers: State] = [:]
    private var lastTap: (modifier: MacModifiers, at: ContinuousClock.Instant)?
    /// Two taps within this make a lock.
    public static let doubleTap: Duration = .milliseconds(400)

    public init() {}

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.states == rhs.states }

    public func state(_ modifier: MacModifiers) -> State { states[modifier] ?? .off }

    /// Everything currently held.
    public var active: MacModifiers {
        states.reduce(into: []) { result, entry in if entry.value != .off { result.formUnion(entry.key) } }
    }

    public mutating func tap(_ modifier: MacModifiers, at now: ContinuousClock.Instant = .now) {
        let quick = lastTap.map { $0.modifier == modifier && now - $0.at < Self.doubleTap } ?? false
        switch state(modifier) {
        case .off: states[modifier] = .once
        case .once: states[modifier] = quick ? .locked : .off
        case .locked: states[modifier] = .off
        }
        lastTap = (modifier, now)
    }

    /// What the next key is pressed with; one-shot modifiers are used up.
    public mutating func consume() -> MacModifiers {
        let held = active
        for (modifier, state) in states where state == .once { states[modifier] = .off }
        return held
    }

    public mutating func reset() {
        states = [:]
        lastTap = nil
    }
}
