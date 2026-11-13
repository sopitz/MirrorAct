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
