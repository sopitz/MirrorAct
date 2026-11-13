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
}
