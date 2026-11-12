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
}
