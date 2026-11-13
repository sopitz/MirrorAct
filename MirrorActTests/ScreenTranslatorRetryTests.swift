// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import XCTest
@testable import MirrorAct

/// Translate over minutes of a service that fails, on a still screen: when the texts are asked
/// for again, what that costs, what the window says, and how soon the screen is translated once
/// the service answers again. Synthetic frames, real Vision, the engine of the app with a
/// stand-in for the service, and a clock of the test's own that jumps over the waits.
@MainActor
final class ScreenTranslatorRetryTests: XCTestCase {
    /// Seconds of a clock that runs with the real one and jumps ahead to the next wake-up when
    /// the test says so; `pause` waits for this clock
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 1000
        private var sleepers: [(until: TimeInterval, continuation: CheckedContinuation<Void, Never>)] = []
        private var lastChange = Date()

        var now: TimeInterval { locked { ProcessInfo.processInfo.systemUptime + offset } }
        /// real seconds since the clock last jumped or someone began to wait
        var quietFor: TimeInterval { locked { Date().timeIntervalSince(lastChange) } }

        func pause(_ seconds: TimeInterval) async {
            await withCheckedContinuation { continuation in
                locked {
                    sleepers.append((ProcessInfo.processInfo.systemUptime + offset + seconds, continuation))
                    lastChange = Date()
                }
            }
        }

        /// moves the clock on by `seconds` (a wait of the engine within one request)
        func advance(by seconds: TimeInterval) {
            locked {
                offset += max(0, seconds)
                lastChange = Date()
            }
            wakeDue()
        }

        /// moves the clock on to the earliest wake-up, but not beyond `limit`; false = none is due
        @discardableResult
        func jumpToNextWakeUp(notAfter limit: TimeInterval) -> Bool {
            let jumped: Bool = locked {
                guard let next = sleepers.map(\.until).min() else { return false }
                let now = ProcessInfo.processInfo.systemUptime + offset
                offset += max(0, min(next, limit) - now)
                lastChange = Date()
                return true
            }
            wakeDue()
            return jumped
        }

