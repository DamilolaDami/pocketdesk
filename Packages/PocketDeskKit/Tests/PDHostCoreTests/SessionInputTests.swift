#if os(macOS)
import CoreGraphics
import Synchronization
import Testing
import PDProtocol
import PDTransport
@testable import PDHostCore

extension HostServiceTests {
    @Test func eachConnectionGetsAnIndependentInputCoordinateFrame() async throws {
        try pinPhone()
        let sinks = Mutex<[RecordingInputSink]>([])
        let port = try await startService(makeSessionInput: {
            let sink = RecordingInputSink()
            sinks.withLock { $0.append(sink) }
            return sink
        })
        for id: UInt32 in [1, 2] {
            try await connect(port: port) { session in
                var control = PhoneControl(session)
                try await session.send(.hello(Hello(deviceName: "Test iPhone", viewport: Viewport(width: 402, height: 874, scale: 3))))
                guard case .helloAck? = try await control.next(), case .streamConfig? = try await control.next() else { throw TransportError.closed }
                if id == 2 {
                    try await session.send(.selectDisplay(id))
                    guard case .streamConfig? = try await control.next() else { throw TransportError.closed }
                }
                try await session.send(.bye(reason: "done"))

            }
        }
        let inputs = sinks.withLock { $0 }
        #expect(inputs.count == 2)
        #expect(inputs[0] !== inputs[1])
        #expect(inputs[0].sourceFrames.last == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(inputs[1].sourceFrames.last == CGRect(x: -2560, y: 0, width: 2560, height: 1440))
    }
}
#endif
