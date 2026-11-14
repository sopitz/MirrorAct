// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import XCTest
@testable import MirrorAct

/// Translate in a mirror window, end to end without a window: frames go into a `FrameSink`,
/// Vision reads them, a stand-in engine translates, and the translations are drawn into what the
/// sink shows, on their text, also while it scrolls.
@MainActor
final class ScreenTranslatorTests: XCTestCase {
    /// Translates by putting "de:" in front, at once or when the test lets it
    private final class StandInEngine: TranslationEngine, @unchecked Sendable {
        let name = "Test"
        let isRemote = false
        let prefersSettledText = false
        var notify: ((String) -> Void)?

        private let lock = NSLock()
        private var held: [CheckedContinuation<Void, Never>] = []
        private var holding: Bool
        private var requestCount = 0
        private var answerCount = 0
        private var cancelled = false

        init(holding: Bool = false) {
            self.holding = holding
        }

        func translate(_ texts: [String], into target: Locale.Language) async throws -> [String?] {
            let hold: Bool = locked {
                requestCount += 1
                return holding
            }
            if hold {
                await withCheckedContinuation { continuation in
                    locked { held.append(continuation) }
                }
            }
            locked { answerCount += 1 }
            return texts.map { "de:" + $0 }
        }

        func cancel() { locked { cancelled = true } }

        /// lets the requests that wait go on, and the next ones too
        func release() {
            let waiting: [CheckedContinuation<Void, Never>] = locked {
                holding = false
                defer { held = [] }
                return held
            }
            waiting.forEach { $0.resume() }
        }

        var requests: Int { locked { requestCount } }
        var answers: Int { locked { answerCount } }
        var waiting: Int { locked { held.count } }
        var wasCancelled: Bool { locked { cancelled } }

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
        TestFrames.Line(text: "Privacy and Security", x: 60, top: 600),
    ]

    private var sink: FrameSink!
    private var translator: ScreenTranslator!

    override func setUp() async throws {
        sink = FrameSink()
        translator = ScreenTranslator(sink: sink)
    }

    override func tearDown() async throws {
        translator.stop()
        translator = nil
        sink = nil
    }

    func testTranslationsAreDrawnOnTheirTextAndFollowItInBGRA() async throws {
        try await checkTranslationsFollowTheText(format: kCVPixelFormatType_32BGRA)
    }