        func wakeDue() {
            let due: [CheckedContinuation<Void, Never>] = locked {
                let now = ProcessInfo.processInfo.systemUptime + offset
                let due = sleepers.filter { $0.until <= now }.map(\.continuation)
                sleepers.removeAll { $0.until <= now }
                return due
            }
            due.forEach { $0.resume() }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    /// A language model service that answers as `mode` says: translations ("de:" in front of
    /// each text), an error, a dropped connection, or something that is not the list asked for
    private final class StandInService: LLMTransport, @unchecked Sendable {
        enum Mode { case answers, error500, dropsTheConnection, garbage }
        struct Request {
            let time: TimeInterval
            let texts: [String]
            let mode: Mode
        }

        private let lock = NSLock()
        private let clock: TestClock
        private var current: Mode = .answers
        private var sent: [Request] = []
        private var lastRequest = Date.distantPast

        init(clock: TestClock) {
            self.clock = clock
        }

        var mode: Mode {
            get { locked { current } }
            set { locked { current = newValue } }
        }
        var requests: [Request] { locked { sent } }
        /// real seconds since the last request
        var quietFor: TimeInterval { locked { Date().timeIntervalSince(lastRequest) } }

        func send(_ request: LLMHTTPRequest) async throws -> LLMHTTPReply {
            let texts = Self.texts(of: request)
            let mode: Mode = locked {
                sent.append(Request(time: clock.now, texts: texts, mode: current))
                lastRequest = Date()
                return current
            }
            switch mode {
            case .answers:
                return Self.reply(TranslationPrompt.user(texts.map { "de:" + $0 }))
            case .error500:
                return (500, [LLMHeader("Content-Type", "application/json")],
                        Data(#"{"error":{"message":"Internal server error (test)","type":"server_error"}}"#.utf8))
            case .dropsTheConnection:
                throw URLError(.networkConnectionLost)
            case .garbage:
                return Self.reply("Sure! Here are the translations you asked for.")
            }
        }

        private static func reply(_ content: String) -> LLMHTTPReply {
            let body: [String: Any] = ["choices": [["index": 0, "message": ["role": "assistant", "content": content],
                                                    "finish_reason": "stop"]]]
            return (200, [LLMHeader("Content-Type", "application/json")],
                    (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        }

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

    private let width = 1170, height = 2400
    /// a still screen of ten paragraphs
    private let texts = ["Settings", "Network and internet", "Connected devices", "Apps and notifications", "Battery",
                         "Display and brightness", "Sound and vibration", "Storage", "Privacy", "Location"]
    private var lines: [TestFrames.Line] {
        texts.enumerated().map { TestFrames.Line(text: $1, x: 60, top: 300 + 200 * CGFloat($0)) }
    }

    private var clock: TestClock!
    private var service: StandInService!
    private var sink: FrameSink!
    private var translator: ScreenTranslator!
    private var messages: [String] = []

    override func setUp() async throws {
        clock = TestClock()
        service = StandInService(clock: clock)
        sink = FrameSink()
        let clock = clock!
        translator = ScreenTranslator(sink: sink, clock: { clock.now }, pause: { await clock.pause($0) })
        translator.makeEngine = { [unowned self] _ in
            let engine = LLMTranslationEngine(connection: LLMConnection(provider: .lmStudio, model: "gemma4"),
                                              transport: self.service)
            engine.now = { clock.now }
            engine.pause = { clock.advance(by: $0) }
            engine.untilSlowAnswer = { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) }
            return engine
        }
        messages = []
        translator.onMessage = { [unowned self] in messages.append($0) }
        sink.push(try TestFrames.text(lines, width: width, height: height, format: kCVPixelFormatType_32BGRA).frame)
    }

    override func tearDown() async throws {
        translator.stop()
        translator = nil
        sink = nil
        service = nil
        clock = nil
    }

    // MARK: Timelines

    /// The service reports errors for ten minutes: tried after 5, 10, 20, 40 s and then every
    /// 60 s (the engine's own short retry within each try), the window names the wait that
    /// applies, and once the service answers again the screen is translated with the next try.
    func testAServiceThatReportsErrorsIsTriedEveryMinuteAndTheScreenIsTranslatedWithTheNextTry() async throws {
        let outage = try await failFor(600, mode: .error500)
        XCTAssertEqual(outage.tries.count, 13, "tries at \(outage.tries)")
        XCTAssertEqual(outage.requests, 26)
        assertTheWaits(outage.waits, steadyAfter: 4)
        XCTAssertLessThanOrEqual(outage.recovery, 62, "translated \(outage.recovery) s after the service answered again")
        let wait = " – " + String(localized: "trying again in \(60) s")
        XCTAssertTrue(messages.contains { $0.hasSuffix(wait) }, "\(messages)")
        XCTAssertFalse(messages.contains { $0.contains(String(localized: "trying again in \(2) min")) }, "\(messages)")
        XCTAssertTrue(translator.isActive)
    }

    /// The connection to the server drops for ten minutes: the same steps
    func testAServerThatDropsTheConnectionIsTriedEveryMinuteAndTheScreenIsTranslatedWithTheNextTry() async throws {
        let outage = try await failFor(600, mode: .dropsTheConnection)
        XCTAssertEqual(outage.tries.count, 13, "tries at \(outage.tries)")
        XCTAssertEqual(outage.requests, 13)
        assertTheWaits(outage.waits, steadyAfter: 4)
        XCTAssertLessThanOrEqual(outage.recovery, 62, "translated \(outage.recovery) s after the service answered again")
        XCTAssertTrue(translator.isActive)
    }

    /// A text that comes into view while the engine waits for its service goes out with the
    /// next request together with the texts that failed, and once the service answers again it
    /// is translated with them, not after waits of its own that grew while nothing was sent.
    /// (This holds through the shared steps of the engine's and the tracker's waits; that a
    /// refusal while the engine waits is no failure of a text is shown by
    /// testAWaitOfTheEngineIsNoFailureOfTheTexts.)
    func testATextThatComesIntoViewDuringAnOutageIsTranslatedWithTheTextsThatFailed() async throws {
        let few = Array(lines.prefix(2))
        sink.push(try TestFrames.text(few, width: width, height: height, format: kCVPixelFormatType_32BGRA).frame)
        service.mode = .error500
        translator.start()
        // three failures: the engine waits 20 s
        await run(until: { self.tries().count == 3 })
        // (the clock does not jump meanwhile)
        try await Task.sleep(nanoseconds: 500_000_000)
        // a third paragraph comes into view; the picture comes to rest and is read
        let more = few + [TestFrames.Line(text: "Privacy and security", x: 60, top: 1400)]
        let frame = try TestFrames.text(more, width: width, height: height, format: kCVPixelFormatType_32BGRA).frame
        for _ in 0..<15 {
            sink.push(frame)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // the fourth try fails as well, then the service answers again
        await run(until: { self.tries().count == 4 })
        try await Task.sleep(nanoseconds: 500_000_000)
        service.mode = .answers
        await run(until: { self.service.requests.contains { $0.mode == .answers } })
        let answered = try XCTUnwrap(service.requests.first { $0.mode == .answers })
        XCTAssertEqual(Set(answered.texts), Set(["Settings", "Network and internet", "Privacy and security"]),
                       "the first request after the outage")
        XCTAssertLessThanOrEqual(answered.time - (tries().last ?? 0), 42)
    }

    /// The engine says that it waits for its service (a failure in an earlier portion of the
    /// same request, or a wait the service asked for): the texts are offered again when that
    /// wait is over, not after the wait of a text that failed, and nothing is shown
    func testAWaitOfTheEngineIsNoFailureOfTheTexts() async throws {
        let engine = WaitingOnceEngine(wait: 2, clock: clock)
        translator.makeEngine = { _ in engine }
        translator.start()
        await run(until: { engine.calls.count >= 2 }, quiet: { engine.quietFor > 0.3 && !engine.calls.isEmpty })
        let calls = engine.calls
        XCTAssertGreaterThanOrEqual(calls.count, 2)
        guard calls.count >= 2 else { return }
        XCTAssertEqual(Set(calls[1].texts), Set(calls[0].texts))
        XCTAssertLessThanOrEqual(calls[1].time - calls[0].time, 3, "offered again \(calls[1].time - calls[0].time) s later")
        XCTAssertEqual(messages, [])
    }

    /// While the engine waits for its service, the translator does not ask it at all, not even
    /// for a text that comes into view meanwhile: that text goes out with the others once the
    /// wait is over
    func testNothingIsOfferedToTheEngineWhileItWaits() async throws {
        let few = Array(lines.prefix(2))
        sink.push(try TestFrames.text(few, width: width, height: height, format: kCVPixelFormatType_32BGRA).frame)
        let engine = WaitingOnceEngine(wait: 30, clock: clock)
        translator.makeEngine = { _ in engine }
        translator.start()
        await run(until: { !engine.calls.isEmpty }, quiet: { false })
        // a third paragraph comes into view and is read while the engine waits (the clock does
        // not jump meanwhile)
        let more = few + [TestFrames.Line(text: "Privacy and security", x: 60, top: 1400)]
        let frame = try TestFrames.text(more, width: width, height: height, format: kCVPixelFormatType_32BGRA).frame
        for _ in 0..<20 {
            sink.push(frame)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await run(until: { engine.calls.count >= 2 }, quiet: { engine.quietFor > 0.3 })
        let calls = engine.calls
        XCTAssertGreaterThanOrEqual(calls.count, 2)
        guard calls.count >= 2 else { return }
        XCTAssertGreaterThanOrEqual(calls[1].time - calls[0].time, 30,
                                    "asked again \(calls[1].time - calls[0].time) s later, during its wait")
        XCTAssertEqual(Set(calls[1].texts), Set(["Settings", "Network and internet", "Privacy and security"]))
        XCTAssertEqual(messages, [])
    }

    // MARK: Helpers

    /// Says once that it waits for its service, then translates
    private final class WaitingOnceEngine: TranslationEngine, @unchecked Sendable {
        let name = "Test"
        let isRemote = false
        let prefersSettledText = true
        var notify: ((String) -> Void)?
        private let wait: TimeInterval
        private let clock: TestClock
        private let lock = NSLock()
        private var made: [(time: TimeInterval, texts: [String])] = []
        private var last = Date.distantPast

        init(wait: TimeInterval, clock: TestClock) {
            self.wait = wait
            self.clock = clock
        }

        var calls: [(time: TimeInterval, texts: [String])] { locked { made } }
        var quietFor: TimeInterval { locked { Date().timeIntervalSince(last) } }

        func translate(_ texts: [String], into target: Locale.Language) async throws -> [String?] {
            let first: Bool = locked {
                made.append((clock.now, texts))
                last = Date()
                return made.count == 1
            }
            if first { throw TranslationWait(seconds: wait) }
            return texts.map { "de:" + $0 }
        }

        func cancel() {}

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    private struct Outage {
        /// when a try began: its first request (the engine may send one more right after)
        var tries: [TimeInterval]
        /// seconds between the end of a try and the next one
        var waits: [TimeInterval]
        /// requests while the service failed
        var requests: Int
        /// seconds from the service answering again to the first request it answered
        var recovery: TimeInterval
    }

    /// Translate on over a still screen while the service fails for `seconds` in `mode`, then
    /// until the screen is translated
    private func failFor(_ seconds: TimeInterval, mode: StandInService.Mode) async throws -> Outage {
        service.mode = mode
        translator.start()
        let started = await run(until: { !self.service.requests.isEmpty }, limit: nil)
        XCTAssertTrue(started, "nothing was sent")
        let start = try XCTUnwrap(service.requests.first).time
        await run(until: { self.clock.now >= start + seconds }, limit: start + seconds)
        let failed = service.requests
        service.mode = .answers
        let back = clock.now
        let translated = await run(until: { self.service.requests.contains { $0.mode == .answers } })
        XCTAssertTrue(translated, "nothing was sent after the service answered again")
        let first = service.requests.first { $0.mode == .answers }
        let tries = self.tries(in: failed)
        let ends = tries.map { start in failed.filter { $0.time >= start && $0.time < start + 2 }.map(\.time).max() ?? start }
        let waits = zip(ends, tries.dropFirst()).map { $1 - $0 }
        return Outage(tries: tries.map { $0 - start }, waits: waits, requests: failed.count,
                      recovery: (first?.time ?? .infinity) - back)
    }

    /// 5, 10, 20, 40 s, then 60 s each: a wake-up comes 0.2 s after the wait, and the clock runs
    /// on with the real one meanwhile
    private func assertTheWaits(_ waits: [TimeInterval], steadyAfter steps: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        let expected = waits.indices.map { $0 < steps ? 5 * pow(2, Double($0)) : 60 }
        for (wait, step) in zip(waits, expected) where wait < step || wait > step + 1.5 {
            XCTFail("waits \(waits.map { ($0 * 10).rounded() / 10 }), expected \(expected)", file: file, line: line)
            return
        }
    }

    /// The times at which a try began: a request more than two seconds after the one before
    private func tries(in requests: [StandInService.Request]? = nil) -> [TimeInterval] {
        var starts: [TimeInterval] = []
        for request in requests ?? service.requests where request.mode != .answers {
            if let last = starts.last, request.time - last < 2 { continue }
            starts.append(request.time)
        }
        return starts
    }

    /// Lets the translator work until `condition` holds: whenever it has sent nothing and begun
    /// no wait for a moment (or `quiet` says so), the clock jumps to its next wake-up (not
    /// beyond `limit`).
    /// False = it did not hold within a minute of real time.
    @discardableResult
    private func run(until condition: () -> Bool, limit: TimeInterval? = .infinity,
                     quiet: (() -> Bool)? = nil) async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while !condition(), Date() < deadline {
            clock.wakeDue()
            if let limit, clock.quietFor > 0.3, quiet?() ?? (service.quietFor > 0.3 && !service.requests.isEmpty) {
                if !clock.jumpToNextWakeUp(notAfter: limit), limit.isFinite { clock.advance(by: limit - clock.now) }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
