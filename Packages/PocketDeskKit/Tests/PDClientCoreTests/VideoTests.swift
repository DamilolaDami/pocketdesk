import CoreGraphics
import CoreMedia
import CoreVideo
import Testing
import VideoToolbox
import PDProtocol
@testable import PDClientCore
@testable import PDHostCore

/// Real HEVC from the host's encoder, assembled the way the phone does it.
@Suite(.timeLimit(.minutes(1)))
struct FrameAssemblerTests {
    func encodedFrames(count: Int, width: Int = 640, height: Int = 360) async throws -> [EncodedFrame] {
        let encoder = try HEVCEncoder(width: width, height: height, fps: 30, bitrateKbps: 2_000)
        for index in 0..<count {
            encoder.encode(flatFrame(width: width, height: height, luma: UInt8(index * 20)),
                           presentationTime: CMTime(value: Int64(index), timescale: 30))
        }
        encoder.flush()
        var frames: [EncodedFrame] = []
        for await frame in encoder.frames {
            frames.append(frame)
            if frames.count == count { break }
        }
        return frames
    }

    func header(_ frame: EncodedFrame, id: UInt32, generation: UInt32 = 1) -> VideoFrameHeader {
        VideoFrameHeader(frameID: id, captureTimeMicros: frame.presentationTimeMicros,
                         flags: frame.isKeyframe ? [.keyframe, .parameterSets] : [],
                         payloadLength: UInt32(frame.payload.count), sourceGeneration: generation)
    }

    @Test func assembledFramesDecodeToTheEncodedSize() async throws {
        let frames = try await encodedFrames(count: 5)
        var assembler = FrameAssembler()
        var samples: [CMSampleBuffer] = []
        for (index, frame) in frames.enumerated() {
            samples.append(try #require(try assembler.assemble(header: header(frame, id: UInt32(index)), payload: frame.payload)))
        }
        let format = try #require(assembler.format)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 640 && dimensions.height == 360)

        let decoded = try decode(samples, format: format)
        #expect(decoded.count == 5)
        #expect(decoded.allSatisfy { CVPixelBufferGetWidth($0) == 640 && CVPixelBufferGetHeight($0) == 360 })
    }

    @Test func dropsDeltasUntilAKeyframe() async throws {
        let frames = try await encodedFrames(count: 3)
        var assembler = FrameAssembler()
        // Join mid-stream: the delta can't be decoded without its keyframe.
        #expect(try assembler.assemble(header: header(frames[1], id: 1), payload: frames[1].payload) == nil)
        #expect(assembler.needsKeyframe)
        #expect(try assembler.assemble(header: header(frames[0], id: 0), payload: frames[0].payload) != nil)
        #expect(!assembler.needsKeyframe)
    }

    @Test func newSourceGenerationWaitsForItsKeyframe() async throws {
        let frames = try await encodedFrames(count: 2)
        var assembler = FrameAssembler()
        _ = try assembler.assemble(header: header(frames[0], id: 0, generation: 1), payload: frames[0].payload)
        // A delta tagged with the next generation (stale encoder state) is dropped.
        #expect(try assembler.assemble(header: header(frames[1], id: 1, generation: 2), payload: frames[1].payload) == nil)
        #expect(try assembler.assemble(header: header(frames[0], id: 2, generation: 2), payload: frames[0].payload) != nil)
    }

    @Test func rejectsKeyframeWithoutParameterSets() {
        var assembler = FrameAssembler()
        var payload: [UInt8] = []
        NALUnits.append([0x26, 0x01, 0xAF], to: &payload) // an IDR slice, no VPS/SPS/PPS
        let header = VideoFrameHeader(frameID: 0, captureTimeMicros: 0, flags: [.keyframe, .parameterSets],
                                      payloadLength: UInt32(payload.count), sourceGeneration: 1)
        #expect(throws: AssemblyError.missingParameterSets) { try assembler.assemble(header: header, payload: payload) }
    }

    private func decode(_ samples: [CMSampleBuffer], format: CMVideoFormatDescription) throws -> [CVPixelBuffer] {
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session
        else { throw AssemblyError.formatDescription(-1) }
        defer { VTDecompressionSessionInvalidate(session) }

        let collected = Collected()
        for sample in samples {
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image { collected.append(image) }
            }
            #expect(status == noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return collected.images
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _images: [CVPixelBuffer] = []
    var images: [CVPixelBuffer] { lock.withLock { _images } }
    func append(_ image: CVPixelBuffer) { lock.withLock { _images.append(image) } }
}

func flatFrame(width: Int, height: Int, luma: UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)!, Int32(plane == 0 ? luma : 128),
               CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

@Suite struct VideoGeometryTests {
    let video = CGSize(width: 1920, height: 1080)
    let portraitPhone = CGSize(width: 402, height: 874)

    @Test func letterboxesWideVideoInPortrait() {
        let rect = VideoGeometry.contentRect(videoSize: video, in: portraitPhone)
        #expect(rect.width == 402)
        #expect(abs(rect.height - 226.125) < 0.001)
        #expect(abs(rect.midY - 437) < 0.001)
    }

    @Test func mapsCenterAndCorners() throws {
        let rect = VideoGeometry.contentRect(videoSize: video, in: portraitPhone)
        let center = try #require(VideoGeometry.normalized(CGPoint(x: 201, y: 437), videoSize: video, in: portraitPhone))
        #expect(abs(center.x - 0.5) < 0.001 && abs(center.y - 0.5) < 0.001)
        let topLeft = try #require(VideoGeometry.normalized(rect.origin, videoSize: video, in: portraitPhone))
        #expect(topLeft.x == 0 && topLeft.y == 0)
    }

    @Test func letterboxTouchesAreIgnoredUnlessClamped() throws {
        let above = CGPoint(x: 100, y: 10)
        #expect(VideoGeometry.normalized(above, videoSize: video, in: portraitPhone) == nil)
        let clamped = try #require(VideoGeometry.normalized(above, videoSize: video, in: portraitPhone, clamped: true))
        #expect(clamped.y == 0)
    }
}
