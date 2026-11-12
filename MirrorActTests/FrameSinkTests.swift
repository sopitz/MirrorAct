// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import XCTest
@testable import MirrorAct

/// The way frames flow through `FrameSink`: what a recording gets and when.
final class FrameSinkTests: XCTestCase {
    /// Notes what a recording would get. Like `MirrorRecorder` it keeps only frames that are
    /// later than the last one it kept.
    private final class RecordingStandIn: FrameRecording {
        private let lock = NSLock()
        private var times: [CMTime] = []
        private var buffers: [CVPixelBuffer] = []
        private var droppedCount = 0

        func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
            lock.lock()
            defer { lock.unlock() }
            if let last = times.last, time <= last {
                droppedCount += 1
                return
            }
            times.append(time)
            buffers.append(pixelBuffer)
        }

        func appendAudio(_ sampleBuffer: CMSampleBuffer) {}

        var kept: [(buffer: CVPixelBuffer, time: CMTime)] {
            lock.lock()
            defer { lock.unlock() }
            return Array(zip(buffers, times))
        }

        var dropped: Int {
            lock.lock()
            defer { lock.unlock() }
            return droppedCount
        }
    }

    private func frame() throws -> CVPixelBuffer {
        try TestFrames.blank(width: 64, height: 64, format: kCVPixelFormatType_32BGRA)
    }

    private func milliseconds(_ value: Int64) -> CMTime { CMTime(value: value, timescale: 1000) }

    // MARK: Recording

    /// Frames of the cable carry the time they were captured, a little before they arrive. A
    /// frame shown again (a translation came in) must not be stamped later than the live frames
    /// that follow it, or the recording drops them.
    func testShowingAFrameAgainKeepsTheLiveFramesOfTheCableInTheRecording() throws {
        let sink = FrameSink()
        let recording = RecordingStandIn()
        sink.recording = recording
        let lag = milliseconds(50)
        var pushed: [CVPixelBuffer] = []
        for _ in 0..<10 {
            let buffer = try frame()
            pushed.append(buffer)
            sink.push(buffer, time: CMTimeSubtract(MirrorRecorder.now, lag))
            sink.redisplay()
        }
        let kept = recording.kept
        XCTAssertEqual(recording.dropped, 0, "frames were thrown away")
        for frame in pushed {
            XCTAssertTrue(kept.contains { $0.buffer === frame }, "a live frame is missing in the recording")
        }
        XCTAssertEqual(kept.count, 20)
    }

    /// A still screen sends no frames: something shown again later moves forward in time, the
    /// way it happened, and stays behind the next live frame.
    func testFrameShownAgainOnAStillScreenMovesForwardInTime() throws {
        let sink = FrameSink()
        let recording = RecordingStandIn()
        sink.recording = recording
        let lag = milliseconds(50)
        let start = CMTimeSubtract(MirrorRecorder.now, lag)
        sink.push(try frame(), time: start)
        Thread.sleep(forTimeInterval: 0.03)
        sink.redisplay()
        sink.redisplay()
        let again = try XCTUnwrap(recording.kept.last?.time)
        XCTAssertGreaterThanOrEqual(CMTimeSubtract(again, start).seconds, 0.025,
                                    "the frame shown again must lie about as far after the first as it was shown later")
        let next = CMTimeSubtract(MirrorRecorder.now, lag)
        sink.push(try frame(), time: next)
        XCTAssertEqual(recording.kept.count, 4)
        XCTAssertEqual(recording.dropped, 0)
    }

    /// AirPlay and Android frames come without a time: they are stamped "now", and so is a
    /// frame shown again.
    func testFramesWithoutATimeAndFramesShownAgainFollowEachOther() throws {
        let sink = FrameSink()
        let recording = RecordingStandIn()
        sink.recording = recording
        for _ in 0..<5 {
            sink.push(try frame())
            sink.redisplay()
        }
        XCTAssertEqual(recording.kept.count, 10)
        XCTAssertEqual(recording.dropped, 0)
        let last = try XCTUnwrap(recording.kept.last?.time)
        XCTAssertLessThan(abs(CMTimeSubtract(MirrorRecorder.now, last).seconds), 0.5)
    }

    // MARK: Processor

    /// Returns a copy of its own for every frame and notes what it was given
    private final class MarkingProcessor: FrameProcessor {
        private(set) var inputs: [CVPixelBuffer] = []
        private(set) var outputs: [CVPixelBuffer] = []

        func process(_ pixelBuffer: CVPixelBuffer, time: CMTime) -> CVPixelBuffer {
            let copy = (try? TestFrames.blank(width: CVPixelBufferGetWidth(pixelBuffer),
                                              height: CVPixelBufferGetHeight(pixelBuffer),
                                              format: CVPixelBufferGetPixelFormatType(pixelBuffer), gray: 0))
                ?? pixelBuffer
            inputs.append(pixelBuffer)
            outputs.append(copy)
            return copy
        }
    }

    /// Display, screenshots and recordings get what the processor made; Text and the text
    /// recognition get the frame as the device sent it.
    func testProcessedFrameIsShownAndRecordedAndTheSourceIsKept() throws {
        let sink = FrameSink()
        let recording = RecordingStandIn()
        sink.recording = recording
        let processor = MarkingProcessor()
        sink.processor = processor
        let source = try frame()
        sink.push(source)

        XCTAssertEqual(processor.inputs.count, 1)
        XCTAssertTrue(processor.inputs.first === source)
        XCTAssertTrue(sink.latestSource === source, "the frame of the device must be kept as it is")
        XCTAssertTrue(sink.latest === processor.outputs.first, "the processed frame must be shown")
        XCTAssertFalse(sink.latest === sink.latestSource)
        XCTAssertTrue(recording.kept.last?.buffer === processor.outputs.first, "the processed frame must be recorded")

        // shown again: the frame of the device goes through the processor once more
        sink.redisplay()
        XCTAssertEqual(processor.inputs.count, 2)
        XCTAssertTrue(processor.inputs.last === source)
        XCTAssertTrue(sink.latestSource === source)
        XCTAssertTrue(sink.latest === processor.outputs.last)
        XCTAssertTrue(recording.kept.last?.buffer === processor.outputs.last)
    }

    func testWithoutAProcessorTheFrameIsShownAsItArrives() throws {
        let sink = FrameSink()
        let processor = MarkingProcessor()
        sink.processor = processor
        sink.push(try frame())
        sink.processor = nil

        let next = try frame()
        sink.push(next)
        XCTAssertTrue(sink.latest === next)
        XCTAssertTrue(sink.latestSource === next)
        XCTAssertEqual(processor.inputs.count, 1)

        // a processor that was removed leaves the picture as the device sent it when shown again
        sink.redisplay()
        XCTAssertTrue(sink.latest === next)
        XCTAssertEqual(processor.inputs.count, 1)
    }

    func testShowingAgainBeforeTheFirstFrameDoesNothing() {
        let sink = FrameSink()
        let processor = MarkingProcessor()
        sink.processor = processor
        sink.redisplay()
        XCTAssertNil(sink.latest)
        XCTAssertTrue(processor.inputs.isEmpty)
    }

    func testClearingForgetsBothFrames() throws {
        let sink = FrameSink()
        sink.processor = MarkingProcessor()
        sink.push(try frame())
        sink.clear()
        XCTAssertNil(sink.latest)
        XCTAssertNil(sink.latestSource)
    }

    // MARK: Thumbnails

    /// The thumbnail the tracker gets of every frame is the same with padded rows as without
    func testThumbnailOfPaddedFramesMatchesTheUnpaddedPicture() throws {
        let width = 1170, height = 400
        // a pattern that shows a row read with the wrong length
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width { gray[y * width + x] = UInt8((x * 7 + y * 13) % 200 + 20) }
        }
        let scale = LumaImage.scale(forFrameWidth: width, height: height)
        let expected = gray.withUnsafeBytes { bytes in
            LumaImage.downsampled(from: bytes.baseAddress!, width: width, height: height, bytesPerRow: width,
                                  format: .luma8, scale: scale)
        }
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA] {
            let frame = try TestFrames.frame(from: gray, width: width, height: height, format: format)
            if format == kCVPixelFormatType_32BGRA {
                XCTAssertGreaterThan(CVPixelBufferGetBytesPerRow(frame), width * 4, "rows must be padded")
            } else {
                XCTAssertGreaterThan(CVPixelBufferGetBytesPerRowOfPlane(frame, 0), width, "rows must be padded")
            }
            let thumbnail = try XCTUnwrap(FramePixels.thumbnail(of: frame))
            XCTAssertEqual(thumbnail.scale, scale)
            XCTAssertEqual(thumbnail.image, expected, "pixel format \(format)")
        }
        // video range: the same picture, its values squeezed into 16…235
        let video = try TestFrames.frame(from: gray, width: width, height: height,
                                         format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let thumbnail = try XCTUnwrap(FramePixels.thumbnail(of: video))
        XCTAssertEqual(thumbnail.image.width, expected.width)
        XCTAssertEqual(thumbnail.image.height, expected.height)
        for index in expected.pixels.indices {
            let squeezed = 16 + (Int(expected.pixels[index]) * 219 + 127) / 255
            XCTAssertLessThanOrEqual(abs(Int(thumbnail.image.pixels[index]) - squeezed), 1)
        }
    }

    func testOtherPixelFormatsGiveNoThumbnail() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
        XCTAssertNil(FramePixels.thumbnail(of: try XCTUnwrap(buffer)))
    }
}
