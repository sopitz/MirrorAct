// SPDX-License-Identifier: GPL-3.0-or-later
import CoreText
import Foundation
import XCTest
@testable import MirrorAct

/// Texts that differ only in their numbers: a summary whose value ticks in place, and the rows of
/// a list that look alike but for a number. No translation is drawn over a text it was not made
/// from: one whose numbers differ from those of the text under it is wrong, however much else the
/// two texts share. The screens are those of a phone 1080 × 2400 (thumbnails at scale 3), as in
/// the lab.
final class OverlayTrackerNumbersTests: XCTestCase {
    typealias Line = OverlayTrackerRestTests.Line
    private static let scale = 3, width = 1080, height = 2400

    /// The thumbnail of a plain page with `lines` (without noise)
    private static func picture(_ lines: [Line]) -> LumaImage {
        var gray = [UInt8](repeating: 245, count: width * height)
        gray.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            for line in lines where line.top + line.height > 0 && line.top < Double(height) {
                line.draw(in: context, frameHeight: height)
            }
        }
        return gray.withUnsafeBytes { bytes in
            LumaImage.downsampled(from: bytes.baseAddress!, width: width, height: height, bytesPerRow: width,
                                  format: .luma8, scale: scale)
        }
    }

    /// Runs the tracker over frames at `times` whose lines `lines(frame)` gives; passes take 0.3 s
    /// and read what the lines showed when they started (`read`); what is asked for is translated
    /// at once ("T " + text), unless `translates` is false. `each` gets the frame's number, its
    /// lines and what was placed. Returns the texts sent for translation.
    /// (`readAll`, when given, reads all lines of a frame at once instead of `read`: lines of a
    /// paragraph come as one block; `noise` is how much each pixel may differ from the picture.)
    @discardableResult
    private func run(_ tracker: OverlayTracker, times: [TimeInterval], seed: UInt64, lines: (Int) -> [Line],
                     read: (Int, Line, CGRect) -> RecognizedBlock? = { _, line, region in line.reading(in: region) },
                     readAll: ((Int, [Line], CGRect) -> [RecognizedBlock])? = nil, noise: Int = 2,
                     translates: Bool = true, each: (Int, [Line], [PlacedBlock]) -> Void = { _, _, _ in }) -> [String] {
        var sent: [String] = []
        var seed = seed
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        for (frame, time) in times.enumerated() {
            seed += 1
            let shown = lines(frame)
            let picture = SyntheticPage.noisy(Self.picture(shown), amount: noise, seed: seed)
            let placed = tracker.advance(picture, scale: Self.scale, time: time).placed
            each(frame, shown, placed)
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                let answer = readAll?(frame, shown, request.region) ?? shown.compactMap { read(frame, $0, request.region) }
                pending = (request, answer, time + 0.3)
            }
            guard translates else { continue }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                sent.append(text)
                tracker.setTranslation("T " + text, for: text)
            }
        }
        return sent
    }

    // MARK: A value that ticks in place

    /// A row of a settings list on a still page, as the lab's page change2.html: a bold title
    /// over a grey summary whose value ticks every 3 s ("41 % belegt, 87 GB frei" … "46 % …").
    /// The first time it shows 43 %, the summary is read without its last word ("43 % belegt,
    /// 85 GB": the edge of what a pass read fell in the space before "frei", as on the phone).
    /// No frame shows a translation of the summary with other numbers than those on the screen,
    /// the title keeps its translation, and every value is sent once – after the cut one, whole
    /// again. (Before, the translation of the old value stayed drawn over the new one until the
    /// next reading replaced it, about a second at every tick; on the phone, where that reading
    /// could not be taken, for up to 40 s.)
    func testASummaryIsNeverDrawnWithAnotherValue() {
        let tracker = OverlayTracker()
        let title = Line(text: "Speicherplatz", top: 1363, fontSize: 52)
        func summary(_ used: Int) -> Line {
            Line(text: "\(used) % belegt, \(128 - used) GB frei", top: 1460, fontSize: 42, fontName: "Helvetica")
        }
        let shownValue = [41, 42, 43, 44, 45, 46].flatMap { Array(repeating: $0, count: 90) }
        let cutFrames = 180..<270
        var wrong: [String] = [], right = 0, titleMissing = 0
        let sent = run(tracker, times: shownValue.indices.map { Double($0) / 30 }, seed: 1,
                       lines: { [title, summary(shownValue[$0])] },
                       read: { frame, line, region in
            guard var reading = line.reading(in: region) else { return nil }
            if cutFrames.contains(frame), line.text.hasSuffix(" frei"), reading.text == line.text {
                reading.text = String(line.text.dropLast(" frei".count))
                reading.rect.size.width *= Double(reading.text.count) / Double(line.text.count)
            }
            return reading
        }) { frame, lines, placed in
            guard frame >= 30 else { return }
            if !placed.contains(where: { $0.text == "T " + title.text }) { titleMissing += 1 }
            for block in placed where block.text.contains("% belegt") {
                if TextSimilarity.numbers(of: block.text) == TextSimilarity.numbers(of: lines[1].text) {
                    right += 1
                } else if wrong.count < 5 {
                    wrong.append("frame \(frame): \(block.text) over \(lines[1].text)")
                }
            }
        }
        XCTAssertEqual(wrong, [])
        XCTAssertEqual(titleMissing, 0)
        XCTAssertEqual(sent, ["Speicherplatz", "41 % belegt, 87 GB frei", "42 % belegt, 86 GB frei", "43 % belegt, 85 GB",
                              "44 % belegt, 84 GB frei", "45 % belegt, 83 GB frei", "46 % belegt, 82 GB frei"])
        // (each value drawn for most of its 3 s)
        XCTAssertGreaterThan(right, 5 * 60, "\(right)")
    }

    // MARK: A paragraph whose number changes in place

    /// What a recognizer reads of `lines` in `region`: the lines of `paragraph` (indices into
    /// `lines`) that it reads, as one block of their texts joined with a space; every other line
    /// on its own
    /// (`apart`: each line of the paragraph as a block of its own, as Vision sometimes returns them)
    private static func readings(of lines: [Line], paragraph: Range<Int>, in region: CGRect,
                                 apart: Bool = false) -> [RecognizedBlock] {
        var result: [RecognizedBlock] = []
        var parts: [RecognizedBlock] = []
        for (index, line) in lines.enumerated() {
            guard let reading = line.reading(in: region) else { continue }
            if paragraph.contains(index), !apart { parts.append(reading) } else { result.append(reading) }
        }
        if let first = parts.first {
            result.append(RecognizedBlock(text: parts.map(\.text).joined(separator: " "),
                                          rect: parts.dropFirst().reduce(first.rect) { $0.union($1.rect) },
                                          lineCount: parts.count))
        }
        return result
    }

    /// A page with a title over a paragraph whose lines `paragraph(value)` gives, its number
    /// showing each of `values` for `seconds` (30 frames a second), the page scrolled up by
    /// `scroll` pixels a second during `moving` (by default from half a second before each change
    /// of the number to half a second after it). Counts the frames that show a translation of the
    /// paragraph with other numbers than those on the screen while the page rests (`wrong`,
    /// examples) and while it moves, those that show it with the right ones, and the longest time
    /// without that from its first translation on; returns what was sent. (`readApart`: from
    /// when to when the recognizer returns the paragraph's lines each on its own; a line of it
    /// then counts as right when it shows all the numbers on the screen, as wrong when its
    /// numbers are not a run of them. `passesAfter`: how many passes began after that time.)
    private func changingParagraph(_ paragraph: (Int) -> [Line], values: [Int], seconds: Double = 3,
                                   scroll: Double = 0, moving: [ClosedRange<Double>]? = nil, noise: Int = 2,
                                   seed: UInt64,
                                   configuration: OverlayTracker.Configuration = OverlayTracker.Configuration(),
                                   readApart: Range<Double>? = nil, passesAfter: Double = .infinity)
        -> (wrong: [String], wrongMoving: Int, right: Int, longestWithout: Double, sent: [String], passes: Int) {
        let perValue = Int(seconds * 30)
        let shownValue = values.flatMap { Array(repeating: $0, count: perValue) }
        let times = shownValue.indices.map { Double($0) / 30 }
        let windows = moving ?? (1..<values.count).map { Double($0) * seconds - 0.5...Double($0) * seconds + 0.5 }
        let offsets = times.map { time in
            scroll * windows.reduce(0) { $0 + max(0, min(time, $1.upperBound) - $1.lowerBound) }
        }
        let title = Line(text: "Postfach", top: 640, fontSize: 58)
        func lines(_ frame: Int) -> [Line] {
            ([title] + paragraph(shownValue[frame])).map { line in
                var moved = line
                moved.top -= offsets[frame]
                return moved
            }
        }
        let count = paragraph(values[0]).count
        var wrong: [String] = [], wrongMoving = 0, right = 0
        var firstRight: Double?, lastRight = 0.0, longestWithout = 0.0, passes = 0
        let sent = run(OverlayTracker(configuration: configuration), times: times, seed: seed, lines: lines,
                       readAll: { frame, shown, region in
                           if times[frame] > passesAfter { passes += 1 }
                           return Self.readings(of: shown, paragraph: 1..<(1 + count), in: region,
                                                apart: readApart?.contains(times[frame]) ?? false)
                       },
                       noise: noise) { frame, shown, placed in
            let text = shown[1...].map(\.text).joined(separator: " ")
            let isMoving = frame > 0 && offsets[frame] != offsets[frame - 1]
            var isRight = false
            for block in placed where block.text.hasPrefix("T ") && block.lineCount > 1 {
                if TextSimilarity.numbers(of: block.text) == TextSimilarity.numbers(of: text) {
                    isRight = true
                } else if isMoving {
                    wrongMoving += 1
                } else if wrong.count < 5 {
                    wrong.append(String(format: "%.2f s: ", times[frame]) + "\(block.text) over \(text)")
                }
            }
            if readApart != nil {
                let all = TextSimilarity.numbers(of: text)
                for block in placed where block.text.hasPrefix("T ") && block.lineCount == 1 && block.text != "T Postfach" {
                    let numbers = TextSimilarity.numbers(of: block.text)
                    if !numbers.isEmpty, numbers == all { isRight = true; continue }
                    let isRun = numbers.count <= all.count && (0...(all.count - numbers.count)).contains {
                        Array(all[$0..<($0 + numbers.count)]) == numbers
                    }
                    if isRun { continue }
                    if isMoving { wrongMoving += 1 } else if wrong.count < 5 {
                        wrong.append(String(format: "%.2f s: ", times[frame]) + "\(block.text) over \(text)")
                    }
                }
            }
            if isRight {
                right += 1
                if firstRight == nil { firstRight = times[frame] }
                lastRight = times[frame]
            } else if firstRight != nil {
                longestWithout = max(longestWithout, times[frame] - lastRight)
            }
        }
        return (wrong, wrongMoving, right, longestWithout, sent, passes)
    }

    /// The lab's page change2.html: "Seit dem letzten Abgleich sind NN neue Nachrichten …" over
    /// two lines, its number ticking every 3 s
    private static func messages(_ count: Int) -> [Line] {
        [Line(text: "Seit dem letzten Abgleich sind \(count) neue Nachrichten", top: 760, fontSize: 40, left: 40,
              fontName: "Helvetica"),
         Line(text: "im Postfach eingegangen. Bitte lesen Sie diese.", top: 828, fontSize: 40, left: 40,
              fontName: "Helvetica")]
    }

    /// … over five lines, its number in the middle of the third
    private static func folders(_ count: Int) -> [Line] {
        ["Die Verbindung zum Server ist im Moment stabil,", "und die Übertragung der Dateien läuft weiter.",
         "Bisher wurden \(count) von 40 Ordnern abgeglichen,", "die übrigen folgen in den nächsten Minuten.",
         "Bitte schalten Sie das Gerät nicht aus."].enumerated().map { index, text in
            Line(text: text, top: 760 + 68 * Double(index), fontSize: 40, left: 40, fontName: "Helvetica")
        }
    }

    /// … over six lines of small text (26 points, a line every 40 pixels)
    private static func smallFolders(_ count: Int) -> [Line] {
        ["Die Verbindung zum Server ist im Moment stabil und schnell,",
         "und die Übertragung der Dateien läuft weiter wie geplant.",
         "Die Sicherung hält alle Fotos und alle Dokumente bereit.",
         "Bisher wurden \(count) von 120 Ordnern sicher abgeglichen,",
         "die übrigen folgen in den nächsten paar Minuten.",
         "Bitte schalten Sie das Gerät nicht aus."].enumerated().map { index, text in
            Line(text: text, top: 760 + 40 * Double(index), fontSize: 26, left: 40, fontName: "Helvetica")
        }
    }

    /// … as `folders`, in a serif font
    private static func serifFolders(_ count: Int) -> [Line] {
        folders(count).map { line in
            var serif = line
            serif.fontName = "Georgia"
            return serif
        }
    }

    /// A paragraph of several lines whose number ticks in place (the lab's change.html and
    /// change2.html: "… sind 22 neue Nachrichten …" became 27, 15 became 18): no frame shows its
    /// translation with the old number, and the new text is translated again within two seconds,
    /// each text sent once. Two lines and five, the number in the middle of a line, also when it
    /// gains a digit (9 to 10). (Before, only blocks of one line were judged: the paragraph showed
    /// the translation with the old number until its place was read again, on the phone for about
    /// 4 s at every tick.)
    func testAParagraphIsNeverDrawnWithAnotherNumber() {
        for (name, paragraph, values) in [("two lines", Self.messages, [22, 27, 33]),
                                          ("five lines", Self.folders, [15, 18, 22]),
                                          ("a digit more", Self.messages, [8, 9, 10, 11])] as [(String, (Int) -> [Line], [Int])] {
            let result = changingParagraph(paragraph, values: values, seed: 21)
            XCTAssertEqual(result.wrong, [], name)
            XCTAssertEqual(result.wrongMoving, 0, name)
            XCTAssertLessThanOrEqual(result.longestWithout, 2, name)
            XCTAssertGreaterThan(result.right, values.count * 90 / 2, name)
            let texts = values.map { paragraph($0).map(\.text).joined(separator: " ") }
            XCTAssertEqual(result.sent.filter { $0 != "Postfach" }, texts, name)
        }
    }

    /// … and when the number ticks while the page scrolls slowly (60 pixels a second, from half a
    /// second before the tick to half a second after it): no frame at rest shows the old number,
    /// and the new text is translated within two seconds. (While the page moves, a block placed a
    /// fraction of a pixel off, or read from a frame that sampled its letters at another phase,
    /// fits worse with all its letters: a digit that changed into one that looks alike, "15"
    /// into "18", or a number that gained a digit, need not stand out then, and its old
    /// translation stays until its place is read again: a known limit.)
    func testAParagraphThatScrollsIsNeverDrawnWithAnotherNumberAtRest() {
        let result = changingParagraph(Self.messages, values: [22, 27, 33], scroll: 60, seed: 23)
        XCTAssertEqual(result.wrong, [])
        XCTAssertLessThanOrEqual(result.wrongMoving, 15 * 2)
        XCTAssertLessThanOrEqual(result.longestWithout, 2)
    }

    /// A paragraph whose numbers do not change, at rest and while the page scrolls (60 and 150
    /// pixels a second for 5 s, then at rest), on a link that adds noise of 2 and of 6 grey
    /// levels: it is drawn in as many frames as without the rule, and only its one text is sent.
    /// Also in small text and in a serif font (at rest and at 60 pixels a second, noise of 6).
    func testAParagraphWhoseNumberStaysIsNotHidden() {
        var withoutRule = OverlayTracker.Configuration()
        withoutRule.numberFitFactor = 1e9
        for (kind, paragraph, scrolls, noises) in [
            ("five lines", Self.folders, [0.0, 60, 150], [2, 6]),
            ("small text", Self.smallFolders, [0.0, 60], [6]),
            ("serif", Self.serifFolders, [0.0, 60], [6])] as [(String, (Int) -> [Line], [Double], [Int])] {
            for scroll in scrolls {
                for noise in noises {
                    let name = "\(kind), \(scroll) px/s, noise \(noise)"
                    let with = changingParagraph(paragraph, values: [15], seconds: 9, scroll: scroll, moving: [2...7],
                                                 noise: noise, seed: 31)
                    let without = changingParagraph(paragraph, values: [15], seconds: 9, scroll: scroll, moving: [2...7],
                                                    noise: noise, seed: 31, configuration: withoutRule)
                    XCTAssertEqual(with.wrongMoving, 0, name)
                    XCTAssertEqual(with.wrong, [], name)
                    XCTAssertGreaterThanOrEqual(with.right, without.right, name)
                    XCTAssertEqual(with.sent.filter { $0 != "Postfach" }, [paragraph(15).map(\.text).joined(separator: " ")],
                                   name)
                }
            }
        }
    }

    /// A paragraph hidden for its numbers whose reading comes back as separate lines after the
    /// tick (for 3 s, and for good): the reading of its box never confirms it, its rereads are
    /// used up, and nothing asks for its place any more. It is dropped and its place read as new
    /// text: the number is right again within two seconds, never wrong at rest, and the page is
    /// not read on without end. (Before, the paragraph stayed hidden for good, 9 s without its
    /// translation to the end of the run, the passes stopped.)
    func testAHiddenParagraphThatNothingReadsIsReadAsNewText() {
        for apartUntil in [6.0, 99] {
            let name = "apart until \(apartUntil)"
            let result = changingParagraph(Self.messages, values: [22, 27, 27, 27], seed: 41,
                                           readApart: 3..<apartUntil, passesAfter: 8)
            XCTAssertEqual(result.wrong, [], name)
            XCTAssertLessThanOrEqual(result.longestWithout, 2, name)
            XCTAssertEqual(result.passes, 0, name)
        }
    }

    private static let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September",
                                 "Oktober", "November", "Dezember"]

    /// The lines of a list of 60 rows that look alike but for their numbers (as the lab's page
    /// alikelist.html): a bold title "Ordner N synchronisieren" over a summary "N+3 Dateien,
    /// geändert am …", a row every 189 pixels, the list scrolled up by `offset` pixels
    private static func rows(offset: Double) -> [Line] {
        var lines: [Line] = []
        for number in 1...60 {
            let top = 260 + Double(number - 1) * 189 - offset
            lines.append(Line(text: "Ordner \(number) synchronisieren", top: top, fontSize: 52))
            lines.append(Line(text: "\(number + 3) Dateien, geändert am \(number). \(months[(number - 1) % 12])",
                              top: top + 70, fontSize: 42, fontName: "Helvetica"))
        }
        return lines
    }

    /// A placed translation lies on the text it was made from: that text is on the screen, and
    /// the rectangle is within half a line of it
    private static func isOnItsText(_ block: PlacedBlock, lines: [Line]) -> Bool {
        guard let line = lines.first(where: { "T " + $0.text == block.text }) else { return false }
        return abs(block.rect.minY - line.top) <= line.height / 2
    }

    /// The time between two frames of the phone's stream that differed, while the lab's list
    /// glided (milliseconds, in the order they came)
    private static let streamIntervals: [Double] = [25, 60, 15, 42, 20, 38, 28, 49, 72, 73, 26, 28, 22, 21, 35, 46, 15,
                                                    25, 40, 37, 9, 20, 29, 24, 16, 35, 21, 20, 34, 68, 47, 22, 23, 32,
                                                    42, 29, 42, 38, 21, 65, 31, 50, 54, 62, 28, 42, 36, 34, 97, 34, 46,
                                                    29, 30, 34, 53, 75, 20, 49, 71, 29, 38]

    /// The list at rest for 3 s, then moved by `swipes` swipes 0.85 s apart, each of which starts
    /// at `speed` pixels a second and slows down with the time constant `slowing` (frames at the
    /// stream's intervals), then at rest for 3 s. Counts placed translations that do not lie on
    /// their text while the list moves and at rest after it, all that were placed while it moved,
    /// and lines in full view without their translation from 2 s after it stopped.
    private func glide(speed: Double, slowing: Double, swipes: Int) -> (wrongMoving: Int, wrongAtRest: Int,
                                                                       placedMoving: Int, untranslatedAtRest: Int,
                                                                       examples: [String]) {
        var times: [Double] = [], offsets: [Double] = []
        var time = 0.0
        while time < 3 {
            times.append(time)
            offsets.append(0)
            time += 1.0 / 30
        }
        let start = time, end = time + 0.85 * Double(swipes) + 1.5
        var interval = 0
        while time < end {
            time += Self.streamIntervals[interval % Self.streamIntervals.count] / 1000
            interval += 1
            var offset = 0.0
            for swipe in 0..<swipes where time > start + 0.85 * Double(swipe) {
                offset += speed * slowing * (1 - exp(-(time - start - 0.85 * Double(swipe)) / slowing))
            }
            times.append(time)
            offsets.append(min(offset, 60 * 189 - 2400))
        }
        let stopped = time
        while time < stopped + 3 {
            time += 1.0 / 30
            times.append(time)
            offsets.append(offsets.last ?? 0)
        }
        var wrongMoving = 0, wrongAtRest = 0, placedMoving = 0
        var examples: [String] = []
        let untranslated = UntranslatedCount(after: stopped + 2, frameHeight: Double(Self.height))
        run(OverlayTracker(), times: times, seed: 11, lines: { Self.rows(offset: offsets[$0]) }, each: { frame, lines, placed in
            untranslated.count(at: times[frame], lines: lines, placed: placed)
            let wrong = placed.filter { !Self.isOnItsText($0, lines: lines) }
            if times[frame] > start, times[frame] <= stopped {
                placedMoving += placed.count
                wrongMoving += wrong.count
            } else {
                wrongAtRest += wrong.count
            }
            if let first = wrong.first, examples.count < 3 {
                let under = lines.first { abs($0.top - first.rect.minY) < 30 }?.text ?? "-"
                examples.append(String(format: "%.2f s: ", times[frame]) + "\(first.text) over \(under)")
            }
        })
        return (wrongMoving, wrongAtRest, placedMoving, untranslated.frames, examples + untranslated.examples)
    }

    /// Counts, frame by frame from `after` on, the lines in full view over which no translation
    /// of their own lies
    private final class UntranslatedCount {
        let after: TimeInterval, frameHeight: Double
        private(set) var frames = 0, examples: [String] = []
        init(after: TimeInterval, frameHeight: Double) {
            self.after = after
            self.frameHeight = frameHeight
        }
        func count(at time: TimeInterval, lines: [Line], placed: [PlacedBlock]) {
            guard time > after else { return }
            for line in lines where line.top > 10 && line.top + line.height < frameHeight - 10 {
                guard !placed.contains(where: { OverlayTrackerNumbersTests.isOnItsText($0, lines: [line]) }) else { continue }
                frames += 1
                if examples.count < 3 { examples.append(String(format: "%.2f s: ", time) + "\(line.text) untranslated") }
            }
        }
    }

    /// A flick over the list, as fast as the lab's (12 000 pixels a second, slowing down within a
    /// quarter of a second), at the stream's uneven frame intervals: the movement of some frames
    /// is measured a row or two off (the rows fit any place of their pitch nearly alike), and
    /// blocks are carried under rows they were not read from. A translation is drawn over another
    /// row than its own in one frame at most (the frame in which its digit still fits the other
    /// row's well enough), none at rest. (Before, 27 translations in 15 frames, up to two rows off.)
    func testAFlickOverRowsThatLookAlikeDrawsNoRowOverAnother() {
        let result = glide(speed: 12_000, slowing: 0.25, swipes: 1)
        XCTAssertLessThanOrEqual(result.wrongMoving, 1, "\(result.examples)")
        XCTAssertEqual(result.wrongAtRest, 0, "\(result.examples)")
        XCTAssertEqual(result.untranslatedAtRest, 0, "\(result.examples)")
        XCTAssertGreaterThan(result.placedMoving, 500)
    }

    /// … and four glides in a row (2600 pixels a second each, as the lab's swipes), where the
    /// movement is measured right: every translation stays on its row, and as many are drawn
    /// while the list moves as without the rule (1688 when it was made).
    func testGlidesOverRowsThatLookAlikeKeepTheirTranslations() {
        let result = glide(speed: 2600, slowing: 0.4, swipes: 4)
        XCTAssertEqual(result.wrongMoving + result.wrongAtRest, 0, "\(result.examples)")
        XCTAssertEqual(result.untranslatedAtRest, 0, "\(result.examples)")
        XCTAssertGreaterThanOrEqual(result.placedMoving, 1600)
    }

    // MARK: Rows with long numbers

    /// The lines of a list of invoices, rows that differ in their long numbers ("Rechnung
    /// 20240107 vom 2. Februar" over "CHF 477.11 offen seit 3 Tagen"), a row every 170 pixels,
    /// the list scrolled up by `offset` pixels
    private static func invoices(offset: Double) -> [Line] {
        var lines: [Line] = []
        for number in 1...80 {
            let top = 260 + Double(number - 1) * 170 - offset
            guard top > -200, top < 2600 else { continue }
            lines.append(Line(text: "Rechnung \(2024_0100 + number * 7) vom \(number % 28 + 1). \(months[number % 12])",
                              top: top, fontSize: 46))
            lines.append(Line(text: "CHF \(100 + (number * 377) % 9000).\(10 + number % 89) offen seit \(number % 40 + 2) Tagen",
                              top: top + 64, fontSize: 40, fontName: "Helvetica"))
        }
        return lines
    }

    /// The invoices at rest for 3 s, scrolled at `speed` pixels a second for 4 s (30 frames a
    /// second), then at rest for 4 s: translations placed while the list moves, those that do
    /// not lie on their text, and lines in full view without their translation from 2 s after
    /// it stopped
    private func scrollInvoices(speed: Double, configuration: OverlayTracker.Configuration)
        -> (placedMoving: Int, wrong: Int, untranslatedAtRest: Int, examples: [String]) {
        var times: [Double] = [], offsets: [Double] = []
        var time = 0.0
        while time < 3 {
            times.append(time)
            offsets.append(0)
            time += 1.0 / 30
        }
        let start = time
        while time < start + 4 {
            time += 1.0 / 30
            times.append(time)
            offsets.append(speed * (time - start))
        }
        let stopped = time
        while time < stopped + 4 {
            time += 1.0 / 30
            times.append(time)
            offsets.append(offsets.last ?? 0)
        }
        var placedMoving = 0, wrong = 0
        let untranslated = UntranslatedCount(after: stopped + 2, frameHeight: Double(Self.height))
        run(OverlayTracker(configuration: configuration), times: times, seed: 13,
            lines: { Self.invoices(offset: offsets[$0]) }, each: { frame, lines, placed in
            untranslated.count(at: times[frame], lines: lines, placed: placed)
            if times[frame] > start, times[frame] <= stopped { placedMoving += placed.count }
            wrong += placed.filter { !Self.isOnItsText($0, lines: lines) }.count
        })
        return (placedMoving, wrong, untranslated.frames, untranslated.examples)
    }

    /// A list whose rows differ in long numbers (an order number of eight digits, an amount),
    /// scrolled slowly: a row placed a fraction of a pixel off at the start of the movement fits
    /// worse with all its letters, and most with the dense strokes of its number. The digits are
    /// judged against all the letters of the line, digits included, so the rule hides no right
    /// row here: about as many translations are drawn while the list moves as without it (2704
    /// against 2764 at 150 pixels a second, where the movement starts), and none more is missing
    /// once it rests. (When the digits were judged against the other letters only, the
    /// order number's line was taken for another at the first frame of the movement at 150
    /// pixels a second and stayed untranslated at rest.)
    func testASlowScrollOverLongNumbersDrawsAsManyTranslations() {
        var withoutRule = OverlayTracker.Configuration()
        withoutRule.numberFitFactor = 1e9
        for speed in [60.0, 150.0] {
            let with = scrollInvoices(speed: speed, configuration: OverlayTracker.Configuration())
            let without = scrollInvoices(speed: speed, configuration: withoutRule)
            XCTAssertEqual(with.wrong, 0, "\(speed): \(with.examples)")
            XCTAssertGreaterThanOrEqual(Double(with.placedMoving), 0.97 * Double(without.placedMoving),
                                        "\(speed): \(with.placedMoving) against \(without.placedMoving)")
            XCTAssertLessThanOrEqual(with.untranslatedAtRest, without.untranslatedAtRest,
                                     "\(speed): \(with.examples) against \(without.examples)")
        }
    }

    /// A row read at the place of a translated row that looks alike but for its number (the other
    /// row slid there, or a reading of a pass while the list moved was carried there) is another
    /// text: the old row's translation is not shown over it while its own is on the way, though
    /// their words are mostly the same (`TextSimilarity.isRelated`). Text with the same numbers
    /// still shows the old translation meanwhile.
    func testARowReadWithOtherNumbersDoesNotShowTheOldTranslation() {
        XCTAssertTrue(TextSimilarity.hasOtherNumbers("Ordner 12 synchronisieren", "Ordner 23 synchronisieren"))
        XCTAssertTrue(TextSimilarity.hasOtherNumbers("49 % belegt, 79 GB", "50 % belegt, 78 GB frei"))
        XCTAssertFalse(TextSimilarity.hasOtherNumbers("Speicherplatz", "Speicherplatz 41 % belegt"))
        XCTAssertFalse(TextSimilarity.hasOtherNumbers("sind 13 neue Nachrichten", "Seit dem Abgleich sind 13 neue Nachrichten"))
        XCTAssertFalse(TextSimilarity.hasOtherNumbers("Line 2", "Line 2 and what follows"))

        let tracker = OverlayTracker()
        let row = Line(text: "Ordner 12 synchronisieren", top: 800, fontSize: 52)
        var placed: [PlacedBlock] = []
        run(tracker, times: (0..<60).map { Double($0) / 30 }, seed: 3, lines: { _ in [row] }, each: { _, _, now in
            placed = now
        })
        XCTAssertEqual(placed.map(\.text), ["T " + row.text])
        // (the other row shows at the same place and is read; nothing is translated meanwhile)
        let other = Line(text: "Ordner 23 synchronisieren", top: 800, fontSize: 52)
        run(tracker, times: (60..<120).map { Double($0) / 30 }, seed: 99, lines: { _ in [other] }, translates: false)
        XCTAssertEqual(tracker.blocks.map(\.text), [other.text])
        XCTAssertEqual(tracker.blocks.map(\.translation), [nil])
    }
}
