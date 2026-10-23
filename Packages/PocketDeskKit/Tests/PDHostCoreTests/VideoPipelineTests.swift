#if os(macOS)
// Uses the macOS host engines (encoder, capture, HostService).
import CoreGraphics
import CoreMedia
import Testing
import PDProtocol
@testable import PDHostCore

@Suite struct StreamSizingTests {
    let iPhone = Viewport(width: 402, height: 874, scale: 3) // 1206 × 2622 px

    @Test func landscapeDisplayFitsPhoneRotated() {
        // A MacBook Pro display is taller than the phone's 2622 × 1206 landscape box allows.
        let size = StreamSizing.fit(sourceWidth: 3024, sourceHeight: 1964, into: iPhone, zoomHeadroom: 1)
        #expect(size.height == 1206)
        #expect(size.width <= 2622)
        #expect(size.width % 2 == 0 && size.height % 2 == 0)
    }

    @Test func zoomHeadroomStreamsSharperThanTheScreen() {
        let size = StreamSizing.fit(sourceWidth: 3024, sourceHeight: 1964, into: iPhone)
        #expect(size.height == 1808) // 1206 × 1.5, rounded down to even
        #expect(size.width <= 3024)
    }

    @Test func portraitWindowFitsPhonePortrait() {
        let size = StreamSizing.fit(sourceWidth: 1600, sourceHeight: 3000, into: iPhone, zoomHeadroom: 1)
        #expect(size.height <= 2622 && size.width <= 1206)
    }

    @Test func neverUpscales() {
        let size = StreamSizing.fit(sourceWidth: 800, sourceHeight: 600, into: iPhone)
        #expect(size == (800, 600))
    }

    @Test func capsTotalPixels() {
        let size = StreamSizing.fit(sourceWidth: 6016, sourceHeight: 3384,
                                    into: Viewport(width: 6016, height: 3384, scale: 1), maxPixels: 3840 * 2160)
        #expect(size.width * size.height <= 3840 * 2160)
    }

    @Test func bitrateIsClamped() {
        #expect(StreamSizing.bitrateKbps(width: 100, height: 100, fps: 60) == 4_000)
        #expect(StreamSizing.bitrateKbps(width: 3840, height: 2160, fps: 60) == 50_000)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HEVCEncoderTests {
    @Test func firstFrameIsDecodableKeyframeThenDeltas() async throws {
        let encoder = try await HEVCEncoder.make(width: 640, height: 360, fps: 30, bitrateKbps: 2_000)
        for index in 0..<10 {
            encoder.encode(makePixelBuffer(width: 640, height: 360, luma: UInt8(index * 20)),
                           presentationTime: CMTime(value: Int64(index), timescale: 30))
        }
        encoder.flush()

        var frames: [EncodedFrame] = []
        for await frame in encoder.frames {
            frames.append(frame)
            if frames.count == 10 { break }
        }

        #expect(frames.count == 10)
        let keyframe = try #require(frames.first)
        #expect(keyframe.isKeyframe)
        #expect(frames.dropFirst().allSatisfy { !$0.isKeyframe })

        let types = try NALUnits.split(keyframe.payload).compactMap { NALUnits.hevcType(of: $0) }
        #expect(Array(types.prefix(3)) == [32, 33, 34]) // VPS, SPS, PPS
        let dimensions = CMVideoFormatDescriptionGetDimensions(try formatDescription(fromKeyframe: keyframe.payload))
        #expect(dimensions.width == 640 && dimensions.height == 360)
    }

    @Test func requestKeyframeForcesOne() async throws {
        let encoder = try await HEVCEncoder.make(width: 640, height: 360, fps: 30, bitrateKbps: 2_000)
        for index in 0..<6 {
            if index == 4 { encoder.requestKeyframe() }
            encoder.encode(makePixelBuffer(width: 640, height: 360, luma: UInt8(index * 30)),
                           presentationTime: CMTime(value: Int64(index), timescale: 30))
        }
        encoder.flush()

        var keyframes: [Int] = []
        var index = 0
        for await frame in encoder.frames {
            if frame.isKeyframe { keyframes.append(index) }
            index += 1
            if index == 6 { break }
        }
        #expect(keyframes == [0, 4])
    }
}

/// Uses the real screen. Runs only where this process has the Screen Recording permission.
@Suite(.timeLimit(.minutes(1)), .enabled(if: CGPreflightScreenCaptureAccess()))
struct ScreenCaptureSourceTests {
    @Test func capturesMainDisplayAtRequestedSize() async throws {
        let source = ScreenCaptureSource()
        let main = try await source.resolve(nil)
        #expect(main.pixelWidth > 0 && main.pixelHeight > 0)
        #expect(!(try await source.displays()).isEmpty)

        let size = StreamSizing.fit(sourceWidth: main.pixelWidth, sourceHeight: main.pixelHeight,
                                    into: Viewport(width: 402, height: 874, scale: 1))
        let frames = try await source.start(main, width: size.width, height: size.height, fps: 30)
        var iterator = frames.makeAsyncIterator()
        let frame = try #require(await iterator.next())
        await source.stop()

        #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == size.width)
        #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == size.height)
        #expect(CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    @Test func capturesEveryConnectedDisplayByItsOwnID() async throws {
        let source = ScreenCaptureSource()
        let displays = try await source.displays()
        #expect(!displays.isEmpty)
        #expect(Set(displays.map(\.persistentID)).count == displays.count)
        do {
            for display in displays {
                let resolved = try await source.resolve(.display(display.id))
                #expect(resolved.source == .display(display.id))
                #expect(resolved.pixelWidth == display.width && resolved.pixelHeight == display.height)
                let frames = try await source.start(resolved, width: 640, height: 360, fps: 30)
                var iterator = frames.makeAsyncIterator()
                let frame = try #require(await iterator.next())
                #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == 640)
                await source.stop()
            }
        } catch {
            await source.stop()
            throw error
        }
        print("ScreenCaptureKit verified capture of \(displays.count) connected display(s).")
    }

    @Test func listsOnScreenWindows() async throws {
        let windows = try await ScreenCaptureSource().windows()
        #expect(windows.allSatisfy { $0.width >= 80 && $0.height >= 60 })
    }
}
#endif
