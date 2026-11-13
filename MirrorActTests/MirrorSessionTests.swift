// SPDX-License-Identifier: GPL-3.0-or-later
import CoreMedia
import CoreVideo
import XCTest
@testable import MirrorAct

/// What a mirror session does with Translate when its device goes away or connects again
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

    /// The new stream after the app connected the window again by itself
    private func reconnect(_ session: MirrorSession) throws {
        session.state = .connecting
        session.sink.clear()
        let (next, _) = try TestFrames.text(lines, width: 1170, height: 800, format: kCVPixelFormatType_32BGRA)
        session.sink.push(next)
        session.state = .live
    }

    /// Android from the cable to Wi-Fi or back: the app moves the window to the other connection
    /// by itself, and Translate goes on with the new stream
    func testTranslateGoesOnWhenTheAppMovesTheWindowToAnotherConnection() async throws {
        let (session, frame, shown) = try await translatingSession(kind: .android)
        session.streamWillEnd(handingOver: true)
        session.state = .disconnected(nil)
        XCTAssertFalse(session.isTranslating, "the button must not stay lit while the stream is away")
        XCTAssertTrue(shown.last === frame, "the last picture must be the device's own")
        XCTAssertEqual(session.toast, MirrorSession.translateResumeNotice, "the window must say that it goes on again")
        try reconnect(session)
        XCTAssertTrue(session.isTranslating, "Translate must go on with the new stream")
        XCTAssertTrue(session.sink.processor === session.translator)
        XCTAssertNotEqual(session.toast, MirrorSession.translateResumeNotice)
        // once only: a stream that connects again later starts without it
        session.state = .disconnected(nil)
        try reconnect(session)
        XCTAssertFalse(session.isTranslating)
        session.sink.recording = nil
    }

    /// The device went away and comes back of its own accord: Translate stays off
    func testTranslateStaysOffWhenTheDeviceConnectsAgainByItself() async throws {
        let (session, _, _) = try await translatingSession(kind: .wireless)
        session.state = .disconnected(nil)
        try reconnect(session)
        XCTAssertFalse(session.isTranslating)
        XCTAssertNil(session.sink.processor)
        session.sink.recording = nil
    }

    private final class TestClock {
        var date = Date(timeIntervalSinceReferenceDate: 0)
    }

    /// What AppModel does to a session, as it does it
    private enum Step {
        /// an Android stream stops (`connectAndroid`'s onStop): whether the app moves the window
        /// to another connection right away, then disconnected
        case androidStop(handingOver: Bool)
        /// AirPlay lost, the AirPlay code prompt, the cable unplugged
        case disconnect(String?)
        /// AirPlay clears the sink after a disconnect
        case clear
        /// `connectAndroid` or a new AirPlay client in the open window
        case connect
        /// the new stream's first frame
        case firstFrame
        case wait(TimeInterval)
        /// the Translate button, ⇧⌘T or the Device menu
        case press
        case expect(translating: Bool)
    }

    private struct Path {
        let name: String
        let kind: MirrorSession.Kind
        /// Translate is on before the first step
        var translating = true
        let steps: [Step]
        /// Translate at the end
        let translates: Bool
        var toast: String?
    }

    /// Every way AppModel changes a session's state, with what Translate does after it. Translate
    /// goes on by itself only when the app moves an Android window to another connection and
    /// the new stream is there within `translateResumeWindow`.
    func testTranslateAcrossEveryChangeOfTheSessionState() async throws {
        let late = MirrorSession.translateResumeWindow + 1
        let half = MirrorSession.translateResumeWindow * 0.6
        let staysOff = String(localized: "Translate stays off")
        let paths: [Path] = [
            Path(name: "AirPlay: the iPhone disconnects and connects again", kind: .wireless,
                 steps: [.disconnect(nil), .clear, .connect, .firstFrame], translates: false),
            Path(name: "AirPlay: the code prompt, then the iPhone connects", kind: .wireless,
                 steps: [.disconnect("Enter this code on the iPhone: 1234"), .connect, .firstFrame],
                 translates: false),
            Path(name: "AirPlay: a new connection replaces the live one", kind: .wireless,
                 steps: [.connect, .firstFrame], translates: false),
            Path(name: "Cable: the iPhone is unplugged", kind: .cable,
                 steps: [.disconnect("Cable disconnected"), .expect(translating: false)], translates: false),
            Path(name: "Android: a window opens", kind: .android, translating: false,
                 steps: [.connect, .firstFrame], translates: false),
            Path(name: "Android: unplugged, the phone is back hours later", kind: .android,
                 steps: [.androidStop(handingOver: false), .wait(3600), .connect, .firstFrame], translates: false),
            Path(name: "Android: unplugged and plugged in again at once", kind: .android,
                 steps: [.androidStop(handingOver: false), .connect, .firstFrame], translates: false),
            Path(name: "Android: moved to the other connection", kind: .android,
                 steps: [.androidStop(handingOver: true), .expect(translating: false), .connect, .firstFrame],
                 translates: true),
            Path(name: "Android: Switch to Wi-Fi, adb restarts before the new stream", kind: .android,
                 steps: [.androidStop(handingOver: true), .wait(half), .connect, .wait(1), .firstFrame],
                 translates: true),
            Path(name: "Android: moved, the new stream comes too late", kind: .android,
                 steps: [.androidStop(handingOver: true), .connect, .wait(late), .firstFrame], translates: false),
            Path(name: "Android: moved, the new stream stops before its first frame", kind: .android,
                 steps: [.androidStop(handingOver: true), .connect, .androidStop(handingOver: false),
                         .wait(3600), .connect, .firstFrame], translates: false),
            Path(name: "Android: moved, the new stream stops and the app moves it once more", kind: .android,
                 steps: [.androidStop(handingOver: true), .connect, .androidStop(handingOver: true),
                         .connect, .firstFrame], translates: true),
            Path(name: "Android: moved twice, too late in all", kind: .android,
                 steps: [.androidStop(handingOver: true), .connect, .wait(half), .androidStop(handingOver: true),
                         .connect, .wait(half), .firstFrame], translates: false),
            Path(name: "Android: Translate pressed while the window waits", kind: .android,
                 steps: [.androidStop(handingOver: true), .press, .expect(translating: false), .connect, .firstFrame],
                 translates: false, toast: staysOff),
            Path(name: "Android: Translate pressed while the new stream connects", kind: .android,
                 steps: [.androidStop(handingOver: true), .connect, .press, .firstFrame],
                 translates: false, toast: staysOff),
            Path(name: "Android: Translate was off when the window was moved", kind: .android, translating: false,
                 steps: [.androidStop(handingOver: true), .connect, .firstFrame], translates: false),
            Path(name: "Android: once only", kind: .android,
                 steps: [.androidStop(handingOver: true), .connect, .firstFrame, .expect(translating: true),
                         .androidStop(handingOver: false), .connect, .firstFrame], translates: false),
            Path(name: "Android: turned on by hand on the last picture, the phone is back later", kind: .android,
                 steps: [.androidStop(handingOver: false), .press, .expect(translating: true), .wait(3600),
                         .connect, .firstFrame], translates: false),
        ]
        for path in paths {
            let session: MirrorSession
            if path.translating {
                session = try await translatingSession(kind: path.kind).session
            } else {
                session = MirrorSession(id: "test", kind: path.kind, deviceName: "Phone", modelIdentifier: nil,
                                        muted: true)
                session.translator.makeEngine = { _ in InstantEngine() }
                session.sink.recording = FrameLog()
                let (frame, _) = try TestFrames.text(lines, width: 1170, height: 800, format: kCVPixelFormatType_32BGRA)
                session.sink.push(frame)
                session.state = .live
            }
            let clock = TestClock()
            session.now = { clock.date }
            for step in path.steps {
                switch step {
                case let .androidStop(handingOver):
                    session.streamWillEnd(handingOver: handingOver)
                    session.state = .disconnected(nil)
                case let .disconnect(reason):
                    session.state = .disconnected(reason)
                case .clear:
                    session.sink.clear()
                case .connect:
                    session.state = .connecting
                    session.sink.clear()
                case .firstFrame:
                    let (next, _) = try TestFrames.text(lines, width: 1170, height: 800,
                                                        format: kCVPixelFormatType_32BGRA)
                    session.sink.push(next)
                    if session.state != .live { session.state = .live }
                case let .wait(seconds):
                    clock.date += seconds
                case .press:
                    session.toggleTranslation()
                case let .expect(translating):
                    XCTAssertEqual(session.isTranslating, translating, "\(path.name): on the way")
                }
            }
            XCTAssertEqual(session.isTranslating, path.translates, path.name)
            XCTAssertEqual(session.sink.processor === session.translator, path.translates, path.name)
            if let toast = path.toast { XCTAssertEqual(session.toast, toast, path.name) }
            session.translator.stop()
            session.sink.recording = nil
        }
    }

    /// Which stopped Android stream the app moves to another connection by itself
    func testWhichStoppedAndroidStreamTheAppMoves() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let cases: [(name: String, other: Bool, wifiSwitch: TimeInterval?, moves: Bool)] = [
            ("cable unplugged, Wi-Fi there", true, nil, true),
            ("unplugged, no other connection", false, nil, false),
            ("Switch to Wi-Fi restarts adb on the phone", false, 2, true),
            ("Switch to Wi-Fi long ago, then unplugged", false, AppModel.wifiSwitchWindow + 1, false),
        ]
        for item in cases {
            let started = item.wifiSwitch.map { now.addingTimeInterval(-$0) }
            XCTAssertEqual(AppModel.movesToAnotherConnection(otherConnection: item.other, wifiSwitchStarted: started,
                                                             now: now), item.moves, item.name)
        }
    }

    /// Text before the first frame says why nothing happens, like Translate does
    func testCopyTextWithoutAFrameSaysWhy() {
        let session = MirrorSession(id: "test", kind: .wireless, deviceName: "iPhone", modelIdentifier: nil,
                                    muted: true)
        session.copyText()
        XCTAssertEqual(session.toast, String(localized: "No video to copy text from yet"))
    }
}
