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
    @discardableResult
    private func run(_ tracker: OverlayTracker, times: [TimeInterval], seed: UInt64, lines: (Int) -> [Line],
                     read: (Int, Line, CGRect) -> RecognizedBlock? = { _, line, region in line.reading(in: region) },
                     translates: Bool = true, each: (Int, [Line], [PlacedBlock]) -> Void = { _, _, _ in }) -> [String] {
        var sent: [String] = []
        var seed = seed
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        for (frame, time) in times.enumerated() {
            seed += 1
            let shown = lines(frame)
            let picture = SyntheticPage.noisy(Self.picture(shown), amount: 2, seed: seed)
            let placed = tracker.advance(picture, scale: Self.scale, time: time).placed
            each(frame, shown, placed)
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                pending = (request, shown.compactMap { read(frame, $0, request.region) }, time + 0.3)
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

    // MARK: Rows that look alike but for their numbers

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
        run(OverlayTracker(), times: times, seed: 11, lines: { Self.rows(offset: offsets[$0]) }) { frame, lines, placed in
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
        }
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
            lines: { Self.invoices(offset: offsets[$0]) }) { frame, lines, placed in
            untranslated.count(at: times[frame], lines: lines, placed: placed)
            if times[frame] > start, times[frame] <= stopped { placedMoving += placed.count }
            wrong += placed.filter { !Self.isOnItsText($0, lines: lines) }.count
        }
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
        run(tracker, times: (0..<60).map { Double($0) / 30 }, seed: 3, lines: { _ in [row] }) { _, _, now in
            placed = now
        }
        XCTAssertEqual(placed.map(\.text), ["T " + row.text])
        // (the other row shows at the same place and is read; nothing is translated meanwhile)
        let other = Line(text: "Ordner 23 synchronisieren", top: 800, fontSize: 52)
        run(tracker, times: (60..<120).map { Double($0) / 30 }, seed: 99, lines: { _ in [other] }, translates: false)
        XCTAssertEqual(tracker.blocks.map(\.text), [other.text])
        XCTAssertEqual(tracker.blocks.map(\.translation), [nil])
    }
}
