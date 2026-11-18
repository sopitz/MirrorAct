// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Combine
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

    /// Text and Translate are there only with the setting "Experimental features"
    override func setUp() async throws {
        setExperimentalFeatures(true)
    }

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

    /// The time of a session and what it schedules on it: `advance` runs what falls due, in order
    @MainActor
    private final class TestClock {
        private final class Timer {
            let due: Date
            let action: @MainActor () -> Void
            var cancelled = false
            init(due: Date, action: @escaping @MainActor () -> Void) {
                self.due = due
                self.action = action
            }
        }

        private(set) var date = Date(timeIntervalSinceReferenceDate: 0)
        private var timers: [Timer] = []

        /// Gives the session this clock
        func drive(_ session: MirrorSession) {
            session.now = { self.date }
            session.schedule = { seconds, action in
                let timer = Timer(due: self.date.addingTimeInterval(seconds), action: action)
                self.timers.append(timer)
                return AnyCancellable { timer.cancelled = true }
            }
        }

        func advance(_ seconds: TimeInterval) {
            let end = date.addingTimeInterval(seconds)
            while let next = timers.filter({ !$0.cancelled && $0.due <= end }).min(by: { $0.due < $1.due }) {
                timers.removeAll { $0 === next }
                date = max(date, next.due)
                next.action()
            }
            date = end
        }

        /// Moves the time on without running what falls due, as when the main thread is busy
        func jump(_ seconds: TimeInterval) {
            date = date.addingTimeInterval(seconds)
        }
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
        let tooLate = String(localized: "Translate is off – the new connection took too long")
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
                 steps: [.androidStop(handingOver: true), .connect, .wait(late), .firstFrame], translates: false,
                 toast: tooLate),
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
            clock.drive(session)
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
                    clock.advance(seconds)
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

    /// What happens to a session, for the messages in its window
    private enum Event {
        /// a passing toast of two seconds
        case toast(String)
        /// the engine's lasting notice ("macOS asks whether it may download …"), or nil to withdraw it
        case engine(String?)
        /// `connectAndroid`'s onStop: the app moves the window to another connection
        case handOver
        /// `connectAndroid`'s onStop: the stream ends otherwise, the device is gone
        case gone
        /// the first half of `handOver`, before the state changes
        case willHandOver
        case connect
        case firstFrame
        /// the Translate button, ⇧⌘T or the Device menu
        case press
        case wait(TimeInterval)
        /// the time moves on while the main thread is busy: nothing scheduled has run yet
        case busy(TimeInterval)
        /// what the window says in place of the state (nil: the state)
        case shows(String?)
    }

    /// Which of the three kinds of message the window shows, in every combination, and when each
    /// goes: a passing toast over everything, the notice that Translate goes on again while it
    /// waits for the stream of a hand-over, the engine's lasting notice under both
    func testWhichMessageTheWindowShows() async throws {
        let resume = MirrorSession.translateResumeNotice
        let staysOff = String(localized: "Translate stays off")
        let connected = "Connected via Wi-Fi"
        let tooLate = String(localized: "Translate is off – the new connection took too long")
        let rows: [(name: String, events: [Event], translates: Bool)] = [
            ("a toast, then the state", [.toast("Saved"), .shows("Saved"), .wait(2), .shows(nil)], true),
            ("the engine's notice under a toast",
             [.engine("asking"), .shows("asking"), .toast("Saved"), .shows("Saved"), .wait(2), .shows("asking"),
              .engine(nil), .shows(nil)], true),
            ("the engine's notice changes under a toast",
             [.engine("asking"), .toast("Saved"), .engine("downloading"), .shows("Saved"), .wait(2),
              .shows("downloading")], true),
            ("Translate turned off withdraws the engine's notice",
             [.engine("asking"), .press, .shows(nil), .wait(2), .shows(nil)], false),
            ("a hand-over replaces a toast and the engine's notice",
             [.engine("asking"), .toast("Saved"), .willHandOver, .shows(resume), .wait(0.5), .shows(resume),
              .handOver, .shows(resume), .wait(5), .shows(resume)], false),
            ("Switch to Wi-Fi: its toast goes over the wait, and the wait shows again",
             [.handOver, .wait(2), .toast(connected), .shows(connected), .wait(2), .shows(resume), .connect,
              .wait(1), .shows(resume), .firstFrame, .shows(nil)], true),
            ("the engine's notice of the new stream",
             [.handOver, .connect, .firstFrame, .engine("asking"), .shows("asking")], true),
            ("pressed while it waits", [.handOver, .press, .shows(staysOff), .wait(2), .shows(nil), .wait(10),
                                         .shows(nil), .connect, .firstFrame, .shows(nil)], false),
            ("pressed under a toast", [.handOver, .toast(connected), .press, .shows(staysOff), .wait(2),
                                        .shows(nil)], false),
            ("the device is gone while it waits", [.handOver, .connect, .gone, .shows(nil), .wait(20), .shows(nil)],
             false),
            ("the device is gone under a toast", [.handOver, .toast(connected), .gone, .shows(connected), .wait(2),
                                                   .shows(nil)], false),
            ("a second hand-over while it waits",
             [.handOver, .connect, .wait(3), .toast(connected), .handOver, .shows(connected), .wait(2),
              .shows(resume), .connect, .firstFrame, .shows(nil)], true),
            ("the new stream just in time", [.handOver, .connect, .wait(9.9), .shows(resume), .firstFrame,
                                              .shows(nil), .wait(10), .shows(nil)], true),
            ("the time runs out", [.handOver, .connect, .wait(10), .shows(tooLate), .wait(4), .shows(nil),
                                    .firstFrame, .shows(nil)], false),
            ("the time runs out under a toast", [.handOver, .wait(9), .toast(connected), .wait(1),
                                                  .shows(tooLate)], false),
            ("the first frame after the time, before the end of the wait could run",
             [.handOver, .connect, .busy(11), .firstFrame, .shows(tooLate), .wait(4), .shows(nil)], false),
            ("two hand-overs, too late in all", [.handOver, .connect, .wait(6), .handOver, .connect, .wait(4),
                                                  .shows(tooLate)], false),
        ]
        for row in rows {
            let session = try await translatingSession(kind: .android).session
            let clock = TestClock()
            clock.drive(session)
            for (index, event) in row.events.enumerated() {
                switch event {
                case let .toast(text):
                    session.showToast(text)
                case let .engine(text):
                    session.translator.onStatus?(text)
                case .handOver, .gone, .willHandOver:
                    if case .gone = event {
                        session.streamWillEnd(handingOver: false)
                    } else {
                        session.streamWillEnd(handingOver: true)
                    }
                    if case .willHandOver = event { break }
                    session.state = .disconnected(nil)
                case .connect:
                    session.state = .connecting
                    session.sink.clear()
                case .firstFrame:
                    let (next, _) = try TestFrames.text(lines, width: 1170, height: 800,
                                                        format: kCVPixelFormatType_32BGRA)
                    session.sink.push(next)
                    if session.state != .live { session.state = .live }
                case .press:
                    session.toggleTranslation()
                case let .wait(seconds):
                    clock.advance(seconds)
                case let .busy(seconds):
                    clock.jump(seconds)
                case let .shows(text):
                    XCTAssertEqual(session.toast, text, "\(row.name), step \(index + 1)")
                }
            }
            XCTAssertEqual(session.isTranslating, row.translates, row.name)
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

    // MARK: The setting "Experimental features"

    /// Turning the setting off ends Translate in every window at once, as if it had been
    /// turned off there: the button is off, the picture is the device's own, the translator's
    /// lasting notice goes
    func testTranslateStopsWhenExperimentalFeaturesAreTurnedOff() async throws {
        let (session, frame, shown) = try await translatingSession(kind: .wireless)
        session.translator.onStatus?("macOS asks whether it may download")
        XCTAssertEqual(session.toast, "macOS asks whether it may download")
        AppSettings.shared.experimentalFeatures = false
        XCTAssertFalse(session.isTranslating)
        XCTAssertNil(session.sink.processor)
        XCTAssertTrue(shown.last === frame, "the last picture must be the device's own")
        XCTAssertNil(session.toast, "the translator's notice must go")
        // on again: Translate stays off until the user turns it on
        AppSettings.shared.experimentalFeatures = true
        XCTAssertFalse(session.isTranslating)
        session.sink.recording = nil
    }

    /// While the setting is off, nothing starts Translate: not the button, the menu or the
    /// shortcut (they all call `toggleTranslation`), and not the translator itself
    func testTranslateDoesNotStartWhileExperimentalFeaturesAreOff() throws {
        setExperimentalFeatures(false)
        let session = MirrorSession(id: "test", kind: .android, deviceName: "Phone", modelIdentifier: nil, muted: true)
        session.translator.makeEngine = { _ in InstantEngine() }
        let (frame, _) = try TestFrames.text(lines, width: 1170, height: 800, format: kCVPixelFormatType_32BGRA)
        session.sink.push(frame)
        session.state = .live
        session.toggleTranslation()
        XCTAssertFalse(session.isTranslating)
        session.translator.start()
        XCTAssertFalse(session.isTranslating)
        XCTAssertNil(session.sink.processor)
        XCTAssertNil(session.toast, "nothing to say about a function that is not there")
    }

    /// The app moved a translating window to another connection, and the setting goes off
    /// before the new stream is live: Translate does not go on again, also when the setting is
    /// on again by then
    func testTranslateDoesNotGoOnAgainAfterAHandOverOnceExperimentalFeaturesAreOff() async throws {
        for onAgain in [false, true] {
            let (session, _, _) = try await translatingSession(kind: .android)
            session.streamWillEnd(handingOver: true)
            session.state = .disconnected(nil)
            XCTAssertEqual(session.toast, MirrorSession.translateResumeNotice)
            AppSettings.shared.experimentalFeatures = false
            XCTAssertNotEqual(session.toast, MirrorSession.translateResumeNotice, "the wait must end")
            if onAgain { AppSettings.shared.experimentalFeatures = true }
            try reconnect(session)
            XCTAssertFalse(session.isTranslating, "on again: \(onAgain)")
            XCTAssertNil(session.sink.processor)
            session.sink.recording = nil
            AppSettings.shared.experimentalFeatures = true
        }
    }

    /// While the setting is off, Text copies nothing and says nothing
    func testCopyTextDoesNothingWhileExperimentalFeaturesAreOff() {
        setExperimentalFeatures(false)
        let session = MirrorSession(id: "test", kind: .wireless, deviceName: "iPhone", modelIdentifier: nil,
                                    muted: true)
        session.copyText()
        XCTAssertNil(session.toast, "not even why it cannot copy")
    }

    /// The setting goes off while Text reads the screen: the text is not copied and nothing is
    /// said. Text copies into a pasteboard of the test's own, never into the clipboard.
    func testTextCopiesNothingOnceExperimentalFeaturesGoOffWhileItReads() async throws {
        func session(into pasteboard: NSPasteboard) throws -> MirrorSession {
            let session = MirrorSession(id: "test", kind: .wireless, deviceName: "iPhone", modelIdentifier: nil,
                                        muted: true)
            session.textPasteboard = pasteboard
            let (frame, _) = try TestFrames.text(lines, width: 1170, height: 800, format: kCVPixelFormatType_32BGRA)
            session.sink.push(frame)
            return session
        }
        func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline, !condition() { try? await Task.sleep(nanoseconds: 20_000_000) }
            return condition()
        }
        let pasteboards = (0..<2).map { _ in
            NSPasteboard(name: NSPasteboard.Name("io.github.sopitz.MirrorAct.tests.\(UUID().uuidString)"))
        }
        defer { pasteboards.forEach { $0.releaseGlobally() } }

        // with the setting on, Text copies the text: how long reading takes here
        let copying = try session(into: pasteboards[0])
        let started = Date()
        copying.copyText()
        let copied = await waitFor(15) { copying.toast != nil }
        let reading = Date().timeIntervalSince(started)
        XCTAssertTrue(copied)
        XCTAssertEqual(copying.toast, String(localized: "Text copied to the clipboard"))
        XCTAssertEqual(pasteboards[0].string(forType: .string)?.contains("Privacy and Security"), true)

        // off while it reads: nothing comes, also well after the text has been read
        let reader = try session(into: pasteboards[1])
        reader.copyText()
        AppSettings.shared.experimentalFeatures = false
        let said = await waitFor(3 * reading + 0.5) { reader.toast != nil }
        XCTAssertFalse(said, "\(reader.toast ?? "")")
        XCTAssertNil(pasteboards[1].string(forType: .string))
    }

    /// Text before the first frame says why nothing happens, like Translate does
    func testCopyTextWithoutAFrameSaysWhy() {
        let session = MirrorSession(id: "test", kind: .wireless, deviceName: "iPhone", modelIdentifier: nil,
                                    muted: true)
        session.copyText()
        XCTAssertEqual(session.toast, String(localized: "No video to copy text from yet"))
    }
}
