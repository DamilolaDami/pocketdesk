/// Pointer and keyboard input sent client → host.
///
/// Encoded as a fixed little-endian binary layout so it fits in a single QUIC datagram
/// (pointer moves are latest-wins; a lost one is replaced by the next). Coordinates are
/// normalized 0...1 within the streamed source, so the client never needs host pixel sizes.
public enum InputEvent: Sendable, Equatable {
    indirect case scoped(generation: UInt32, event: InputEvent)
    case pointerMove(x: Float, y: Float)
    case button(MouseButton, isDown: Bool, x: Float, y: Float)
    case scroll(dx: Float, dy: Float)
    /// macOS virtual key code (`kVK_*`) plus `CGEventFlags` modifier bits.
    case key(code: UInt16, isDown: Bool, modifiers: UInt32)
}

public enum MouseButton: UInt8, Sendable {
    case left = 0, right = 1, middle = 2
}

extension InputEvent {
    private enum Tag: UInt8 {
        case pointerMove = 1, button = 2, scroll = 3, key = 4, scoped = 5
    }

    /// Largest encoded size. Well under any QUIC datagram limit.
    public static let maxEncodedSize = 5 + 1 + 1 + 1 + 4 + 4

    public func encode(into bytes: inout [UInt8]) {
        switch self {
        case .scoped(let generation, let event):
            bytes.append(Tag.scoped.rawValue)
            bytes.appendLE(generation)
            event.encode(into: &bytes)
        case let .pointerMove(x, y):
            bytes.append(Tag.pointerMove.rawValue)
            bytes.appendLE(x.bitPattern)
            bytes.appendLE(y.bitPattern)
        case let .button(button, isDown, x, y):
            bytes.append(Tag.button.rawValue)
            bytes.append(button.rawValue)
            bytes.append(isDown ? 1 : 0)
            bytes.appendLE(x.bitPattern)
            bytes.appendLE(y.bitPattern)
        case let .scroll(dx, dy):
            bytes.append(Tag.scroll.rawValue)
            bytes.appendLE(dx.bitPattern)
            bytes.appendLE(dy.bitPattern)
        case let .key(code, isDown, modifiers):
            bytes.append(Tag.key.rawValue)
            bytes.appendLE(code)
            bytes.append(isDown ? 1 : 0)
            bytes.appendLE(modifiers)
        }
    }

    public func encoded() -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Self.maxEncodedSize)
        encode(into: &bytes)
        return bytes
    }

    public init(decoding bytes: some Collection<UInt8>) throws(WireError) {
        var reader = ByteReader(bytes)
        guard let tag = Tag(rawValue: try reader.u8()) else { throw .unknownTag }
        switch tag {
        case .scoped:
            guard bytes.count <= Self.maxEncodedSize else { throw .invalidValue }
            let generation = try reader.u32()
            let payload = bytes.dropFirst(5)
            guard payload.first != Tag.scoped.rawValue else { throw .invalidValue }
            self = .scoped(generation: generation, event: try InputEvent(decoding: payload))
        case .pointerMove:
            self = .pointerMove(x: Float(bitPattern: try reader.u32()), y: Float(bitPattern: try reader.u32()))
        case .button:
            guard let button = MouseButton(rawValue: try reader.u8()) else { throw .invalidValue }
            let isDown = try reader.u8() != 0
            self = .button(button, isDown: isDown,
                           x: Float(bitPattern: try reader.u32()), y: Float(bitPattern: try reader.u32()))
        case .scroll:
            self = .scroll(dx: Float(bitPattern: try reader.u32()), dy: Float(bitPattern: try reader.u32()))
        case .key:
            let code = try reader.u16()
            let isDown = try reader.u8() != 0
            self = .key(code: code, isDown: isDown, modifiers: try reader.u32())
        }
    }
}
