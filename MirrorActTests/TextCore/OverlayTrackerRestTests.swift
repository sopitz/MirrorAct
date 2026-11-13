// SPDX-License-Identifier: GPL-3.0-or-later
import CoreText
import Foundation
import XCTest
@testable import MirrorAct

/// What the tracker reads again so that a screen at rest ends up translated: text that changed
/// in place, and a block that went away while its place still shows text, have their place read
/// whole, and no translation stays over a text it was not made from. The screens are those of
/// a phone 1080 × 2400 (thumbnails at scale 3), as in the lab.
final class OverlayTrackerRestTests: XCTestCase {
    private static let scale = 3, width = 1080, height = 2400
    /// A line of dark text on the plain page, drawn with Core Text in Helvetica Bold
    struct Line {
        var text: String
        var top: Double
        var fontSize = 63.0
        var left = 49.0
        var fontName = "Helvetica-Bold"
        /// what the recognizer makes of the whole line, when it misreads it (in the same box)
        var readAs: String?

        private var font: CTFont { CTFontCreateWithName(fontName as CFString, fontSize, nil) }

        private var ctLine: CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 30 / 255, alpha: 1),
            ]))
        }

        var height: Double { Double(CTFontGetAscent(font) + CTFontGetDescent(font)) }

        /// where each letter begins, and where the last one ends (frame pixels)
        private var edges: [Double] {
            let line = ctLine, utf16 = Array(text.utf16)
            var result: [Double] = []
            var index = 0
            for character in text {
                result.append(left + Double(CTLineGetOffsetForStringIndex(line, index, nil)))
                index += String(character).utf16.count
            }
            result.append(left + Double(CTLineGetOffsetForStringIndex(line, utf16.count, nil)))
            return result
        }

        func draw(in context: CGContext, frameHeight: Int) {
            context.textPosition = CGPoint(x: left, y: Double(frameHeight) - top - Double(CTFontGetAscent(font)))
            CTLineDraw(ctLine, context)
        }

        /// What a recognizer reads of the line in `region` (frame pixels): the letters that reach
        /// into it, in a box that ends at the region's edge where a letter is cut there (as Vision
        /// reads a line cut by the edge of what it reads); nothing when the line's rows are not
        /// all in it
        func reading(in region: CGRect) -> RecognizedBlock? {
            guard region.minY <= top, region.maxY >= top + height else { return nil }
            let letters = Array(text), edges = edges
            var first: Int?, last: Int?
            for index in letters.indices where letters[index] != " " {
                guard edges[index + 1] > region.minX, edges[index] < region.maxX else { continue }
                first = first ?? index
                last = index
            }
            guard let first, let last else { return nil }
            let minX = max(edges[first], region.minX), maxX = min(edges[last + 1], region.maxX)
            // (Vision's box of a part of a line need not be as high as that of the whole line: on
            // the phone "Intranet" of "Netzwerk & Intranet" came 5 px lower, "rk & Intranet" 16 px
            // higher)
            let isPart = first > 0 || last < letters.count - 1
            return RecognizedBlock(text: isPart ? String(letters[first...last]) : readAs ?? text,
                                   rect: CGRect(x: minX, y: top + (isPart ? 8 : 0), width: maxX - minX,
                                                height: height - (isPart ? 22 : 0)))
        }
    }

    /// The thumbnail of a plain page with `lines` (without noise)
    private static func picture(_ lines: [Line]) -> LumaImage {
        var gray = [UInt8](repeating: 245, count: width * height)
        gray.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            for line in lines {
                line.draw(in: context, frameHeight: height)
            }
        }
        return gray.withUnsafeBytes { bytes in
            LumaImage.downsampled(from: bytes.baseAddress!, width: width, height: height, bytesPerRow: width,
                                  format: .luma8, scale: scale)
        }
    }

    /// Shows `lines` for `seconds` at 30 frames per second, from `start`, with `each` called with
    /// what is drawn into every frame and `alter` changing every frame before the tracker sees
    /// it; passes take 0.3 s and read what `lines` show in their region; what is asked for is
    /// translated at once
    private func show(_ lines: [Line], on tracker: OverlayTracker, from start: TimeInterval, seconds: Double,
                      seed: inout UInt64, each: ([String]) -> Void = { _ in },
                      alter: (inout LumaImage) -> Void = { _ in })
        -> (regions: [CGRect], sent: [String], placed: [String], read: [String]) {
        var regions: [CGRect] = [], sent: [String] = [], placed: [String] = [], read: [String] = []
        let picture = Self.picture(lines)
        var time = start
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        while time < start + seconds {
            time += 1.0 / 30
            seed += 1
            var frame = SyntheticPage.noisy(picture, amount: 2, seed: seed)
            alter(&frame)
            placed = tracker.advance(frame, scale: Self.scale, time: time).placed.map(\.text)
            each(placed)
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                read += job.answer.map(\.text)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                regions.append(request.region)
                pending = (request, lines.compactMap { $0.reading(in: request.region) }, time + 0.3)
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                sent.append(text)
                tracker.setTranslation("T " + text, for: text)
            }
        }
        return (regions, sent, placed, read)
    }

    /// The title of a bar changes in place in its last word ("Netzwerk & Internet" to "Netzwerk
    /// & Intranet", as on the phone): only the place of the two letters that differ changed, and
    /// a pass reads it with the room `readMargin` gives, which cuts the line on the left. Vision's
    /// box of that part is lower than the line's, so the old block does not count as a line of
    /// the same paragraph. The part lies over the old block of one line, whose place is read with
    /// it: the new title is translated and drawn in place of the old translation. Read again
    /// only a little beyond the cut each time ("Intranet", "k & Intranet", "zwerk & Intranet", as
    /// on the phone), it was never read whole, and the old translation stayed over the new title
    /// for good.
    func testATitleThatChangedInItsLastWordIsReadWhole() {
        let tracker = OverlayTracker()
        var seed: UInt64 = 1
        let before = Line(text: "Netzwerk & Internet", top: 264)
        let first = show([before], on: tracker, from: 0, seconds: 2, seed: &seed)
        XCTAssertEqual(first.placed, ["T " + before.text])

        let after = Line(text: "Netzwerk & Intranet", top: 264)
        let changed = show([after], on: tracker, from: 2, seconds: 6, seed: &seed)
        XCTAssertEqual(tracker.blocks.map(\.text), [after.text], "regions \(changed.regions)")
        XCTAssertEqual(changed.sent, [after.text])
        XCTAssertEqual(changed.placed, ["T " + after.text])
        XCTAssertLessThanOrEqual(changed.regions.count, 3, "\(changed.regions)")
    }

    /// A row of a settings list on a still page: a bold title over a grey summary that ticks
    /// every 3 s ("47 % belegt, 81 GB frei" … "49 % belegt, 79 GB frei"), then jumps back
    /// ("41 % belegt, 87 GB frei", both numbers changed) and ticks on, as on the lab's page. Only
    /// the places of the digits change, and their part of the line is read with the old block's
    /// place. Every value is translated within a second of showing, with one request per
    /// change, the title keeps its translation throughout, and no translation stays over a value
    /// it was not made from. (On the phone the summary was never read again after
    /// the jump back and stayed untranslated.)
    func testASummaryThatTicksAndJumpsBackIsTranslatedEveryTime() {
        let tracker = OverlayTracker()
        var seed: UInt64 = 1
        let title = Line(text: "Speicherplatz", top: 1363, fontSize: 52)
        func summary(_ used: Int) -> Line {
            Line(text: "\(used) % belegt, \(128 - used) GB frei", top: 1460, fontSize: 42, fontName: "Helvetica")
        }
        _ = show([title, summary(47)], on: tracker, from: 0, seconds: 3, seed: &seed)
        var time = 3.0
        for used in [48, 49, 41, 42, 43] {
            let shown = summary(used)
            var frames = 0, right = 0, wrong = 0
            let step = show([title, shown], on: tracker, from: time, seconds: 3, seed: &seed) { placed in
                frames += 1
                XCTAssertTrue(placed.contains("T " + title.text), "\(used): \(placed)")
                if placed.contains(where: { $0.contains(" % belegt") && $0 != "T " + shown.text }) { wrong += 1 }
                if placed.contains("T " + shown.text) { right += 1 }
            }
            XCTAssertEqual(step.sent, [shown.text], "\(used)")
            XCTAssertGreaterThanOrEqual(right, frames - 30, "\(used): translated within a second")
            XCTAssertLessThanOrEqual(wrong, 30, "\(used): the old value's translation at most a second")
            XCTAssertLessThanOrEqual(step.regions.count, 3, "\(used): \(step.regions)")
            time += 3
        }
    }

    /// The synthetic page with its lines 4…6 (one paragraph) drawn at `contrast` (1 = as they
    /// are, less = paler, as the link sends dark text it blurs while the page moves)
    private static func paleFrame(_ screen: SyntheticScreen, offset: Int, contrast: Double, seed: UInt64) -> LumaImage {
        var frame = screen.thumbnail(offset: offset, noiseSeed: seed)
        let top = SyntheticScreen.block(4, offset: offset, text: "").rect
        let bottom = SyntheticScreen.block(6, offset: offset, text: "").rect
        let scale = SyntheticScreen.scale
        for y in max(0, Int(top.minY) / scale)..<min(frame.height, Int(bottom.maxY) / scale + 1) {
            for x in 0..<frame.width {
                frame[x, y] = UInt8(240 - Int((240 - Double(frame[x, y])) * contrast))
            }
        }
        return frame
    }

    /// A translated paragraph on a page that scrolls: while the page moves, the link sends it so
    /// blurred that it cannot be found, for longer than `lostLifetime`, and the recognizer is busy
    /// elsewhere; once the page rests, it sharpens again a little in every frame (no change big
    /// enough to be read). The block forgotten while it moved has its place read once everything
    /// over it rests, and the paragraph is drawn again (its translation is known: nothing is
    /// sent). Before, nothing read its place again, and it stayed untranslated at rest (the dark
    /// paragraph d02 in a slow series on the phone).
    func testAParagraphForgottenWhileThePageMovedIsReadAgainAtRest() {
        let screen = SyntheticScreen(seed: 41)
        let scale = SyntheticScreen.scale
        let tracker = OverlayTracker()
        let text = "alpha beta gamma delta epsilon zeta eta theta"
        func paragraph(_ offset: Int) -> RecognizedBlock {
            let rect = SyntheticScreen.block(4, offset: offset, text: "").rect
                .union(SyntheticScreen.block(6, offset: offset, text: "").rect)
            return RecognizedBlock(text: text, rect: rect, lineCount: 3)
        }
        var time = 0.0, seed: UInt64 = 100, offset = 0, contrast = 1.0
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        var regions: [CGRect] = [], sent: [String] = [], placed: [String] = []
        func step(busy: Bool) {
            time += 1.0 / 30
            seed += 1
            let frame = Self.paleFrame(screen, offset: offset, contrast: contrast, seed: seed)
            placed = tracker.advance(frame, scale: scale, time: time).placed.map(\.text)
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                pending = nil
            }
            if !busy, pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                regions.append(request.region)
                // (the recognizer reads the paragraph when all of it lies in the region and shows clearly)
                let shown = paragraph(offset)
                let answer = contrast > 0.9 && request.region.contains(shown.rect) ? [shown] : []
                pending = (request, answer, time + 0.3)
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                sent.append(text)
                tracker.setTranslation("T " + text, for: text)
            }
        }
        while time < 2 { step(busy: false) }
        XCTAssertEqual(placed, ["T " + text])
        sent = []
        // the page moves up 2 px a frame for 2 s, the paragraph pale; the recognizer is busy
        contrast = 0.3
        while time < 4 {
            offset += 2
            step(busy: true)
        }
        // at rest it sharpens again over a second
        while contrast < 1 {
            contrast = min(1, contrast + 0.7 / 30)
            step(busy: true)
        }
        regions = []
        while time < 8 { step(busy: false) }
        XCTAssertTrue(regions.contains { $0.contains(paragraph(offset).rect) }, "\(regions)")
        XCTAssertEqual(tracker.blocks.map(\.text).filter { $0 == text }, [text])
        XCTAssertEqual(placed, ["T " + text])
        XCTAssertEqual(sent, [])
    }

    /// A bar title and a row change in place to texts that look alike, a letter longer each
    /// ("Netzwerk & Internet" to "Netzwerk & Internetz", "Mobilfunknetz" to "Mobilfunknetze", as
    /// on the lab's page): read at rest, each new reading is nearly the same as the old text, but
    /// its box is wider by about a letter. Both are taken as changed and translated, and the old
    /// translations are drawn over the new texts for two seconds at most. (Taken for misreadings,
    /// the old translations stayed over the new texts for good.)
    func testATextThatGainedALetterInPlaceIsTranslatedAgain() {
        let tracker = OverlayTracker()
        var seed: UInt64 = 1
        let title = Line(text: "Netzwerk & Internet", top: 264)
        let row = Line(text: "Mobilfunknetz", top: 470, fontSize: 52)
        let first = show([title, row], on: tracker, from: 0, seconds: 2, seed: &seed)
        XCTAssertEqual(Set(first.placed), ["T " + title.text, "T " + row.text])
        let newTitle = Line(text: "Netzwerk & Internetz", top: 264)
        let newRow = Line(text: "Mobilfunknetze", top: 470, fontSize: 52)
        var old = 0
        let changed = show([newTitle, newRow], on: tracker, from: 2, seconds: 5, seed: &seed) { placed in
            if placed.contains("T " + title.text) || placed.contains("T " + row.text) { old += 1 }
        }
        XCTAssertEqual(Set(tracker.blocks.map(\.text)), [newTitle.text, newRow.text], "\(changed.regions)")
        XCTAssertEqual(Set(changed.sent), [newTitle.text, newRow.text])
        XCTAssertEqual(changed.sent.count, 2)
        XCTAssertEqual(Set(changed.placed), ["T " + newTitle.text, "T " + newRow.text])
        XCTAssertLessThanOrEqual(old, 60, "the old translations at most two seconds")
    }

    /// … while readings of a title that does not change, which come out a letter different now
    /// and then (Vision misreads a letter, or drops one) in the same box, are misreadings: the
    /// title keeps its text and its translation, and nothing more is sent than the summary below
    /// it that ticks (it has the title read with it each time)
    func testMisreadingsOfATitleAtRestAreNotSent() {
        let tracker = OverlayTracker()
        var seed: UInt64 = 1
        // (close enough above the summary that a pass that reads the summary reads it too)
        var title = Line(text: "Speicherplatz", top: 1392, fontSize: 52)
        func summary(_ used: Int) -> Line {
            Line(text: "\(used) % belegt, \(128 - used) GB frei", top: 1460, fontSize: 42, fontName: "Helvetica")
        }
        _ = show([title, summary(41)], on: tracker, from: 0, seconds: 3, seed: &seed)
        var time = 3.0, sent: [String] = [], misread = 0
        for (step, misreading) in [nil, "Speicherpiatz", "Speicherpltz", nil, "Speicherplatz."].enumerated() {
            title.readAs = misreading
            let shown = summary(42 + step)
            let result = show([title, shown], on: tracker, from: time, seconds: 3, seed: &seed) { placed in
                XCTAssertTrue(placed.contains("T Speicherplatz"), "\(step): \(placed)")
            }
            sent += result.sent
            misread += result.read.filter { $0 == misreading }.count
            time += 3
        }
        XCTAssertGreaterThanOrEqual(misread, 2, "the title is read with the summary")
        XCTAssertEqual(sent, (42...46).map { summary($0).text })
        XCTAssertTrue(tracker.blocks.map(\.text).contains("Speicherplatz"))
    }

    /// … and so are readings of a title and a row under a scrim: a dialog dims the page for four
    /// seconds, so neither can be found where it was read (they are lost), and Vision reads the
    /// dimmed lines a letter short ("Speicherpltz", "Mobilfunknet") in the same boxes. Nothing is
    /// sent and both keep their translations. (When a lost block took a nearly equal reading at
    /// rest for a change, both misreadings were sent and their translations drawn.)
    func testMisreadingsUnderAScrimAreNotSent() {
        let tracker = OverlayTracker()
        var seed: UInt64 = 1
        let title = Line(text: "Speicherplatz", top: 1363, fontSize: 52)
        let row = Line(text: "Mobilfunknetz", top: 470, fontSize: 52)
        let first = show([title, row], on: tracker, from: 0, seconds: 3, seed: &seed)
        XCTAssertEqual(Set(first.placed), ["T " + title.text, "T " + row.text])
        var dimmedTitle = title, dimmedRow = row
        dimmedTitle.readAs = "Speicherpltz"
        dimmedRow.readAs = "Mobilfunknet"
        let during = show([dimmedTitle, dimmedRow], on: tracker, from: 3, seconds: 4, seed: &seed) { frame in
            for index in frame.pixels.indices { frame.pixels[index] = UInt8(Double(frame.pixels[index]) * 0.5) }
        }
        XCTAssertGreaterThanOrEqual(during.read.filter { $0 == "Speicherpltz" || $0 == "Mobilfunknet" }.count, 1,
                                    "the dimmed lines are read: \(during.regions)")
        XCTAssertEqual(during.sent, [])
        XCTAssertEqual(Set(during.placed), ["T " + title.text, "T " + row.text])
        let after = show([title, row], on: tracker, from: 7, seconds: 4, seed: &seed)
        XCTAssertEqual(after.sent, [])
        XCTAssertEqual(Set(after.placed), ["T " + title.text, "T " + row.text])
    }

    /// A translated paragraph of six lines on a still page; a pass at rest reads its first five
    /// lines as one paragraph and the last line as another (the recognizer split the paragraph,
    /// as on the phone after flings to the end of the page), the next one reads it whole. The
    /// five lines hold most of the paragraph's place but leave its last line out: the
    /// paragraph's place is read again whole, and in the end it is one block with the whole text
    /// and its translation. (Taken as covering it, the five lines kept the place, and the last
    /// line stayed a piece of its own for good.)
    func testAReadingThatLeavesOutTheLastLineHasTheParagraphReadAgain() {
        let screen = SyntheticScreen(seed: 43)
        let scale = SyntheticScreen.scale
        let tracker = OverlayTracker()
        func lines(_ first: Int, _ last: Int, _ text: String) -> RecognizedBlock {
            RecognizedBlock(text: text, rect: SyntheticScreen.block(first, offset: 0, text: "").rect
                .union(SyntheticScreen.block(last, offset: 0, text: "").rect), lineCount: last - first + 1)
        }
        let whole = lines(4, 9, "one two three four five six seven eight nine ten eleven twelve")
        let five = lines(4, 8, "one two three four five six seven eight nine ten")
        let frame = screen.thumbnail(offset: 0, noiseSeed: 7)
        var time = 0.0, sent: [String] = [], regions: [CGRect] = []
        var answer: (CGRect) -> [RecognizedBlock] = { region in region.contains(whole.rect) ? [whole] : [] }
        func run(until end: TimeInterval, frame: LumaImage) {
            while time < end {
                time += 1.0 / 30
                _ = tracker.advance(frame, scale: scale, time: time)
                if let due = tracker.recognitionDue, due <= time, let request = tracker.beginRecognition(time: time) {
                    regions.append(request.region)
                    tracker.finishRecognition(request, blocks: answer(request.region), time: time + 0.05)
                }
                for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                    sent.append(text)
                    tracker.setTranslation("T " + text, for: text)
                }
            }
        }
        run(until: 2, frame: frame)
        XCTAssertEqual(tracker.blocks.map(\.translation), ["T " + whole.text])
        // something changes around the paragraph (a frame drawn in the gaps above and below it
        // and beside its lines), and the pass that reads it splits the paragraph
        var changed = frame
        let above = Int(SyntheticScreen.block(4, offset: 0, text: "").rect.minY) / scale - 8
        let below = Int(SyntheticScreen.block(9, offset: 0, text: "").rect.maxY) / scale + 2
        for x in 4..<196 where x % 4 != 0 {
            changed[x, above] = 0
            changed[x, below] = 0
        }
        for y in above..<below { changed[193, y] = 0 }
        let last = lines(9, 9, "eleven twelve")
        var split = true
        answer = { region in
            guard region.contains(whole.rect) else { return [] }
            defer { split = false }
            return split ? [five, last] : [whole]
        }
        regions = []
        run(until: 6, frame: changed)
        XCTAssertGreaterThanOrEqual(regions.filter { $0.contains(whole.rect) }.count, 2, "\(regions)")
        XCTAssertEqual(tracker.blocks.map(\.text), [whole.text])
        let placed = tracker.advance(changed, scale: scale, time: time + 0.1).placed.map(\.text)
        XCTAssertEqual(placed, ["T " + whole.text])
    }
}
