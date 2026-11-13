// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// What a reading of a place does to the blocks known there, and when the text of a block is
/// final: one block per text, a paragraph that was read in part is read whole, and a paragraph
/// at the edge of the view is not sent to the translator before all of it can have been seen.
final class OverlayTrackerReadingTests: XCTestCase {
    private let scale = SyntheticScreen.scale

    /// The rectangle of lines `first`…`last` of the synthetic page as one paragraph
    private static func paragraph(_ first: Int, _ last: Int, offset: Int, text: String) -> RecognizedBlock {
        let top = SyntheticScreen.block(first, offset: offset, text: "").rect
        let bottom = SyntheticScreen.block(last, offset: offset, text: "").rect
        return RecognizedBlock(text: text, rect: top.union(bottom), lineCount: last - first + 1)
    }

    /// Reads the still screen once with `blocks` and translates what is asked for
    private func readAtRest(_ tracker: OverlayTracker, _ screen: SyntheticScreen, offset: Int,
                            blocks: [RecognizedBlock], time: TimeInterval) throws {
        _ = tracker.advance(screen.thumbnail(offset: offset, noiseSeed: 7), scale: scale, time: time)
        let request = try XCTUnwrap(tracker.beginRecognition(time: time + 1))
        tracker.finishRecognition(request, blocks: blocks, time: time + 1.2)
        for text in tracker.textsAwaitingTranslation(limit: 50, time: time + 1.2) {
            tracker.setTranslation("T " + text, for: text)
        }
    }

    /// Something changes in a strip across the screen right below line `line`, so that the place
    /// of that line is read: the frame with the change
    private func changed(_ screen: SyntheticScreen, offset: Int, below line: Int, mark: Int) -> LumaImage {
        var frame = screen.thumbnail(offset: offset, noiseSeed: 7)
        let rect = SyntheticScreen.block(line, offset: offset, text: "").rect
        // (both rows in one row of tiles, so that the change shows clearly)
        var y = Int(rect.maxY) / scale + 3
        if y % 8 == 7 { y += 1 }
        for row in y..<(y + 2) {
            for x in 4..<196 where (x + mark) % 4 != 0 {
                frame[x, row] = 0
            }
        }
        return frame
    }