    func testTranslationsAreDrawnOnTheirTextAndFollowItIn420() async throws {
        try await checkTranslationsFollowTheText(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    private func checkTranslationsFollowTheText(format: OSType) async throws {
        let engine = StandInEngine()
        translator.makeEngine = { _ in engine }
        let (still, inked) = try TestFrames.text(lines, width: width, height: height, format: format)
        sink.push(still)
        translator.start()
        XCTAssertTrue(translator.isActive)
        XCTAssertTrue(sink.processor === translator)

        // a still screen: nothing but the translator itself brings the translations in
        let drawn = await waitFor { self.drawnArea() }
        let first = try XCTUnwrap(drawn, "no translation was drawn (engine asked \(engine.requests) times)")
        XCTAssertTrue(sink.latestSource === still, "Text and the recognition must keep reading the device's frame")
        XCTAssertTrue(inked.contains { $0.intersects(first) }, "drawn at \(first), the text is at \(inked)")
        for line in inked {
            XCTAssertTrue(first.insetBy(dx: -4, dy: -4).contains(line) || !first.intersects(line),
                          "a box covers \(line) only in part: \(first)")
        }

        // scrolling up by 40 pixels, a few at a time as at 60 frames per second
        let scrolled = try (1...10).map { step in
            try TestFrames.text(TestFrames.shifted(lines, by: -4 * CGFloat(step)),
                                width: width, height: height, format: format).frame
        }
        for frame in scrolled {
            sink.push(frame)
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        let moved = await waitFor { () -> CGRect? in
            guard let area = self.drawnArea(), abs(area.minY - (first.minY - 40)) <= 6 else { return nil }
            return area
        }
        XCTAssertNotNil(moved, "the translations did not follow the text: \(String(describing: drawnArea())), first \(first)")

        translator.stop()
        XCTAssertFalse(translator.isActive)
        XCTAssertNil(sink.processor)
        XCTAssertTrue(sink.latest === sink.latestSource, "the device's own picture must be back at once")
        XCTAssertTrue(engine.wasCancelled)
    }

    /// A translation still on its way when Translate is turned off is not drawn, also not into
    /// the turn that is on by the time it arrives, which reads the same text
    func testTranslationArrivingAfterStopIsNotDrawn() async throws {
        let stale = StandInEngine(holding: true)
        translator.makeEngine = { _ in stale }
        let (still, _) = try TestFrames.text(lines, width: width, height: height, format: kCVPixelFormatType_32BGRA)
        sink.push(still)
        translator.start()
        let asked = await waitFor { stale.waiting > 0 ? true : nil }
        XCTAssertNotNil(asked, "the engine was not asked")
        translator.stop()

        // the next turn has read the same text and waits for its own engine
        let fresh = StandInEngine(holding: true)
        translator.makeEngine = { _ in fresh }
        translator.start()
        let askedAgain = await waitFor { fresh.waiting > 0 ? true : nil }
        XCTAssertNotNil(askedAgain, "the second turn did not ask its engine")

        stale.release()
        let answered = await waitFor { stale.answers > 0 ? true : nil }
        XCTAssertNotNil(answered)
        // what would be drawn would be shown again right after the answer
        sink.push(still)
        let drawnLater = await waitFor(timeout: 1) { self.drawnArea() }
        XCTAssertNil(drawnLater, "a translation of a turn that was turned off was drawn")

        // the turn that is on draws its own translations
        fresh.release()
        let drawn = await waitFor { self.drawnArea() }
        XCTAssertNotNil(drawn, "the second turn drew nothing")
    }

    /// Off and on again: the second turn translates by itself, with its own engine
    func testTurningOnAgainTranslatesWithTheNewEngine() async throws {
        let stale = StandInEngine(holding: true)
        translator.makeEngine = { _ in stale }
        let (still, _) = try TestFrames.text(lines, width: width, height: height, format: kCVPixelFormatType_32BGRA)
        sink.push(still)
        translator.start()
        _ = await waitFor { stale.waiting > 0 ? true : nil }
        translator.stop()

        let fresh = StandInEngine()
        translator.makeEngine = { _ in fresh }
        translator.start()
        stale.release()
        let drawn = await waitFor { self.drawnArea() }
        XCTAssertNotNil(drawn, "the second turn drew nothing")
        XCTAssertGreaterThan(fresh.requests, 0)
        XCTAssertTrue(stale.wasCancelled)
    }

    /// No paragraph reaches across a known edge of a scrolling area. Vision's lines of a phone
    /// screen (1080 × 2400): the title in the bar and, right below the bar, a heading whose centre
    /// happens to lie below the title's; once the page has scrolled, the tracker knows where the
    /// bar ends.
    func testTheTitleOfABarAndTheTextBelowItAreNotOneParagraph() throws {
        let phone = CGSize(width: 1080, height: 2400)
        let lines = [("Testlabor", 171.0, 115.0, 247.0, 49.0), ("Hautige Fragen", 52.0, 206.0, 415.0, 52.0)].map { text, x, y, w, h in
            RecognizedLine(text: text, rect: CGRect(x: x / phone.width, y: y / phone.height, width: w / phone.width,
                                                    height: h / phone.height))
        }
        let frame = try TestFrames.blank(width: 1080, height: 2400, format: kCVPixelFormatType_32BGRA)
        let area = ScrollingArea(rect: CGRect(x: 24, y: 204, width: 1032, height: 2160),
                                 knownEdges: FrameMotion.top | FrameMotion.bottom)
        XCTAssertEqual(ScreenTranslator.recognizedBlocks(from: lines, in: frame, areas: [area]).map(\.text).sorted(),
                       ["Hautige Fragen", "Testlabor"])
        // (without the bar's edge the two would be taken for one paragraph)
        XCTAssertEqual(ScreenTranslator.recognizedBlocks(from: lines, in: frame, areas: []).count, 1)
    }

    /// With Android's keyboard up (Vision's lines of a web page with a search field, the keys,
    /// the strip of suggestions and the bottom row), nothing of the keyboard goes to the tracker,
    /// so nothing of it is sent or drawn: not from a reading of the whole picture, and not from a
    /// reading of the strip of suggestions alone, which changes with every key typed. The word
    /// typed into the field and the page above the keyboard are translated.
    func testNothingOfAnOnScreenKeyboardIsSentForTranslation() throws {
        let phone = TextLayoutKeyboardTests.phone
        let lines = TextLayoutKeyboardTests.webPage
        let frame = try TestFrames.blank(width: 1080, height: 2400, format: kCVPixelFormatType_32BGRA)
        let keyboard = TextLayout.keyboard(in: lines, imageSize: phone, region: nil, known: nil)
        let texts = ScreenTranslator.recognizedBlocks(from: lines, in: frame, areas: [], statusBar: .longerSide,
                                                      keyboard: keyboard).map(\.text)
        XCTAssertEqual(texts, [
            "Eingabe", "Suche im Katalog", "Wasserkocher", "Geben Sie oben ein Wort ein, nach dem gesucht werden soll.",
            "Ein ruhiger Absatz",
            "Dieser Absatz ändert sich nie. Er steht als Vergleich neben den Texten, die sich bewegen oder ändern, "
                + "und muss nach kurzer Zeit übersetzt sein und übersetzt bleiben.",
            "Hinweise zur Lieferung", "Pakete werden werktags zwischen acht und",
        ])
        // the strip read alone, after the keyboard was found
        let strip = lines.filter { $0.text.hasPrefix("Wasserkocher Washer") }
        let region = CGRect(x: 0, y: 1520, width: 1080, height: 110)
        let kept = TextLayout.keyboard(in: strip, imageSize: phone, region: region, known: keyboard)
        XCTAssertTrue(ScreenTranslator.recognizedBlocks(from: strip, in: frame, areas: [], statusBar: .longerSide,
                                                        keyboard: kept).isEmpty)
        // (before, the keys and the suggestions were sent)
        XCTAssertTrue(ScreenTranslator.recognizedBlocks(from: lines, in: frame, areas: [], statusBar: .longerSide)
            .contains { $0.text.contains("asdf") || $0.text.contains("Washer") })
    }

    /// The coarse picture of a keyboard's keys (`keySignature`): light keys with dark letters on a
    /// grey ground, the same with one key pressed (darker), and the page of the keyboard's ground
    /// that is left when the keyboard slid away, in BGRA and in 4:2:0
    func testTheKeysOfAKeyboardAreSeenToLeaveThePicture() throws {
        let width = 1080, height = 2400
        let keys = CGRect(x: 0, y: 1652, width: 1080, height: 402)
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            let up = try XCTUnwrap(ScreenTranslator.keySignature(
                of: TestFrames.frame(from: Self.keyboardPicture(pressed: false, keyboard: true), width: width, height: height, format: format),
                keys: keys))
            let typing = try XCTUnwrap(ScreenTranslator.keySignature(
                of: TestFrames.frame(from: Self.keyboardPicture(pressed: true, keyboard: true), width: width, height: height, format: format),
                keys: keys))
            let gone = try XCTUnwrap(ScreenTranslator.keySignature(
                of: TestFrames.frame(from: Self.keyboardPicture(pressed: false, keyboard: false), width: width, height: height, format: format),
                keys: keys))
            XCTAssertEqual(up.count, 2 * TextLayout.keyCells)
            XCTAssertFalse(TextLayout.keysChanged(from: up, to: typing))
            XCTAssertTrue(TextLayout.keysChanged(from: up, to: gone))
        }
    }

    /// A phone's picture of 1080 × 2400 in gray: a ground of the keyboard's colour, and when
    /// `keyboard`, light keys with dark letters over y 1652 to 2054, one of them pressed (darker)
    /// when `pressed`
    private static func keyboardPicture(pressed: Bool, keyboard: Bool) -> [UInt8] {
        let width = 1080, height = 2400
        var gray = [UInt8](repeating: 215, count: width * height)
        guard keyboard else { return gray }
        for y in 1652..<2054 {
            for x in 0..<width {
                let inKey = x % 108 > 8 && (y - 1652) % 134 > 10
                let letter = inKey && (40..<68).contains(x % 108) && (40..<90).contains((y - 1652) % 134)
                var level: UInt8 = letter ? 40 : (inKey ? 235 : 215)
                if pressed, inKey, x / 108 == 3, (y - 1652) / 134 == 1 { level = letter ? 40 : 150 }
                gray[y * width + x] = level
            }
        }
        return gray
    }

    /// The keyboard from one reading to the next, as the translator keeps it
    /// (`keyboardAfterReading`): found in a reading of the whole web page; kept through a reading
    /// of the strip of suggestions alone, of the two upper rows of letters alone (where it does
    /// not begin higher), of a band over most of the keys read in pieces, and while a key is
    /// pressed; ended by a reading of a part once the keys have left the picture, and by a reading
    /// of the whole picture that finds none. The picture of the keys is kept from the reading
    /// that found them.
    func testTheTranslatorKeepsTheKeyboardFromOneReadingToTheNext() throws {
        let width = 1080, height = 2400
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let up = try TestFrames.frame(from: Self.keyboardPicture(pressed: false, keyboard: true),
                                      width: width, height: height, format: format)
        let typing = try TestFrames.frame(from: Self.keyboardPicture(pressed: true, keyboard: true),
                                          width: width, height: height, format: format)
        let gone = try TestFrames.frame(from: Self.keyboardPicture(pressed: false, keyboard: false),
                                        width: width, height: height, format: format)
        let page = TextLayoutKeyboardTests.webPage
        let pageBottom = 1504.0  // "Pakete werden werktags zwischen acht und"
        // the whole picture
        let first = ScreenTranslator.keyboardAfterReading(page, in: up, region: nil, known: nil, knownKeys: nil)
        let found = try XCTUnwrap(first.keyboard)
        let keys = try XCTUnwrap(first.keys)
        XCTAssertGreaterThan(found.top, pageBottom)
        // the strip alone
        let strip = page.filter { $0.text.hasPrefix("Wasserkocher Washer") }
        let afterStrip = ScreenTranslator.keyboardAfterReading(strip, in: up, region: CGRect(x: 0, y: 1520, width: 1080, height: 110),
                                                               known: found, knownKeys: keys)
        XCTAssertEqual(afterStrip.keyboard, found)
        XCTAssertEqual(afterStrip.keys, keys)
        // the two upper rows alone
        let afterRows = ScreenTranslator.keyboardAfterReading(TextLayoutKeyboardTests.upperRowsOfWebPage, in: up,
                                                              region: TextLayoutKeyboardTests.upperRowsRegion,
                                                              known: found, knownKeys: keys)
        let rows = try XCTUnwrap(afterRows.keyboard)
        XCTAssertGreaterThan(rows.top, pageBottom)
        XCTAssertNotNil(afterRows.keys)
        // most of the keys, read in pieces, while a key is pressed
        let afterPieces = ScreenTranslator.keyboardAfterReading(TextLayoutKeyboardTests.webPageAndKeysInPieces, in: typing,
                                                                region: TextLayoutKeyboardTests.piecesRegion,
                                                                known: rows, knownKeys: afterRows.keys)
        XCTAssertEqual(afterPieces.keyboard, rows)
        XCTAssertEqual(afterPieces.keys, afterRows.keys)
        XCTAssertTrue(ScreenTranslator.recognizedBlocks(from: TextLayoutKeyboardTests.webPageAndKeysInPieces, in: typing,
                                                        areas: [], statusBar: .longerSide, keyboard: afterPieces.keyboard)
            .allSatisfy { Double($0.rect.maxY) <= pageBottom + 1 })
        // the keys have left: a line that came out from under them, read alone
        let revealed = [RecognizedLine(text: "achtzehn Uhr zugestellt. Wenn niemand zu",
                                       rect: CGRect(x: 52.0 / 1080, y: 1524.0 / 2400, width: 900.0 / 1080, height: 52.0 / 2400))]
        let afterGone = ScreenTranslator.keyboardAfterReading(revealed, in: gone, region: CGRect(x: 0, y: 1500, width: 1080, height: 100),
                                                              known: afterPieces.keyboard, knownKeys: afterPieces.keys)
        XCTAssertNil(afterGone.keyboard)
        XCTAssertNil(afterGone.keys)
        // a reading of the whole picture that finds none ends it, however the keys look
        let page2 = page.filter { $0.rect.maxY * CGFloat(height) < 1510 }
        XCTAssertNil(ScreenTranslator.keyboardAfterReading(page2, in: up, region: nil, known: found, knownKeys: keys).keyboard)
    }

    /// Android in landscape: the status bar has the height it has in portrait, so it is left out
    /// with a band in the longer side of the picture, and the content below it is translated
    func testTheStatusBarOfAndroidInLandscapeIsNotTranslated() throws {
        let landscape = CGSize(width: 2400, height: 1080)
        let lines = [("10:56 Uhr", 42.0, 17.0, 220.0, 37.0), ("Häufige Fragen zur App", 52.0, 206.0, 615.0, 52.0)]
            .map { text, x, y, w, h in
                RecognizedLine(text: text, rect: CGRect(x: x / landscape.width, y: y / landscape.height,
                                                        width: w / landscape.width, height: h / landscape.height))
            }
        let frame = try TestFrames.blank(width: 2400, height: 1080, format: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(ScreenTranslator.recognizedBlocks(from: lines, in: frame, areas: [], statusBar: .longerSide)
            .map(\.text), ["Häufige Fragen zur App"])
        XCTAssertEqual(MirrorSession.statusBar(of: .android), .longerSide)
        XCTAssertEqual(MirrorSession.statusBar(of: .cable), .heightOfPicture)
        XCTAssertEqual(MirrorSession.statusBar(of: .wireless), .heightOfPicture)
    }

    /// Android's settings in landscape: the icon of "Verbundene Geräte" read as "LoD" (a band of
    /// the picture read alone) is not sent, so no translation is drawn over the icon; its row is
    func testTheIconOfASettingsRowIsNotTranslated() throws {
        let landscape = CGSize(width: 2400, height: 1080)
        let lines = [("LoD", 105.0, 471.0, 63.0, 38.0), ("Verbundene Geräte", 206.0, 437.0, 460.0, 49.0),
                     ("Bluetooth, Kopplung", 209.0, 505.0, 328.0, 42.0)].map { text, x, y, w, h in
            RecognizedLine(text: text, rect: CGRect(x: x / landscape.width, y: y / landscape.height,
                                                    width: w / landscape.width, height: h / landscape.height))
        }
        let frame = try TestFrames.blank(width: 2400, height: 1080, format: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(ScreenTranslator.recognizedBlocks(from: lines, in: frame, areas: [], statusBar: .longerSide)
            .map(\.text), ["Verbundene Geräte", "Bluetooth, Kopplung"])
        // Text copies it: it keeps what could be a real short word there
        XCTAssertTrue(TextLayout.plainText(lines, imageSize: landscape, statusBar: .longerSide)
            .components(separatedBy: "\n").contains("LoD"))
    }

    /// The stated limit of Translate: a weekday centred before two opening times (Vision's boxes on
    /// a rendered page of 1080 × 2400) is taken for the icon of a row and stays untranslated. Text
    /// copies it.
    func testAWeekdayBeforeTwoOpeningTimesIsCopiedButNotTranslated() throws {
        let phone = CGSize(width: 1080, height: 2400)
        let lines = [("Mo", 56.0, 1266.0, 70.0, 49.0), ("09:00 - 12:00", 212.0, 1234.0, 293.0, 61.0),
                     ("14:00 - 18:00", 216.0, 1289.0, 227.0, 48.0)].map { text, x, y, w, h in
            RecognizedLine(text: text, rect: CGRect(x: x / phone.width, y: y / phone.height,
                                                    width: w / phone.width, height: h / phone.height))
        }
        let frame = try TestFrames.blank(width: 1080, height: 2400, format: kCVPixelFormatType_32BGRA)
        XCTAssertFalse(ScreenTranslator.recognizedBlocks(from: lines, in: frame, areas: [], statusBar: .longerSide)
            .contains { $0.text.contains("Mo") })
        XCTAssertTrue(TextLayout.plainText(lines, imageSize: phone, statusBar: .longerSide)
            .components(separatedBy: "\n").contains("Mo"))
    }

    func testWithoutAFrameTranslateDoesNotStart() {
        var messages: [String] = []
        translator.onMessage = { messages.append($0) }
        translator.makeEngine = { _ in StandInEngine() }
        translator.start()
        XCTAssertFalse(translator.isActive)
        XCTAssertNil(sink.processor)
        XCTAssertEqual(messages.count, 1)
    }

    func testAnEngineThatCannotBeMadeKeepsTranslateOff() throws {
        var messages: [String] = []
        translator.onMessage = { messages.append($0) }
        translator.makeEngine = { _ in throw TranslationFailure(message: "Enter the key", isPermanent: true) }
        sink.push(try TestFrames.blank(width: 64, height: 64, format: kCVPixelFormatType_32BGRA))
        translator.start()
        XCTAssertFalse(translator.isActive)
        XCTAssertNil(sink.processor)
        XCTAssertEqual(messages, ["Enter the key"])
    }

    // MARK: Helpers

    /// Where what is shown differs from the device's frame; nil while it is the same
    private func drawnArea() -> CGRect? {
        guard let shown = sink.latest, let source = sink.latestSource, shown !== source else { return nil }
        return TestFrames.difference(shown, source)
    }

    /// Polls `condition` until it gives a value or `timeout` (seconds) has passed
    private func waitFor<T>(timeout: TimeInterval = 15, _ condition: () -> T?) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = condition() { return value }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
}
