// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import XCTest
@testable import MirrorAct

/// What a mirror session does with Translate when its device goes away
@MainActor
final class MirrorSessionTests: XCTestCase {
    private final class InstantEngine: TranslationEngine {
        let name = "Test"
        let isRemote = false
        let prefersSettledText = false
        var notify: ((String) -> Void)?
        func translate(_ texts: [String], into target: Locale.Language) async throws -> [String?] {
            texts.map { "de:" + $0 }
        }
        func cancel() {}
    }

    /// Notes the frames a recording would get; the display gets the same ones
    private final class FrameLog: FrameRecording {
        private let lock = NSLock()
        private var frames: [CVPixelBuffer] = []
        func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
            lock.lock()
            frames.append(pixelBuffer)
            lock.unlock()
        }
        func appendAudio(_ sampleBuffer: CMSampleBuffer) {}
        var last: CVPixelBuffer? {
            lock.lock()
            defer { lock.unlock() }
            return frames.last
        }
    }

    private let lines = [
        TestFrames.Line(text: "Settings", x: 60, top: 120),
        TestFrames.Line(text: "Privacy and Security", x: 60, top: 400),
    ]

    private func translatingSession(kind: MirrorSession.Kind) async throws
        -> (session: MirrorSession, frame: CVPixelBuffer, shown: FrameLog) {
        let session = MirrorSession(id: "test", kind: kind, deviceName: "iPhone", modelIdentifier: "iPhone14,2",
                                    muted: true)
        let shown = FrameLog()
        session.sink.recording = shown
        session.translator.makeEngine = { _ in InstantEngine() }
        let (frame, _) = try TestFrames.text(lines, width: 1170, height: 800, format: kCVPixelFormatType_32BGRA)
        session.sink.push(frame)
        session.state = .live
        session.translator.start()
        XCTAssertTrue(session.isTranslating)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, session.sink.latest === session.sink.latestSource {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(session.sink.latest === frame, "no translation was drawn")
        return (session, frame, shown)
    }

    /// AirPlay, the cable and Android all mark the session disconnected (AirPlay then clears
    /// its sink): Translate ends first, while the device's last frame is still there to be shown
    /// again without the translations.
    func testTranslateEndsWhenTheDeviceDisconnects() async throws {
        for kind in [MirrorSession.Kind.wireless, .cable, .android] {
            let (session, frame, shown) = try await translatingSession(kind: kind)
            session.state = .disconnected(nil)
            XCTAssertFalse(session.isTranslating, "\(kind): the button must not stay lit")
            XCTAssertNil(session.sink.processor)
            XCTAssertTrue(shown.last === frame, "\(kind): the last picture must be the device's own")
            session.sink.clear()
            session.sink.recording = nil
        }
    }

    /// A device that connects again into the same window starts without the translations of
    /// the stream before
    func testTranslateEndsWhenTheSessionConnectsAgain() async throws {
        let (session, frame, shown) = try await translatingSession(kind: .wireless)
        session.state = .connecting
        session.sink.clear()
        XCTAssertFalse(session.isTranslating)
        XCTAssertNil(session.sink.processor)
        XCTAssertTrue(shown.last === frame)
        session.sink.recording = nil
    }

    func testTranslateStaysOnWhileTheSessionIsLive() async throws {
        let (session, _, _) = try await translatingSession(kind: .cable)
        session.state = .live
        XCTAssertTrue(session.isTranslating)
        session.translator.stop()
        session.sink.recording = nil
    }

    /// Text before the first frame says why nothing happens, like Translate does
    func testCopyTextWithoutAFrameSaysWhy() {
        let session = MirrorSession(id: "test", kind: .wireless, deviceName: "iPhone", modelIdentifier: nil,
                                    muted: true)
        session.copyText()
        XCTAssertEqual(session.toast, String(localized: "No video to copy text from yet"))
    }
}
