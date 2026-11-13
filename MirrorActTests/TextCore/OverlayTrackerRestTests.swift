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
            return RecognizedBlock(text: String(letters[first...last]),
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
    /// what is drawn into every frame; passes take 0.3 s and read what `lines` show in their
    /// region; what is asked for is translated at once
    private func show(_ lines: [Line], on tracker: OverlayTracker, from start: TimeInterval, seconds: Double,
                      seed: inout UInt64, each: ([String]) -> Void = { _ in })
        -> (regions: [CGRect], sent: [String], placed: [String]) {
        var regions: [CGRect] = [], sent: [String] = [], placed: [String] = []
        let picture = Self.picture(lines)
        var time = start
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        while time < start + seconds {
            time += 1.0 / 30
            seed += 1
            let frame = SyntheticPage.noisy(picture, amount: 2, seed: seed)
            placed = tracker.advance(frame, scale: Self.scale, time: time).placed.map(\.text)
            each(placed)
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
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
        return (regions, sent, placed)
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
}
