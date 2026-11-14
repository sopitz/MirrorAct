// SPDX-License-Identifier: GPL-3.0-or-later
import CoreText
import Foundation
import XCTest
@testable import MirrorAct

/// What changes in place is read at once, and what keeps changing in one place without bringing
/// anything new to translate costs few passes: a change in a line is read with the whole line,
/// text typed into a field is translated as soon as it shows, and the caret that blinks after
/// it is not read again and again. Screens of a phone 1080 × 2400 (thumbnails at scale 3), as
/// in the lab.
final class OverlayTrackerChangingTests: XCTestCase {
    typealias Line = OverlayTrackerRestTests.Line
    private static let scale = 3, width = 1080, height = 2400

    /// What a frame shows: lines, carets (frame pixels, filled dark) and bars (thumbnail pixels,
    /// filled dark after the reduction)
    private struct Scene {
        var lines: [Line]
        var carets: [CGRect] = []
        var bars: [ThumbnailRect] = []

        var key: String {
            lines.map { "\($0.text)@\($0.top),\($0.left),\($0.fontSize)" }.joined(separator: "|")
                + carets.map { "c\($0)" }.joined()
        }
    }

    private var pictures: [String: LumaImage] = [:]

    /// The thumbnail of a scene, without noise
    private func picture(_ scene: Scene) -> LumaImage {
        let key = scene.key
        var base: LumaImage
        if let known = pictures[key] {
            base = known
        } else {
            var gray = [UInt8](repeating: 245, count: Self.width * Self.height)
            gray.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: Self.width, height: Self.height,
                                              bitsPerComponent: 8, bytesPerRow: Self.width,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                for line in scene.lines {
                    line.draw(in: context, frameHeight: Self.height)
                }
                context.setFillColor(CGColor(gray: 0.1, alpha: 1))
                for caret in scene.carets {
                    context.fill(CGRect(x: caret.minX, y: Double(Self.height) - caret.maxY, width: caret.width,
                                        height: caret.height))
                }
            }
            base = gray.withUnsafeBytes { bytes in
                LumaImage.downsampled(from: bytes.baseAddress!, width: Self.width, height: Self.height,
                                      bytesPerRow: Self.width, format: .luma8, scale: Self.scale)
            }
            if pictures.count > 64 { pictures = [:] }
            pictures[key] = base
        }
        for bar in scene.bars {
            for y in bar.y..<bar.maxY {
                for x in bar.x..<bar.maxX {
                    base[x, y] = 60
                }
            }
        }
        return base
    }

    private struct Run {
        /// when each pass began
        var passes: [TimeInterval] = []
        var sent: [String] = []
        func passes(from start: TimeInterval, to end: TimeInterval) -> Int {
            passes.filter { $0 >= start && $0 < end }.count
        }
    }

    /// Shows `scene(time)` at `fps` from `start` for `seconds`; passes take 0.3 s and read the
    /// lines of the frame they began on in their region; what is asked for is translated at once
    /// ("T " + text; a text without letters comes back as it is, as from a translator: nothing
    /// to show). `each` gets every frame's time and the texts drawn into it.
    private func run(_ tracker: OverlayTracker, from start: TimeInterval, seconds: Double, fps: Double = 30,
                     seed: inout UInt64, scene: (TimeInterval) -> Scene,
                     each: (TimeInterval, [String]) -> Void = { _, _ in },
                     begun: (CGRect) -> Void = { _ in }) -> Run {
        var result = Run()
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        var frame = 0
        while true {
            let time = start + Double(frame) / fps
            guard time < start + seconds else { break }
            frame += 1
            seed += 1
            let shown = scene(time)
            let image = SyntheticPage.noisy(picture(shown), amount: 2, seed: seed)
            let placed = tracker.advance(image, scale: Self.scale, time: time).placed.map(\.text)
            each(time, placed)
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                result.passes.append(time)
                begun(request.region)
                pending = (request, shown.lines.compactMap { $0.reading(in: request.region) }, time + 0.3)
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                result.sent.append(text)
                tracker.setTranslation(text.contains(where: \.isLetter) ? "T " + text : text, for: text)
            }
        }
        return result
    }

    // MARK: Scenes

    private static let heading = Line(text: "Wasserkocher bestellen", top: 600, fontSize: 63)
    private static let note = Line(text: "Die Lieferung dauert drei Tage", top: 1500, fontSize: 42,
                                   fontName: "Helvetica")

    /// The text of a field and its caret, 4 pixels wide, 2 pixels after the text
    private static func field(_ text: String) -> (line: Line, caret: CGRect) {
        let line = Line(text: text, top: 1000, fontSize: 48, fontName: "Helvetica")
        let font = CTFontCreateWithName(line.fontName as CFString, line.fontSize, nil)
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font]))
        let end = line.left + Double(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        return (line, CGRect(x: end + 2, y: line.top - 4, width: 4, height: line.height + 8))
    }

    /// A still page with a field whose caret blinks every 0.53 s (two pictures taking turns)
    private static func caretScene(_ time: TimeInterval, text: String = "Wasserkocher") -> Scene {
        let field = field(text)
        let on = Int(time / 0.53) % 2 == 0
        return Scene(lines: [heading, field.line, note], carets: on ? [field.caret] : [])
    }

    // MARK: What must stay prompt

    /// The tracker as it was before what keeps changing cost little: nothing is known of a
    /// place's pictures
    private static let unchanged: OverlayTracker.Configuration = {
        var configuration = OverlayTracker.Configuration()
        configuration.knownTilePictures = 0
        return configuration
    }()

    /// For each (time, text): how long after that time the translation of `text` was first
    /// drawn (nil = never), with `scene` shown from 0 to `seconds`
    private func delays(_ configuration: OverlayTracker.Configuration, seconds: Double, fps: Double = 30,
                        scene: (TimeInterval) -> Scene, checks: [(time: TimeInterval, text: String)]) -> [Double?] {
        var seed: UInt64 = 3
        var result = [Double?](repeating: nil, count: checks.count)
        _ = run(OverlayTracker(configuration: configuration), from: 0, seconds: seconds, fps: fps, seed: &seed,
                scene: scene) { time, placed in
            for (index, check) in checks.enumerated() where result[index] == nil && time >= check.time
                && placed.contains("T " + check.text) {
                result[index] = time - check.time
            }
        }
        return result
    }

    /// Text typed into the field, a letter every 0.7 s, after its caret blinked for 3 s (its
    /// two pictures are known then), with a counter below the field that ticks with every
    /// letter, then a word at once: the caret stays on while keys come and blinks again 0.5 s
    /// after the last. Tried with the typing starting at four points of the caret's blink, at
    /// 15 frames a second. The text and the counter are translated as soon as when nothing was
    /// known of the field's pictures: none later by more than a frame on average, and the latest
    /// no later than before or a second; and at least as many of their states as before a
    /// change was read with its line (45 of the 56). A debug build plays the first of the four
    /// points, and 2 s after the word instead of 4 (12 of its 14, `TestBuild`).
    func testTextTypedAfterTheBlinkingCaretIsTranslatedAsSoonAsBefore() {
        var before: [Double?] = [], after: [Double?] = []
        let phases = TestBuild.playsEverything ? 4 : 1
        for phase in 0..<phases {
            let begin = 3 + 0.14 * Double(phase)
            var states: [(time: TimeInterval, text: String)] = [(0, "Wasser")]
            for letter in "kocher" {
                states.append((begin + 0.7 * Double(states.count - 1), states.last!.text + String(letter)))
            }
            states.append((states.last!.time + 4, states.last!.text + " Kanne"))
            func scene(_ time: TimeInterval) -> Scene {
                let state = states.last { $0.time <= time }!
                let field = Self.field(state.text)
                let idle = time - state.time
                let on = state.time == 0 ? Int(time / 0.53) % 2 == 0 : idle < 0.5 || Int((idle - 0.5) / 0.53) % 2 == 1
                let counter = Line(text: "Noch \(40 - state.text.count) Zeichen", top: 1090, fontSize: 36,
                                   fontName: "Helvetica")
                return Scene(lines: [Self.heading, field.line, counter, Self.note], carets: on ? [field.caret] : [])
            }
            var checks: [(time: TimeInterval, text: String)] = []
            for state in states.dropFirst() {
                checks.append((state.time, state.text))
                checks.append((state.time, "Noch \(40 - state.text.count) Zeichen"))
            }
            let end = states.last!.time + (phases == 4 ? 4 : 2)
            before += delays(Self.unchanged, seconds: end, fps: 15, scene: scene, checks: checks)
            after += delays(OverlayTracker.Configuration(), seconds: end, fps: 15, scene: scene, checks: checks)
        }
        func summary(_ list: [Double?]) -> (count: Int, mean: Double, worst: Double) {
            let found = list.compactMap { $0 }
            return (found.count, found.reduce(0, +) / Double(max(1, found.count)), found.max() ?? 0)
        }
        let old = summary(before), new = summary(after)
        print("CHANGING typed: before \(old) after \(new) of \(before.count)")
        print("CHANGING typed before: \(before.map { $0.map { String(format: "%.2f", $0) } ?? "-" })")
        print("CHANGING typed after:  \(after.map { $0.map { String(format: "%.2f", $0) } ?? "-" })")
        // 45 of the 56 states were translated before a change in a known line was read with
        // that line; nothing known of the pictures (`before`) is not that state and may do better
        XCTAssertGreaterThanOrEqual(new.count, phases == 4 ? 45 : 12)
        XCTAssertLessThanOrEqual(new.mean, old.mean + 1.0 / 15)
        XCTAssertLessThanOrEqual(new.worst, max(old.worst, 1))
    }

    /// A word typed at once at the end of a field's text (no caret on the page): the change is
    /// read with the whole line, and the new text is translated within a second. Read with only
    /// the room around the change, the line was cut on the left, read again a little farther
    /// each time, and translated after 1.5 s, by the fifth pass.
    func testAWordTypedAtTheEndOfALineIsReadWithItsLine() {
        func scene(_ time: TimeInterval) -> Scene {
            let text = time < 4 ? "Wasserkocher" : "Wasserkocher Kanne"
            let counter = Line(text: "Noch \(40 - text.count) Zeichen", top: 1090, fontSize: 36, fontName: "Helvetica")
            return Scene(lines: [Self.heading, Self.field(text).line, counter, Self.note])
        }
        var regions: [CGRect] = []
        var seed: UInt64 = 3
        var drawn: TimeInterval?
        let tracker = OverlayTracker()
        let result = run(tracker, from: 0, seconds: 7, seed: &seed, scene: scene) { time, placed in
            if drawn == nil, placed.contains("T Wasserkocher Kanne") { drawn = time }
        } begun: { regions.append($0) }
        print("CHANGING word: drawn \(drawn.map { $0 - 4 } ?? -1) passes \(result.passes.filter { $0 >= 4 })")
        XCTAssertLessThan((drawn ?? .infinity) - 4, 1)
        XCTAssertEqual(result.sent.filter { $0.hasPrefix("Wasserkocher") && $0 != Self.heading.text }, ["Wasserkocher", "Wasserkocher Kanne"])
        XCTAssertLessThanOrEqual(result.passes(from: 4, to: 7), 2, "\(regions)")
    }

    /// A line with a mark at its end that changes in every frame (an animation that never comes
    /// to rest): when the line's text changes, it is translated within a second, as before the
    /// line was read whole with a change in it
    func testATextBesideAnAnimationIsTranslatedWithinASecond() {
        func scene(_ time: TimeInterval) -> Scene {
            let field = Self.field(time < 4 ? "Wird geladen" : "Wird gesichert")
            let step = Int((time * 30).rounded()) % 8
            let mark = CGRect(x: field.caret.minX + 20 + Double(step) * 4, y: field.caret.minY + 8, width: 6, height: 30)
            return Scene(lines: [Self.heading, field.line, Self.note], carets: [mark])
        }
        let delay = delays(OverlayTracker.Configuration(), seconds: 7, scene: scene, checks: [(4, "Wird gesichert")])
        print("CHANGING animation: \(delay)")
        XCTAssertLessThan(delay[0] ?? .infinity, 1)
    }

    /// While the caret blinks (its pictures known), a message comes in above the field, then a
    /// dialog of three lines appears over the page: each is translated as soon as before. (A
    /// debug build plays the message only, `TestBuild`.)
    func testWhatAppearsBesideTheBlinkingCaretIsTranslatedAsSoonAsBefore() {
        let everything = TestBuild.playsEverything
        let message = Line(text: "Anna: Brauchst du noch etwas", top: 880, fontSize: 42, fontName: "Helvetica")
        let dialog = [Line(text: "Bestellung abschicken", top: 1250, fontSize: 52),
                      Line(text: "Der Betrag wird sofort belastet", top: 1330, fontSize: 40, fontName: "Helvetica"),
                      Line(text: "Abbrechen", top: 1400, fontSize: 40, fontName: "Helvetica")]
        func scene(_ time: TimeInterval) -> Scene {
            var shown = Self.caretScene(time)
            if time >= 6 { shown.lines.append(message) }
            if time >= 9 { shown.lines += dialog }
            return shown
        }
        let checks = [(time: 6.0, text: message.text)] + (everything ? dialog.map { (time: 9.0, text: $0.text) } : [])
        let seconds = everything ? 12.0 : 7
        let before = delays(Self.unchanged, seconds: seconds, scene: scene, checks: checks)
        let after = delays(OverlayTracker.Configuration(), seconds: seconds, scene: scene, checks: checks)
        print("CHANGING beside: before \(before) after \(after)")
        for index in checks.indices {
            XCTAssertNotNil(after[index], checks[index].text)
            XCTAssertLessThanOrEqual(after[index] ?? .infinity, (before[index] ?? .infinity) + 0.05, checks[index].text)
        }
    }

    /// A counter in the line below the field counts down every half second while the caret
    /// blinks: each of its values is translated before the next replaces it, as on a page
    /// without the caret. (A pass that read a new value forgot what was known of every tile of
    /// its region, the caret's too; the caret was read again with its line at the next blink, and
    /// that pass kept the counter's next value waiting: a third of the values were never drawn.)
    /// A debug build plays the first 12 values, of which one may be missed (`TestBuild`).
    func testACounterBesideTheBlinkingCaretKeepsItsValues() {
        let values = TestBuild.playsEverything ? 40 : 12
        func counter(_ time: TimeInterval) -> Line {
            let value = time < 6 ? 60 : 60 - Int((time - 6) / 0.5)
            return Line(text: "Noch \(value) Zeichen", top: 1090, fontSize: 36, fontName: "Helvetica")
        }
        var checks: [(time: TimeInterval, text: String)] = []
        for step in 0..<values { checks.append((6 + 0.5 * Double(step), "Noch \(60 - step) Zeichen")) }
        let delays = delays(OverlayTracker.Configuration(), seconds: 6 + 0.5 * Double(values) + 1, scene: { time in
            var shown = Self.caretScene(time)
            shown.lines.append(counter(time))
            return shown
        }, checks: checks)
        let found = delays.compactMap { $0 }
        print("CHANGING counter: \(found.count) of \(checks.count), worst \(found.max() ?? -1)")
        XCTAssertGreaterThanOrEqual(found.count, checks.count - (values == 40 ? 2 : 1))
        XCTAssertLessThan(found.max() ?? .infinity, 0.5)
    }

    /// Nothing known of the caret's pictures survives a reset (Translate turned off and on):
    /// the tracker holds nothing right after it, and the caret's place is read again as at first
    func testWhatIsKnownOfAPlaceDoesNotSurviveAReset() {
        var seed: UInt64 = 5
        let tracker = OverlayTracker()
        let first = run(tracker, from: 0, seconds: 8, seed: &seed) { Self.caretScene($0) }
        XCTAssertEqual(first.passes(from: 5, to: 8), 0)
        tracker.reset()
        // (`heldItemCount` counts the known pictures; a reset leaves nothing held)
        XCTAssertEqual(tracker.heldItemCount, 0)
        let again = run(tracker, from: 8, seconds: 4, seed: &seed) { Self.caretScene($0) }
        XCTAssertGreaterThanOrEqual(again.passes(from: 8.5, to: 12), 1)
    }

    /// What the tracker shows of itself for a look at it (`readingState`): how many pictures it
    /// knows to hold nothing new (the caret's, none after a reset), and for a change in a known
    /// line the line it is read with, in frame pixels like the place
    func testTheReadingStateShowsKnownPicturesAndTheLineAChangeIsReadWith() {
        var seed: UInt64 = 5
        let tracker = OverlayTracker()
        _ = run(tracker, from: 0, seconds: 6, fps: 15, seed: &seed) { Self.caretScene($0) }
        XCTAssertGreaterThan(tracker.readingState.knownTilePictures, 0)
        tracker.reset()
        XCTAssertEqual(tracker.readingState.knownTilePictures, 0)

        let line = Self.field("Wasserkocher Kanne").line
        var withLine: [(rect: CGRect, line: CGRect)] = []
        // (the place is asked for when the word shows and read 0.12 s later: look at every frame)
        let tracker2 = OverlayTracker()
        _ = run(tracker2, from: 0, seconds: 5, fps: 15, seed: &seed, scene: { time in
            Scene(lines: [Self.heading, Self.field(time < 3 ? "Wasserkocher" : "Wasserkocher Kanne").line, Self.note])
        }, each: { _, _ in
            for place in tracker2.readingState.places {
                if let readWith = place.readWith { withLine.append((place.rect, readWith)) }
            }
        })
        XCTAssertFalse(withLine.isEmpty)
        for entry in withLine {
            // the whole line of the field, beyond the change at its end
            XCTAssertLessThanOrEqual(entry.line.minX, line.left + 10)
            XCTAssertGreaterThan(entry.line.width, entry.rect.width)
            XCTAssertTrue(entry.line.intersects(CGRect(x: line.left, y: line.top, width: 600, height: line.height)))
        }
    }

    // MARK: What keeps changing

    /// Counts the passes over 60 s (10 frames a second) and 600 s (5 frames a second) after
    /// 5 s in which the page is read and translated; a debug build plays 20 s at 10 frames a
    /// second only (`TestBuild`)
    private func passes(_ scene: (TimeInterval) -> Scene) -> (minute: Int, tenMinutes: Int?, sent: [String]) {
        var seed: UInt64 = 1
        let tracker = OverlayTracker()
        guard TestBuild.playsEverything else {
            let first = run(tracker, from: 0, seconds: 25, fps: 10, seed: &seed, scene: scene)
            return (first.passes(from: 5, to: 25), nil, first.sent)
        }
        let first = run(tracker, from: 0, seconds: 65, fps: 10, seed: &seed, scene: scene)
        let long = run(OverlayTracker(), from: 0, seconds: 605, fps: 5, seed: &seed, scene: scene)
        return (first.passes(from: 5, to: 65), long.passes(from: 5, to: 605), first.sent)
    }

    /// The caret of a field blinks beside its text on a still page. Every blink changed the
    /// picture, the place of the caret was read 0.12 s later, and so the line about twice a
    /// second for as long as the field had focus (four times on the phone, at a third of a
    /// core), and the bound on the passes over a picture that does not change never applied.
    func testABlinkingCaretIsNotReadAgainAndAgain() {
        let counts = passes { Self.caretScene($0) }
        print("CHANGING caret: \(counts.minute) passes in the first part, \(counts.tenMinutes.map(String.init) ?? "-") in 600 s")
        XCTAssertEqual(Set(counts.sent), [Self.heading.text, "Wasserkocher", Self.note.text])
        XCTAssertLessThanOrEqual(counts.minute, 6)
        if let tenMinutes = counts.tenMinutes { XCTAssertLessThanOrEqual(tenMinutes, 6) }
    }

    // MARK: Lines left out of the readings

    /// When the field and a value below it lie under a keyboard whose top was placed too high,
    /// the caller leaves their lines out of the readings while the keyboard shows (here for
    /// 4 s, its keys a bar at the bottom). The keyboard goes, the page does not move, and
    /// nothing changes in those lines afterwards. Passes over them had brought nothing new,
    /// so nothing read them again: they are read within 1.5 s once the caller says that they
    /// are no longer left out (`linesNoLongerLeftOut`, at the end of the first reading begun
    /// after the keyboard went, as `ScreenTranslator` does), and never without it. 10 frames a
    /// second, 3 s after the keyboard.
    func testLinesLeftOutUnderAKeyboardAreReadOnceItHasGone() {
        let gone: TimeInterval = 4, leftOutBelow = 950.0
        let field = Self.field("Wasserkocher")
        let value = Line(text: "Noch 28 Zeichen", top: 1100, fontSize: 42, fontName: "Helvetica")
        let lines = [Self.heading, field.line, value]
        let keys = ThumbnailRect(x: 0, y: 500, width: 360, height: 300)
        func drawn(sayingSo: Bool) -> (field: Double?, value: Double?) {
            let tracker = OverlayTracker()
            var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval, begun: TimeInterval)?
            var seed: UInt64 = 5, said = false
            var result: (field: Double?, value: Double?) = (nil, nil)
            for frame in 0..<70 {
                let time = Double(frame) / 10, shown = time < gone
                seed += 1
                let scene = Scene(lines: lines, carets: shown ? [field.caret] : [], bars: shown ? [keys] : [])
                let image = SyntheticPage.noisy(picture(scene), amount: 2, seed: seed)
                let placed = tracker.advance(image, scale: Self.scale, time: time).placed.map(\.text)
                if !shown {
                    if result.field == nil, placed.contains("T " + field.line.text) { result.field = time - gone }
                    if result.value == nil, placed.contains("T " + value.text) { result.value = time - gone }
                }
                if let job = pending, time >= job.at {
                    if sayingSo, !said, job.begun >= gone {
                        said = true
                        tracker.linesNoLongerLeftOut(in: CGRect(x: 0, y: leftOutBelow, width: Double(Self.width),
                                                                height: Double(Self.height) - leftOutBelow), time: time)
                    }
                    tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                    pending = nil
                }
                if pending == nil, let due = tracker.recognitionDue, due <= time,
                   let request = tracker.beginRecognition(time: time) {
                    let read = lines.filter { !shown || $0.top < leftOutBelow }
                    pending = (request, read.compactMap { $0.reading(in: request.region) }, time + 0.3, time)
                }
                for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                    tracker.setTranslation(text.contains(where: \.isLetter) ? "T " + text : text, for: text)
                }
            }
            return result
        }
        let with = drawn(sayingSo: true), without = drawn(sayingSo: false)
        print("CHANGING left out: field \(with.field ?? -1) value \(with.value ?? -1) s after the keyboard went; "
              + "without saying so field \(without.field ?? -1) value \(without.value ?? -1)")
        XCTAssertLessThan(with.field ?? .infinity, 1.5)
        XCTAssertLessThan(with.value ?? .infinity, 1.5)
        XCTAssertNil(without.field)
    }
}
