// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import XCTest
@testable import MirrorAct

/// A lasting notice of the engine ("macOS asks whether it may download …") stays in the window
/// for as long as the engine says, under the passing ones, and goes with the turn of translating
@MainActor
final class TranslationStatusNoticeTests: XCTestCase {
    private final class StatusEngine: TranslationEngine, @unchecked Sendable {
        let name = "Test"
        let isRemote = false
        let prefersSettledText = false
        var notify: ((String) -> Void)?
        var notifyStatus: ((String?) -> Void)?
        func translate(_ texts: [String], into target: Locale.Language) async throws -> [String?] {
            [String?](repeating: nil, count: texts.count)
        }
        func cancel() {}
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("not within 10 s", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func translatingSession(with engine: StatusEngine) throws -> MirrorSession {
        let session = MirrorSession(id: "test", kind: .android, deviceName: "Phone", modelIdentifier: nil, muted: true)
        session.translator.makeEngine = { _ in engine }
        let (frame, _) = try TestFrames.text([TestFrames.Line(text: "Settings", x: 60, top: 120)],
                                             width: 600, height: 400, format: kCVPixelFormatType_32BGRA)
        session.sink.push(frame)
        session.state = .live
        session.translator.start()
        XCTAssertTrue(session.isTranslating)
        return session
    }

    func testALastingNoticeStaysUnderPassingOnesUntilItIsWithdrawn() async throws {
        let engine = StatusEngine()
        let session = try translatingSession(with: engine)
        // called from any thread
        await Task.detached { engine.notifyStatus?("asking") }.value
        try await waitUntil { session.toast == "asking" }
        // after two seconds it is still there
        try await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertEqual(session.toast, "asking")
        // a passing notice goes over it for its time
        session.showToast("saved", seconds: 0.1)
        XCTAssertEqual(session.toast, "saved")
        try await waitUntil { session.toast == "asking" }
        // replaced while a passing notice is up: the new one comes after it
        session.showToast("saved", seconds: 0.1)
        engine.notifyStatus?("downloading")
        try await waitUntil { session.toast == "downloading" }
        engine.notifyStatus?(nil)
        try await waitUntil { session.toast == nil }
        session.translator.stop()
    }

    /// Turning Translate off withdraws the notice, and one that was on its way does not come back
    func testTheNoticeGoesWithTheTurn() async throws {
        let engine = StatusEngine()
        let session = try translatingSession(with: engine)
        let report = try XCTUnwrap(engine.notifyStatus)
        report("asking")
        try await waitUntil { session.toast == "asking" }
        report("downloading")
        session.translator.stop()
        XCTAssertNil(session.toast)
        XCTAssertNil(engine.notifyStatus)
        // what the old turn says afterwards stays unseen
        report("late")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(session.toast)
    }
}
