// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import XCTest
@testable import MirrorAct

/// Translate with a server on this Mac (LM Studio) that does not answer: the window says so after
/// a while and stops saying it when the answer comes or Translate is turned off; turning
/// Translate off and on again sends the texts anew, and text that came into view meanwhile goes
/// out once the server answers. Synthetic frames, real Vision, the engine of the app with a
/// stand-in for the network.
@MainActor
final class LocalServiceWaitTests: XCTestCase {
    /// Answers every request once `answer` is open; the requests are kept, and so is whether
    /// they ended without an answer
    private final class WaitingTransport: LLMTransport, @unchecked Sendable {
        let answer = Gate()
        private let lock = NSLock()
        private var sent: [[String]] = []
        private var unanswered = 0

        func send(_ request: LLMHTTPRequest) async throws -> LLMHTTPReply {
            let texts = Self.texts(of: request)
            locked { sent.append(texts) }
            do {
                try await answer.wait()
            } catch {
                locked { unanswered += 1 }
                throw error
            }
            let content = TranslationPrompt.user(texts.map { "de:" + $0 })
            let body: [String: Any] = ["choices": [["index": 0, "message": ["role": "assistant", "content": content],
                                                    "finish_reason": "stop"]]]
            return (200, [LLMHeader("Content-Type", "application/json")], try JSONSerialization.data(withJSONObject: body))
        }

        var requests: [[String]] { locked { sent } }
        var cancelledRequests: Int { locked { unanswered } }

        private static func texts(of request: LLMHTTPRequest) -> [String] {
            guard let body = request.body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = object["messages"] as? [[String: Any]], let content = messages.last?["content"] as? String,
                  let list = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String] else { return [] }
            return list
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private let width = 1170, height = 800
    private let lines = [
        TestFrames.Line(text: "Settings", x: 60, top: 120),
        TestFrames.Line(text: "General information about this device", x: 60, top: 360),
    ]
    private let notice = "LM Studio: " + String(localized: "no answer for \(20) s – is the model still loading?")

    private var session: MirrorSession!
    private var transport: WaitingTransport!
    /// the waits for the notice of every engine made, in their order
    private var slowWaits: [Gate] = []

    override func setUp() async throws {
        transport = WaitingTransport()
        slowWaits = []
        session = MirrorSession(id: "test", kind: .android, deviceName: "Phone", modelIdentifier: nil, muted: true)
        session.translator.makeEngine = { [unowned self] _ in
            let engine = LLMTranslationEngine(connection: LLMConnection(provider: .lmStudio, model: "gemma4"),
                                              transport: self.transport)
            let slow = Gate()
            engine.untilSlowAnswer = { try await slow.wait() }
            self.slowWaits.append(slow)
            return engine
        }
        session.sink.push(try TestFrames.text(lines, width: width, height: height, format: kCVPixelFormatType_32BGRA).frame)
        session.state = .live
    }

    override func tearDown() async throws {
        session.translator.stop()
        transport.answer.open()
        session = nil
        transport = nil
    }

    func testTheWindowNamesAServerThatDoesNotAnswerUntilTheAnswerComes() async throws {
        session.translator.start()
        XCTAssertTrue(session.isTranslating)
        let asked = await waitFor { self.transport.requests.count == 1 && self.slowWaits.first?.counts.waiting == 1 }
        XCTAssertTrue(asked, "no request is waiting for its answer: \(transport.requests)")
        XCTAssertNil(session.toast)

        // the time is up: the window says so, and the request goes on waiting
        try XCTUnwrap(slowWaits.first).open()
        let named = await waitFor { self.session.toast == self.notice }
        XCTAssertTrue(named, "the window shows \(String(describing: session.toast))")
        XCTAssertEqual(transport.requests.count, 1)

        // the answer comes: the notice goes and the translations are drawn
        transport.answer.open()
        let gone = await waitFor { self.session.toast == nil }
        XCTAssertTrue(gone, "the window still shows \(String(describing: session.toast))")
        let drawn = await waitFor { self.session.sink.latest !== self.session.sink.latestSource }
        XCTAssertTrue(drawn, "no translation was drawn")
    }

    func testOffAndOnAgainEndsTheWaitingRequestAndSendsTheTextsAnew() async throws {
        session.translator.start()
        let asked = await waitFor { self.transport.requests.count == 1 }
        XCTAssertTrue(asked)
        try XCTUnwrap(slowWaits.first).open()
        let named = await waitFor { self.session.toast == self.notice }
        XCTAssertTrue(named)

        // off: the notice goes at once, the request ends, nothing of the turn is left waiting
        session.translator.stop()
        XCTAssertNil(session.toast)
        let ended = await waitFor { self.transport.cancelledRequests == 1 }
        XCTAssertTrue(ended, "the request still waits for its answer")

        // on again: the same texts go out in a new request, with a new wait for the notice
        session.translator.start()
        let askedAgain = await waitFor { self.transport.requests.count == 2 && self.slowWaits.count == 2 }
        XCTAssertTrue(askedAgain, "no new request: \(transport.requests)")
        XCTAssertEqual(Set(transport.requests[1]), Set(transport.requests[0]))
        XCTAssertNil(session.toast)
        transport.answer.open()
        let drawn = await waitFor { self.session.sink.latest !== self.session.sink.latestSource }
        XCTAssertTrue(drawn, "no translation was drawn")
        XCTAssertNil(session.toast)
    }

    func testTextThatCameIntoViewMeanwhileGoesOutOnceTheServerAnswers() async throws {
        session.translator.start()
        let asked = await waitFor { self.transport.requests.count == 1 }
        XCTAssertTrue(asked)
        let first = transport.requests[0]

        // a third paragraph comes into view while the server keeps the first request waiting
        let more = lines + [TestFrames.Line(text: "Privacy and Security", x: 60, top: 600)]
        session.sink.push(try TestFrames.text(more, width: width, height: height, format: kCVPixelFormatType_32BGRA).frame)
        // read meanwhile, but not sent: one request at a time
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(transport.requests.count, 1)

        transport.answer.open()
        let sent = await waitFor { self.transport.requests.dropFirst().joined().contains { $0.contains("Privacy") } }
        XCTAssertTrue(sent, "the new text did not go out: first \(first), then \(transport.requests.dropFirst())")
    }

    /// Polls `condition` until it holds or 15 seconds have passed
    private func waitFor(timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