    /// A line of a known paragraph read alone (Vision splits a line, a strip holds only one
    /// line of it) is a part of that paragraph: it gets no block of its own, is not sent, and
    /// nothing is drawn over the paragraph's translation
    func testALineReadAloneInsideItsParagraphStaysPartOfIt() throws {
        let screen = SyntheticScreen(seed: 21)
        let tracker = OverlayTracker()
        let whole = Self.paragraph(4, 6, offset: 0, text: "alpha beta gamma delta epsilon zeta")
        try readAtRest(tracker, screen, offset: 0, blocks: [whole], time: 0)
        XCTAssertEqual(tracker.blocks.map(\.translation), ["T alpha beta gamma delta epsilon zeta"])

        _ = tracker.advance(changed(screen, offset: 0, below: 5, mark: 1), scale: scale, time: 3)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 3.5), "the change is read")
        XCTAssertFalse(request.isFullFrame)
        tracker.finishRecognition(request, blocks: [SyntheticScreen.block(5, offset: 0, text: "gamma delta")],
                                  time: 3.6)

        XCTAssertEqual(tracker.blocks.count, 1, "one block for the paragraph: \(tracker.blocks.map(\.text))")
        XCTAssertEqual(tracker.blocks.first?.text, whole.text)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 3.6), [], "the line is not sent on its own")
        let placed = tracker.advance(screen.thumbnail(offset: 0, noiseSeed: 7), scale: scale, time: 4).placed
        XCTAssertEqual(placed.map(\.text), ["T alpha beta gamma delta epsilon zeta"])
    }

    /// A new reading that lies over part of an older block with other text replaces it: the
    /// place shows something else now, and two translations must never cover each other
    func testALaterReadingOverAnOlderOneReplacesIt() throws {
        let screen = SyntheticScreen(seed: 22)
        let tracker = OverlayTracker()
        // (two lines: the upper one lies outside of what is read next, so it is not simply gone)
        try readAtRest(tracker, screen, offset: 0, blocks: [Self.paragraph(4, 5, offset: 0, text: "Old words here")],
                       time: 0)
        _ = tracker.advance(changed(screen, offset: 0, below: 5, mark: 2), scale: scale, time: 3)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 3.5))
        // (half a line lower: less than `sameBlockOverlap` of it, more than `overlapLimit`)
        var other = SyntheticScreen.block(5, offset: 0, text: "Something new")
        other.rect = other.rect.offsetBy(dx: 0, dy: Double(SyntheticScreen.lineHeight) / 2)
        tracker.finishRecognition(request, blocks: [other], time: 3.6)

        XCTAssertEqual(tracker.blocks.map(\.text), ["Something new"], "the older reading gives way")
        for text in tracker.textsAwaitingTranslation(limit: 10, time: 3.6) {
            tracker.setTranslation("T " + text, for: text)
        }
        let placed = tracker.advance(screen.thumbnail(offset: 0, noiseSeed: 7), scale: scale, time: 4).placed
        XCTAssertEqual(placed.map(\.text), ["T Something new"])
        // (the reading did not cover the older block's place: what is left of it is read again)
        let again = try XCTUnwrap(tracker.beginRecognition(time: 4), "the older block's place is read again")
        XCTAssertTrue(again.region.contains(SyntheticScreen.block(4, offset: 0, text: "").rect), "\(again.region)")
    }

    /// Runs the passes that become due on a still frame for `seconds`, each answered with
    /// `answer(region)`, and translates what is asked for. Returns the regions read and the
    /// texts sent.
    private func idle(_ tracker: OverlayTracker, frame: LumaImage, from start: TimeInterval, seconds: Double,
                      answer: (CGRect) -> [RecognizedBlock]) -> (regions: [CGRect], sent: [String]) {
        var regions: [CGRect] = [], sent: [String] = []
        var time = start
        while time < start + seconds {
            time += 1.0 / 30
            _ = tracker.advance(frame, scale: scale, time: time)
            if let due = tracker.recognitionDue, due <= time, let request = tracker.beginRecognition(time: time) {
                regions.append(request.region)
                tracker.finishRecognition(request, blocks: answer(request.region), time: time + 0.05)
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time + 0.05) {
                sent.append(text)
                tracker.setTranslation("T " + text, for: text)
            }
        }
        return (regions, sent)
    }

    /// Two texts that one pass found apart are two texts, also when their boxes overlap (a
    /// label, a badge or the time in the box of a paragraph's short last line): both stay,
    /// in either order, and the paragraph's translation is drawn
    func testTextsReadApartInOnePassBothStay() throws {
        let screen = SyntheticScreen(seed: 25)
        let whole = Self.paragraph(4, 6, offset: 0, text: "alpha beta gamma delta epsilon zeta")
        let line6 = SyntheticScreen.block(6, offset: 0, text: "").rect
        let label = RecognizedBlock(text: "Sponsored offer",
                                    rect: CGRect(x: line6.maxX - 100, y: line6.minY, width: 100, height: line6.height))
        for order in [[whole, label], [label, whole]] {
            let tracker = OverlayTracker()
            try readAtRest(tracker, screen, offset: 0, blocks: order, time: 0)
            XCTAssertEqual(Set(tracker.blocks.map(\.text)), [whole.text, label.text], "order \(order.map(\.text))")
            let frame = screen.thumbnail(offset: 0, noiseSeed: 7)
            let placed = tracker.advance(frame, scale: scale, time: 2).placed
            XCTAssertTrue(placed.contains { $0.text == "T " + whole.text }, "order \(order.map(\.text))")
            // (and they stay so on the still screen, without reading it again and again)
            let after = idle(tracker, frame: frame, from: 2, seconds: 3, answer: { _ in order })
            XCTAssertEqual(after.regions, [])
            XCTAssertEqual(Set(tracker.blocks.map(\.text)), [whole.text, label.text])
        }
    }

    /// A row of a settings list, as Vision read it on an Android phone: the title with its icon
    /// as one line ("E Display & Touchbedienung", the icon read as a letter) in a box twice the
    /// usual height (100 px in a picture 1080 px wide), which reaches into the summary line right
    /// below it. Both are read in one pass; the title stays and is translated.
    func testATallTitleBoxOverTheSummaryBelowItStays() throws {
        let screen = SyntheticScreen(seed: 26)
        let line4 = SyntheticScreen.block(4, offset: 0, text: "").rect
        let line5 = SyntheticScreen.block(5, offset: 0, text: "").rect
        // (from the top of the title line to half into the summary line)
        let title = RecognizedBlock(text: "E Display & Touchbedienung",
                                    rect: CGRect(x: line4.minX, y: line4.minY, width: line4.width * 0.8,
                                                 height: line5.minY + line5.height / 2 - line4.minY))
        let summary = SyntheticScreen.block(5, offset: 0, text: "Dunkles Design, Schriftgröße, Helligkeit")
        let tracker = OverlayTracker()
        try readAtRest(tracker, screen, offset: 0, blocks: [title, summary], time: 0)
        XCTAssertEqual(Set(tracker.blocks.map(\.text)), [title.text, summary.text])
        let placed = tracker.advance(screen.thumbnail(offset: 0, noiseSeed: 7), scale: scale, time: 2).placed
        XCTAssertTrue(placed.contains { $0.text == "T " + title.text }, "\(placed.map(\.text))")
    }

    /// A small reading of a later pass inside the place of a larger block (one word of it, read
    /// while that place was not read as a whole) does not stand in for it: the paragraph keeps
    /// its translation, and its place is read again
    func testASmallReadingInsideAParagraphDoesNotStandInForIt() throws {
        let screen = SyntheticScreen(seed: 27)
        let tracker = OverlayTracker()
        let whole = Self.paragraph(4, 9, offset: 0, text: "Zum Schluss noch etwas Text über die Seite hier")
        try readAtRest(tracker, screen, offset: 0, blocks: [whole], time: 0)
        let frame = changed(screen, offset: 0, below: 9, mark: 3)
        _ = tracker.advance(frame, scale: scale, time: 3)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 3.5))
        XCTAssertFalse(request.region.contains(whole.rect), "only a part of the paragraph is read")
        let line9 = SyntheticScreen.block(9, offset: 0, text: "").rect
        let word = RecognizedBlock(text: "In", rect: CGRect(x: line9.minX, y: line9.minY, width: 20, height: line9.height))
        tracker.finishRecognition(request, blocks: [word], time: 3.6)
        XCTAssertEqual(tracker.blocks.map(\.text), [whole.text])
        let placed = tracker.advance(frame, scale: scale, time: 3.7).placed
        XCTAssertEqual(placed.map(\.text), ["T " + whole.text])
        let after = idle(tracker, frame: frame, from: 3.7, seconds: 3, answer: { region in
            region.contains(whole.rect) ? [whole] : []
        })
        XCTAssertTrue(after.regions.contains { $0.contains(whole.rect) }, "the paragraph's place is read again")
        XCTAssertLessThanOrEqual(after.regions.count, 2, "\(after.regions)")
        XCTAssertEqual(tracker.blocks.map(\.text), [whole.text])
        XCTAssertEqual(after.sent, [])
    }

    /// One line of a paragraph changes to other words (a status line, a live text) and only the
    /// place of that line is read: the paragraph's place is read again, and its new text is
    /// translated, instead of the line taking the place of the paragraph and its other lines
    /// staying untranslated. Also when the reading covers most of the paragraph (its last two
    /// lines, read as other words).
    func testAParagraphPartOfWhichChangedIsReadAgainWhole() throws {
        let screen = SyntheticScreen(seed: 28)
        let whole = Self.paragraph(4, 6, offset: 0, text: "alpha beta gamma delta epsilon zeta")
        let newWhole = Self.paragraph(4, 6, offset: 0, text: "alpha beta omega sigma tau upsilon")
        // (the second in a box a little taller than its lines: it shares more than
        // `sameBlockOverlap` with the paragraph, and so takes its place as another text)
        var lower = Self.paragraph(5, 6, offset: 0, text: "omega sigma tau upsilon")
        lower.rect = CGRect(x: lower.rect.minX, y: lower.rect.minY - 10, width: lower.rect.width,
                            height: lower.rect.height + 10)
        let readings = [[SyntheticScreen.block(5, offset: 0, text: "omega sigma")], [lower]]
        for reading in readings {
            let tracker = OverlayTracker()
            try readAtRest(tracker, screen, offset: 0, blocks: [whole], time: 0)
            let frame = changed(screen, offset: 0, below: 5, mark: 1)
            _ = tracker.advance(frame, scale: scale, time: 3)
            let request = try XCTUnwrap(tracker.beginRecognition(time: 3.5))
            XCTAssertFalse(request.region.contains(whole.rect), "only a part of the paragraph is read")
            tracker.finishRecognition(request, blocks: reading, time: 3.6)
            let after = idle(tracker, frame: frame, from: 3.6, seconds: 3, answer: { region in
                region.contains(newWhole.rect) ? [newWhole] : []
            })
            XCTAssertTrue(after.regions.contains { $0.contains(whole.rect) }, "\(reading.map(\.text)): \(after.regions)")
            XCTAssertLessThanOrEqual(after.regions.count, 2, "\(after.regions)")
            XCTAssertEqual(tracker.blocks.map(\.text), [newWhole.text], "\(reading.map(\.text))")
            XCTAssertTrue(after.sent.contains(newWhole.text))
            let placed = tracker.advance(frame, scale: scale, time: 7).placed
            XCTAssertEqual(placed.map(\.text), ["T " + newWhole.text])
        }
    }

    /// A line inside a known paragraph whose words are mostly the paragraph's but not a run of
    /// them (a counter or a status in it changed) is no part of it: the paragraph is read again
    /// and its new text translated, instead of the old translation staying over the new text
    func testAChangedLineThatSharesMostWordsHasTheParagraphReadAgain() throws {
        let screen = SyntheticScreen(seed: 29)
        let tracker = OverlayTracker()
        let whole = Self.paragraph(4, 6, offset: 0, text: "Status online since today Anna is reachable now")
        try readAtRest(tracker, screen, offset: 0, blocks: [whole], time: 0)
        let frame = changed(screen, offset: 0, below: 5, mark: 1)
        _ = tracker.advance(frame, scale: scale, time: 3)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 3.5))
        tracker.finishRecognition(request, blocks: [SyntheticScreen.block(5, offset: 0, text: "since yesterday Anna is")],
                                  time: 3.6)
        // (changed by more than a misread letter in ten: `TextSimilarity.isNearlySame`)
        let newWhole = Self.paragraph(4, 6, offset: 0, text: "Status away since yesterday Anna is not reachable")
        let after = idle(tracker, frame: frame, from: 3.6, seconds: 3, answer: { region in
            region.contains(newWhole.rect) ? [newWhole] : []
        })
        XCTAssertTrue(after.regions.contains { $0.contains(whole.rect) }, "\(after.regions)")
        XCTAssertEqual(tracker.blocks.map(\.text), [newWhole.text])
        XCTAssertEqual(after.sent, [newWhole.text])
    }

    /// A strip read while the page glides holds the last line of a translated paragraph and the
    /// line that came in below it (Android, seed 4 of the bench: a 4-line paragraph and a 2-line
    /// reading over its last line). The piece does not take the paragraph's place or its
    /// translation, which would be drawn over the wrong lines: the paragraph stays, and the two
    /// places are read again together
    func testAPieceOverTheLastLineOfAParagraphDoesNotTakeItsPlace() throws {
        let screen = SyntheticScreen(seed: 30)
        let tracker = OverlayTracker()
        let whole = Self.paragraph(4, 7, offset: 0, text: "alpha beta gamma delta epsilon zeta eta theta")
        try readAtRest(tracker, screen, offset: 0, blocks: [whole], time: 0)
        // (something changes between lines 7 and 8, in one row of tiles: the pass reads both)
        var frame = screen.thumbnail(offset: 0, noiseSeed: 7)
        let line7 = SyntheticScreen.block(7, offset: 0, text: "").rect
        let y = (Int(line7.maxY) / scale + 8) / 8 * 8 + 1
        for row in y..<(y + 2) {
            for x in 4..<196 where (x + 1) % 4 != 0 {
                frame[x, row] = 0
            }
        }
        _ = tracker.advance(frame, scale: scale, time: 3)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 3.5))
        let piece = Self.paragraph(7, 8, offset: 0, text: "zeta eta theta iota")
        XCTAssertTrue(request.region.contains(piece.rect), "\(request.region)")
        XCTAssertFalse(request.region.contains(whole.rect), "only a part of the paragraph is read")
        tracker.finishRecognition(request, blocks: [piece], time: 3.6)

        XCTAssertEqual(tracker.blocks.map(\.text), [whole.text], "the paragraph stays")
        let placed = tracker.advance(frame, scale: scale, time: 3.7).placed
        XCTAssertEqual(placed.map(\.text), ["T " + whole.text])
        let drawn = try XCTUnwrap(placed.first)
        XCTAssertEqual(drawn.rect.minY, whole.rect.minY, accuracy: 2 * Double(scale),
                       "the translation stays on the paragraph's lines")
        // (read again together, the two places come back as one paragraph)
        let longer = Self.paragraph(4, 8, offset: 0, text: "alpha beta gamma delta epsilon zeta eta theta iota")
        let after = idle(tracker, frame: frame, from: 3.7, seconds: 3, answer: { region in
            region.contains(longer.rect) ? [longer] : []
        })
        XCTAssertTrue(after.regions.contains { $0.contains(longer.rect) }, "\(after.regions)")
        XCTAssertLessThanOrEqual(after.regions.count, 2, "\(after.regions)")
        XCTAssertEqual(tracker.blocks.map(\.text), [longer.text])
        XCTAssertEqual(after.sent, [longer.text])
    }

    /// A piece of a paragraph is a run of its words, but for a misread letter; a line whose
    /// words changed is not, even when it shares most of them
    func testARunOfAParagraphsWords() {
        let whole = "Status online since today Anna is reachable now"
        XCTAssertTrue(TextSimilarity.isRun("since today Anna is", of: whole))
        XCTAssertTrue(TextSimilarity.isRun("Since tuday Anna is", of: whole))
        XCTAssertTrue(TextSimilarity.isRun("now", of: whole))
        XCTAssertFalse(TextSimilarity.isRun("since yesterday Anna is", of: whole))
        XCTAssertFalse(TextSimilarity.isRun("today since Anna is", of: whole))
        XCTAssertFalse(TextSimilarity.isRun(whole + " again", of: whole))
        XCTAssertFalse(TextSimilarity.isRun("", of: whole))
        XCTAssertTrue(TextSimilarity.isRun("Dunkles Design, Schrift-", of: "Dunkles Design, Schrift- größe, Helligkeit"))
    }

    /// The synthetic screen at `offset` with the page between the bars stretched by `stretch`
    /// from the top bar down (an overscroll that springs back: the picture stretches, it does
    /// not shift)
    private static func stretched(_ screen: SyntheticScreen, offset: Int, stretch: Double, noiseSeed: UInt64) -> LumaImage {
        let width = SyntheticScreen.width, height = SyntheticScreen.height
        var plain = screen.thumbnail(offset: offset)
        guard stretch != 1 else { return SyntheticPage.noisy(plain, amount: 2, seed: noiseSeed) }
        var full = [UInt8](repeating: 225, count: width * height)
        for y in SyntheticScreen.topBar..<SyntheticScreen.bottomBar {
            let source = offset + SyntheticScreen.topBar + Int(Double(y - SyntheticScreen.topBar) / stretch)
            guard source >= 0, source < screen.pageHeight else { continue }
            for x in 0..<width {
                full[y * width + x] = screen.page[source * width + x]
            }
        }
        let page = LumaImage(width: width, height: height, pixels: full).downsampled(by: SyntheticScreen.scale)
        // (the bars as they are)
        for y in (SyntheticScreen.topBar / 2)..<(SyntheticScreen.bottomBar / 2) {
            for x in 0..<page.width {
                plain[x, y] = page[x, y]
            }
        }
        return SyntheticPage.noisy(plain, amount: 2, seed: noiseSeed)
    }

    /// After a fling to the end of a page, the page springs back (the picture stretches and
    /// shrinks again, nothing shifts). Passes during the spring-back find only a word of a
    /// translated paragraph; once the picture rests, its place is read whole and translated.
    /// (The shrinking page moves where it is stretched most: that counts as motion, so the
    /// spring-back does not pass for rest.)
    func testAParagraphKeepsItsTranslationThroughASpringBack() throws {
        let screen = SyntheticScreen(seed: 30)
        let tracker = OverlayTracker()
        let offset = 300
        let whole = Self.paragraph(8, 10, offset: offset, text: "Zum Schluss noch etwas Text über die Seite hier")
        func truth(_ region: CGRect) -> [RecognizedBlock] { region.contains(whole.rect) ? [whole] : [] }
        var time = 0.0
        var frame = Self.stretched(screen, offset: offset - 40, stretch: 1, noiseSeed: 1)
        _ = tracker.advance(frame, scale: scale, time: time)
        // the fling: 4 px a frame up to the end of the page
        var position = offset - 40
        while position < offset {
            position += 4
            time += 1.0 / 60
            frame = Self.stretched(screen, offset: position, stretch: 1, noiseSeed: UInt64(position))
            _ = tracker.advance(frame, scale: scale, time: time)
        }
        // read and translated
        _ = idle(tracker, frame: frame, from: time, seconds: 1, answer: truth)
        time += 1
        XCTAssertTrue(tracker.advance(frame, scale: scale, time: time).placed.contains { $0.text == "T " + whole.text })
        // the spring-back, half a second; passes that run meanwhile find one word of it
        let line10 = SyntheticScreen.block(10, offset: offset, text: "").rect
        let word = RecognizedBlock(text: "In", rect: CGRect(x: line10.minX, y: line10.minY, width: 20, height: line10.height))
        for step in 0..<30 {
            time += 1.0 / 60
            let stretch = 1 + 0.06 * (1 - Double(step) / 30) * (1 - Double(step) / 30)
            frame = Self.stretched(screen, offset: offset, stretch: stretch, noiseSeed: UInt64(100 + step))
            _ = tracker.advance(frame, scale: scale, time: time)
            if let due = tracker.recognitionDue, due <= time, let request = tracker.beginRecognition(time: time) {
                tracker.finishRecognition(request, blocks: request.region.intersects(word.rect) ? [word] : [],
                                          time: time + 0.03)
            }
        }
        frame = Self.stretched(screen, offset: offset, stretch: 1, noiseSeed: 200)
        _ = idle(tracker, frame: frame, from: time, seconds: 3, answer: truth)
        let placed = tracker.advance(frame, scale: scale, time: time + 3.1).placed
        XCTAssertTrue(placed.contains { $0.text == "T " + whole.text }, "\(placed.map(\.text))")
    }

    /// A paragraph of which only its first line was taken (the rest was not in view then) is
    /// read whole once a reading finds more of it, also when that reading is cut off itself:
    /// the line alone must not keep the paragraph from being read
    func testAParagraphKnownOnlyInPartIsReadWhole() throws {
        let screen = SyntheticScreen(seed: 23)
        let tracker = OverlayTracker()
        try readAtRest(tracker, screen, offset: 0, blocks: [SyntheticScreen.block(4, offset: 0, text: "alpha beta")],
                       time: 0)
        _ = tracker.advance(changed(screen, offset: 0, below: 5, mark: 1), scale: scale, time: 3)
        let first = try XCTUnwrap(tracker.beginRecognition(time: 3.5))
        // more lines of it, the last of them read only in part (something hides it)
        var more = Self.paragraph(4, 5, offset: 0, text: "alpha beta gamma delta")
        more.cutOffEdges = FrameMotion.bottom
        tracker.finishRecognition(first, blocks: [more], time: 3.6)

        let again = try XCTUnwrap(tracker.beginRecognition(time: 3.7), "the paragraph is read again")
        let whole = Self.paragraph(4, 6, offset: 0, text: "alpha beta gamma delta epsilon zeta")
        tracker.finishRecognition(again, blocks: [whole], time: 3.8)
        XCTAssertEqual(tracker.blocks.map(\.text), [whole.text])
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 3.8), [whole.text])
    }

    /// Runs the passes that are due at `time`, each with those of `lines` that lie in the region
    /// it reads and above `bottom` (frame pixels), as a recognizer would find them
    private func readDue(_ tracker: OverlayTracker, at time: TimeInterval, lines: [RecognizedBlock],
                         bottom: Double) {
        for _ in 0..<8 {
            guard let due = tracker.recognitionDue, due <= time + 1e-9,
                  let request = tracker.beginRecognition(time: time) else { return }
            let found = lines.filter { request.region.contains($0.rect) && $0.rect.maxY <= bottom }
            tracker.finishRecognition(request, blocks: found, time: time)
        }
    }

    /// While the page moves, a paragraph that ends right at the edge of the view may go on
    /// beyond it: it is not sent then. Once the band below it has come into view without a
    /// line that continues it, it is; and so it is once the page rests.
    func testAParagraphAtTheEdgeOfTheViewIsSentOnceItCannotGoOn() throws {
        let screen = SyntheticScreen(seed: 24)
        let bar = Double(SyntheticScreen.bottomBar)
        // line 11 ends 10 px above the bottom bar at this offset
        let line = 11
        let start = SyntheticScreen.firstLine + SyntheticScreen.linePitch * line + SyntheticScreen.lineHeight + 10
            - SyntheticScreen.bottomBar
        func frame(_ offset: Int) -> LumaImage { screen.thumbnail(offset: offset, noiseSeed: 7) }
        func lines(_ offset: Int) -> [RecognizedBlock] {
            [SyntheticScreen.block(line, offset: offset, text: "Eleven"),
             SyntheticScreen.block(line + 1, offset: offset, text: "Twelve")]
        }
        func run(restAfterwards: Bool) throws {
            let tracker = OverlayTracker()
            var offset = start - 60, time = 0.0
            _ = tracker.advance(frame(offset), scale: scale, time: time)
            readDue(tracker, at: 1, lines: lines(offset), bottom: bar)
            // the page moves up, 4 px a frame, until the line ends right above the bar
            time = 2
            while offset < start {
                offset += 4
                time += 1.0 / 60
                _ = tracker.advance(frame(offset), scale: scale, time: time)
                readDue(tracker, at: time, lines: lines(offset), bottom: bar)
            }
            // what came in last is read, while the page has only just stopped
            time += 0.05
            readDue(tracker, at: time, lines: lines(offset), bottom: bar)
            XCTAssertEqual(tracker.blocks.map(\.text).filter { $0 == "Eleven" }, ["Eleven"])
            XCTAssertFalse(tracker.textsAwaitingTranslation(limit: 10, time: time).contains("Eleven"),
                           "its next line may be about to come in")
            if restAfterwards {
                // a moment later the page rests: a pass is due, and the translator is asked after it
                let rest = time + tracker.configuration.restDelay
                let due = try XCTUnwrap(tracker.recognitionDue, "a pass is due once it rests")
                XCTAssertLessThanOrEqual(due, rest)
                readDue(tracker, at: rest, lines: lines(offset), bottom: bar)
                XCTAssertTrue(tracker.textsAwaitingTranslation(limit: 10, time: rest).contains("Eleven"))
                return
            }
            // on: the band below it comes into view (nothing in it continues the line)
            var sent: [String] = []
            for _ in 0..<20 where !sent.contains("Eleven") {
                offset += 4
                time += 1.0 / 60
                _ = tracker.advance(frame(offset), scale: scale, time: time)
                readDue(tracker, at: time, lines: lines(offset), bottom: bar)
                sent += tracker.textsAwaitingTranslation(limit: 10, time: time)
            }
            XCTAssertTrue(sent.contains("Eleven"), "the band below it came into view while the page moved")
        }
        try run(restAfterwards: true)
        try run(restAfterwards: false)
    }

    /// A strip of cards that glides sideways without a pause (a ticker, a carousel that turns by
    /// itself) above the page: its frame with the page scrolled by `offset` and the strip by
    /// `shift` thumbnail pixels
    private static func withTicker(_ frame: LumaImage, shift: Int, pattern: [UInt8]) -> LumaImage {
        var frame = frame
        let width = frame.width, rows = pattern.count / 256
        for row in 0..<rows {
            for x in 0..<width {
                frame[x, Self.tickerTop + row] = pattern[row * 256 + (x + shift) % 256]
            }
        }
        return frame
    }

    private static let tickerTop = 40

    private static func tickerPattern(seed: UInt64) -> [UInt8] {
        var random = SyntheticPage.Random(state: seed)
        var pattern = [UInt8](repeating: 0, count: 256 * 24)
        // (columns of a few pixels, each of its own grey, with a little texture inside)
        var x = 0
        while x < 256 {
            let width = 2 + random.below(5), level = 40 + random.below(170)
            for column in x..<min(256, x + width) {
                for row in 0..<24 {
                    pattern[row * 256 + column] = UInt8(min(255, level + random.below(24)))
                }
            }
            x += width
        }
        return pattern
    }

    /// Rest is decided for each scrolling area: a strip that keeps gliding sideways beside the
    /// page does not keep a paragraph at the bottom bar from being sent once the page rests,
    /// and reading the page comes to rest with it
    func testAParagraphAtTheBarIsSentWhileATickerKeepsMoving() throws {
        let screen = SyntheticScreen(seed: 31)
        let pattern = Self.tickerPattern(seed: 5)
        let bar = Double(SyntheticScreen.bottomBar)
        let line = 11
        let start = SyntheticScreen.firstLine + SyntheticScreen.linePitch * line + SyntheticScreen.lineHeight + 10
            - SyntheticScreen.bottomBar
        func lines(_ offset: Int) -> [RecognizedBlock] {
            [SyntheticScreen.block(line, offset: offset, text: "Eleven"),
             SyntheticScreen.block(line + 1, offset: offset, text: "Twelve")]
        }
        for moving in [false, true] {
            let tracker = OverlayTracker()
            var offset = start - 60, time = 0.0, shift = 0
            func step() {
                time += 1.0 / 60
                if moving { shift += 2 }
                let frame = Self.withTicker(screen.thumbnail(offset: offset, noiseSeed: 7), shift: shift,
                                            pattern: pattern)
                _ = tracker.advance(frame, scale: scale, time: time)
            }
            for _ in 0..<60 {
                step()
                readDue(tracker, at: time, lines: lines(offset), bottom: bar)
            }
            // the page moves up, 4 px a frame, until the line ends right above the bar
            while offset < start {
                offset += 4
                step()
                readDue(tracker, at: time, lines: lines(offset), bottom: bar)
            }
            // then it rests for two seconds, while the strip goes on
            var sent: [String] = [], passes = 0, sentAt: TimeInterval?
            let stop = time
            while time < stop + 2 {
                step()
                for _ in 0..<8 {
                    guard let due = tracker.recognitionDue, due <= time + 1e-9,
                          let request = tracker.beginRecognition(time: time) else { break }
                    // (what enters the strip is read as it comes in: only passes over the page count)
                    if request.region.maxY > Double((Self.tickerTop + 24 + 24) * scale) { passes += 1 }
                    let found = lines(offset).filter { request.region.contains($0.rect) && $0.rect.maxY <= bar }
                    tracker.finishRecognition(request, blocks: found, time: time)
                }
                for text in tracker.textsAwaitingTranslation(limit: 10, time: time) {
                    sent.append(text)
                    if text == "Eleven" { sentAt = time }
                    tracker.setTranslation("T " + text, for: text)
                }
            }
            let at = try XCTUnwrap(sentAt, "moving \(moving): sent once the page rests")
            XCTAssertLessThanOrEqual(at - stop, 1, "moving \(moving)")
            XCTAssertEqual(sent.filter { $0 == "Eleven" }, ["Eleven"], "moving \(moving)")
            XCTAssertLessThanOrEqual(passes, 4, "moving \(moving): reading the page comes to rest")
        }
    }

    /// The end of a page whose ground below its last line shows no movement (it stops there
    /// while it springs back) is not taken for a bar: a translation there is not cut off
    func testTheEndOfAPageIsNoBar() {
        var image = LumaImage(width: 200, height: 400, pixels: [UInt8](repeating: 240, count: 200 * 400))
        // the last line of the page, the plain ground below it, a bar from row 370
        for y in 280..<292 {
            for x in stride(from: 10, to: 150, by: 3) { image[x, y] = 30 }
        }
        for y in 370..<400 {
            for x in 0..<200 { image[x, y] = (x / 4) % 2 == 0 ? 200 : 120 }
        }
        let known = ThumbnailRect(x: 0, y: 30, width: 200, height: 340)
        let atPageEnd = FrameMotion(dx: 0, dy: -1, area: ThumbnailRect(x: 0, y: 30, width: 200, height: 264), tiles: 200,
                                    refinedEdges: FrameMotion.top | FrameMotion.bottom)
        XCTAssertEqual(OverlayTracker.plainShrink(of: known, edges: FrameMotion.top | FrameMotion.bottom, to: atPageEnd,
                                                  in: image, plainRange: 10), FrameMotion.bottom)
        // something that is not plain between the edges: a bar that came up
        let atBar = FrameMotion(dx: 0, dy: -1, area: ThumbnailRect(x: 0, y: 30, width: 200, height: 240), tiles: 200,
                                refinedEdges: FrameMotion.top | FrameMotion.bottom)
        XCTAssertEqual(OverlayTracker.plainShrink(of: known, edges: FrameMotion.top | FrameMotion.bottom, to: atBar,
                                                  in: image, plainRange: 10), 0)
    }
}

extension ReadingPlanTests {
    /// A place that cannot be seen completely while the picture moves (it lies at a bar) is read
    /// once the picture rests, once for each time it comes to rest
    func testAPlaceThatCannotBeSeenIsReadOnceThePictureRests() {
        let configuration = OverlayTracker.Configuration()
        let plan = ReadingPlan(configuration: configuration)
        plan.add(UnreadArea(rect: CGRect(x: 0, y: 360, width: 200, height: 30), kind: .reread, since: 5))
        let due = plan.due(lastMotion: 5.2, isFullyVisible: { _ in false })
        XCTAssertEqual(due ?? 0, 5.2 + configuration.restDelay, accuracy: 1e-9)
        // asked for while it rests: it waits for the next movement
        let later = ReadingPlan(configuration: configuration)
        later.add(UnreadArea(rect: CGRect(x: 0, y: 360, width: 200, height: 30), kind: .reread, since: 9))
        XCTAssertNil(later.due(lastMotion: 5.2, isFullyVisible: { _ in false }))
        XCTAssertEqual(later.due(lastMotion: 9.5, isFullyVisible: { _ in false }) ?? 0, 9.5 + configuration.restDelay,
                       accuracy: 1e-9)
    }
}
