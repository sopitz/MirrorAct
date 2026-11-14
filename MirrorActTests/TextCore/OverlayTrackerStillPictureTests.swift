// SPDX-License-Identifier: GPL-3.0-or-later
import CoreText
import Foundation
import XCTest
@testable import MirrorAct

/// A picture that does not change is read a few times and then not at all, until it changes:
/// the screens are those of a phone 1080 × 2400 (thumbnails at scale 3), as in the lab, where a
/// still page was read some seven times a second for minutes.
final class OverlayTrackerStillPictureTests: XCTestCase {
    private static let scale = 3, width = 1080, height = 2400

    /// A line of dark text on the plain page, drawn with Core Text in Helvetica; its box is the
    /// one given here (frame pixels), as the recognizer's box of a line is
    struct Line {
        var text: String
        var box: CGRect
        var fontSize: Double

        private var font: CTFont { CTFontCreateWithName("Helvetica" as CFString, fontSize, nil) }

        private var ctLine: CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 30 / 255, alpha: 1),
            ]))
        }

        func draw(in context: CGContext) {
            context.textPosition = CGPoint(x: box.minX, y: Double(OverlayTrackerStillPictureTests.height) - box.maxY
                                           + Double(CTFontGetDescent(font)))
            CTLineDraw(ctLine, context)
        }

        /// Where each letter begins, and where the last one ends (frame pixels)
        private var edges: [Double] {
            let line = ctLine, utf16 = Array(text.utf16)
            var result: [Double] = []
            var index = 0
            for character in text {
                result.append(box.minX + Double(CTLineGetOffsetForStringIndex(line, index, nil)))
                index += String(character).utf16.count
            }
            result.append(box.minX + Double(CTLineGetOffsetForStringIndex(line, utf16.count, nil)))
            return result
        }

        /// What a recognizer reads of the line in `region`: the letters that reach into it, in a
        /// box that ends at the region's edges (as Vision reads a line cut by the edge of what it
        /// reads, also one cut through its letters if half of its height is left, which it then
        /// misreads: "Das veer a druly" for "Das Wetter in Hamburg"); nil when less is left.
        /// `whole` = all of the line, in its own box.
        func reading(in region: CGRect) -> (text: String, rect: CGRect, whole: Bool)? {
            let rows = box.intersection(region)
            guard !rows.isNull, rows.height * 2 >= box.height else { return nil }
            let letters = Array(text), edges = edges
            var first: Int?, last: Int?
            for index in letters.indices where letters[index] != " " {
                guard edges[index + 1] > region.minX, edges[index] < region.maxX else { continue }
                first = first ?? index
                last = index
            }
            guard let first, let last else { return nil }
            let minX = max(edges[first], region.minX), maxX = min(edges[last + 1], region.maxX)
            let whole = first == 0 && last == letters.count - 1 && rows.height >= box.height
            var read = Array(letters[first...last])
            if rows.height < box.height {
                for index in read.indices where index % 2 == 1 && read[index] != " " { read[index] = "x" }
            }
            return (String(read),
                    CGRect(x: minX, y: rows.minY, width: maxX - minX, height: rows.height), whole)
        }
    }

    /// What a recognizer makes of `paragraphs` (lists of lines) in `region`: each paragraph whose
    /// lines it reads whole as one block, and every line it reads only in part as a block of its own
    static func recognize(_ paragraphs: [[Line]], in region: CGRect) -> [RecognizedBlock] {
        var blocks: [RecognizedBlock] = []
        for lines in paragraphs {
            var whole: [Line] = []
            for line in lines {
                guard let reading = line.reading(in: region) else { continue }
                if reading.whole {
                    whole.append(line)
                } else {
                    blocks.append(RecognizedBlock(text: reading.text, rect: reading.rect))
                }
            }
            guard let first = whole.first else { continue }
            let rect = whole.dropFirst().reduce(first.box) { $0.union($1.box) }
            blocks.append(RecognizedBlock(text: whole.map(\.text).joined(separator: " "), rect: rect,
                                          lineCount: whole.count))
        }
        return blocks
    }

    /// The thumbnail of a plain page with `paragraphs`, and a dark bar where `bar` says (frame pixels)
    static func picture(_ paragraphs: [[Line]], bar: CGRect? = nil) -> LumaImage {
        var gray = [UInt8](repeating: 245, count: width * height)
        gray.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            for line in paragraphs.joined() {
                line.draw(in: context)
            }
            if let bar {
                context.setFillColor(gray: 120 / 255, alpha: 1)
                context.fill(CGRect(x: bar.minX, y: Double(height) - bar.maxY, width: bar.width, height: bar.height))
            }
        }
        return gray.withUnsafeBytes { bytes in
            LumaImage.downsampled(from: bytes.baseAddress!, width: width, height: height, bytesPerRow: width,
                                  format: .luma8, scale: scale)
        }
    }

    /// Shows `picture` for `seconds` at 30 frames per second from `start`; a pass takes 0.08 s and
    /// reads what `paragraphs` show in its region (`answer`: nil = the recognizer fails); what is
    /// asked for is translated at once. The regions of the passes begun.
    private func show(_ picture: LumaImage, _ paragraphs: [[Line]], on tracker: OverlayTracker,
                      from start: TimeInterval, seconds: Double, seed: inout UInt64,
                      answer: ((CGRect) -> [RecognizedBlock]?)? = nil) -> [CGRect] {
        var regions: [CGRect] = []
        var time = start
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock]?, at: TimeInterval)?
        while time < start + seconds {
            time += 1.0 / 30
            seed += 1
            _ = tracker.advance(SyntheticPage.noisy(picture, amount: 2, seed: seed), scale: Self.scale, time: time)
            // (several passes in a frame's time, as the app reads again at once)
            var step = time
            while step < time + 1.0 / 30 {
                if let job = pending, step >= job.at {
                    if let blocks = job.answer {
                        tracker.finishRecognition(job.request, blocks: blocks, time: step)
                    } else {
                        tracker.abandonRecognition(job.request)
                    }
                    pending = nil
                }
                if pending == nil, let due = tracker.recognitionDue, due <= step,
                   let request = tracker.beginRecognition(time: step) {
                    regions.append(request.region)
                    let blocks = answer.map { $0(request.region) } ?? Self.recognize(paragraphs, in: request.region)
                    pending = (request, blocks, step + 0.08)
                }
                step += 0.01
            }
            // (a pass still running when the picture is shown no longer ends with it)
            if time >= start + seconds, let job = pending {
                if let blocks = job.answer {
                    tracker.finishRecognition(job.request, blocks: blocks, time: time)
                } else {
                    tracker.abandonRecognition(job.request)
                }
                pending = nil
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                tracker.setTranslation("T " + text, for: text)
            }
        }
        return regions
    }

    /// A heading over a German paragraph, and right below that an English one, which the layout
    /// keeps apart (as on the lab's page after a swipe; thumbnail rows 132–153, 170–236 and
    /// 248–314). The scroll indicator at the right edge fades out after the page has come to
    /// rest: a narrow pass over the right edge reads a few letters of the English paragraph's
    /// first line, cut off by its left edge, which holds the paragraph for a reading of its place,
    /// and both paragraphs are read together. The margin of that pass cuts the heading above
    /// them, the pass that reads the heading again cuts the German paragraph's first line, which
    /// holds that paragraph in turn, and both paragraphs were asked for again, each time as for
    /// the first time: the page was read for as long as it stayed. Reading two paragraphs
    /// together is reading their place again, and counts: the screen is read a few times after
    /// the indicator went, and then nothing is due.
    func testANarrowReadingBesideAParagraphDoesNotKeepAStillPageBeingRead() {
        let heading = [Line(text: "Das Wetter in Hamburg", box: CGRect(x: 54, y: 396, width: 626, height: 63),
                            fontSize: 60)]
        let german = (0..<3).map { index in
            Line(text: ["Am Montag bleibt es überwiegend bewölkt,", "gelegentlich fällt leichter Regen. Die",
                        "Temperaturen steigen tagsüber auf zwölf"][index],
                 box: CGRect(x: 51, y: 510 + 66 * Double(index), width: 915, height: 66), fontSize: 48)
        }
        let english = (0..<3).map { index in
            Line(text: ["This paragraph is already written in English and", "is the language this Mac translates into,",
                        "so the app must leave it exactly as it is and"][index],
                 box: CGRect(x: 48, y: 744 + 66 * Double(index), width: 1011, height: 66), fontSize: 48)
        }
        let paragraphs = [heading, german, english]
        let page = Self.picture(paragraphs)
        let tracker = OverlayTracker()
        var seed: UInt64 = 7
        _ = show(page, paragraphs, on: tracker, from: 0, seconds: 2, seed: &seed)
        XCTAssertEqual(Set(tracker.blocks.map(\.text)), Set(paragraphs.map { $0.map(\.text).joined(separator: " ") }))
        XCTAssertNil(tracker.recognitionDue)

        // the indicator shows for two frames and fades out
        let indicator = Self.picture(paragraphs, bar: CGRect(x: 1062, y: 750, width: 9, height: 180))
        _ = show(indicator, paragraphs, on: tracker, from: 2, seconds: 0.06, seed: &seed)
        let regions = show(page, paragraphs, on: tracker, from: 2.1, seconds: 6, seed: &seed)
        XCTAssertLessThanOrEqual(regions.count, 4, "\(regions)")
        XCTAssertNil(tracker.recognitionDue)
        XCTAssertEqual(Set(tracker.blocks.map(\.text)), Set(paragraphs.map { $0.map(\.text).joined(separator: " ") }))
    }

    /// Whatever keeps asking for a place to be read: a picture that does not change is read
    /// `maxPassesOnPicture` times and then not at all until it changes. Here the recognizer
    /// fails on every pass (its region is asked for again each time); a change of the picture
    /// is read again at once, and with a recognizer that works, read and translated.
    func testAStillPictureIsReadABoundedNumberOfTimes() {
        let title = [Line(text: "Netzwerk & Internet", box: CGRect(x: 54, y: 400, width: 600, height: 63), fontSize: 60)]
        let tracker = OverlayTracker()
        var seed: UInt64 = 3
        let still = show(Self.picture([title]), [title], on: tracker, from: 0, seconds: 10, seed: &seed,
                         answer: { _ in nil })
        XCTAssertEqual(still.count, tracker.configuration.maxPassesOnPicture, "\(still)")
        XCTAssertNil(tracker.recognitionDue)
        // (what a debug dump shows of it: the whole frame still to be read, the passes spent)
        let state = tracker.readingState
        XCTAssertEqual(state.passesOnPicture, tracker.configuration.maxPassesOnPicture)
        XCTAssertNil(state.due)
        XCTAssertFalse(state.isReading)
        XCTAssertEqual(state.places.map(\.kind), ["changed"])
        XCTAssertEqual(state.places.first?.rect, CGRect(x: 0, y: 0, width: 1080, height: 2400))
        XCTAssertEqual(state.blocks.count, 0)

        let changed = [Line(text: "Netzwerk & Intranet", box: CGRect(x: 54, y: 400, width: 600, height: 63), fontSize: 60)]
        let after = show(Self.picture([changed]), [changed], on: tracker, from: 10, seconds: 3, seed: &seed)
        XCTAssertGreaterThanOrEqual(after.count, 1)
        XCTAssertLessThanOrEqual(after.count, tracker.configuration.maxPassesOnPicture)
        XCTAssertEqual(tracker.blocks.map(\.text), ["Netzwerk & Intranet"])
        XCTAssertEqual(tracker.blocks.map(\.translation), ["T Netzwerk & Intranet"])
    }

    /// The bound holds back only reading that would go on without end: a still picture that
    /// takes many passes to read (here the recognizer fails on the first 18, a little less than
    /// the most a picture of the tracking bench needed) is still read and translated.
    func testAStillPictureThatTakesManyPassesIsStillRead() {
        let title = [Line(text: "Netzwerk & Internet", box: CGRect(x: 54, y: 400, width: 600, height: 63), fontSize: 60)]
        let tracker = OverlayTracker()
        var seed: UInt64 = 5
        var failures = 18
        let passes = show(Self.picture([title]), [title], on: tracker, from: 0, seconds: 10, seed: &seed,
                          answer: { region in
                              guard failures == 0 else { failures -= 1; return nil }
                              return Self.recognize([title], in: region)
                          })
        XCTAssertGreaterThan(passes.count, 18, "\(passes)")
        XCTAssertLessThanOrEqual(passes.count, tracker.configuration.maxPassesOnPicture)
        XCTAssertEqual(tracker.blocks.map(\.text), ["Netzwerk & Internet"])
        XCTAssertEqual(tracker.blocks.map(\.translation), ["T Netzwerk & Internet"])
        XCTAssertNil(tracker.recognitionDue)
    }

    /// The screen of a page under a bar with its title slides in from the right (the viewer
    /// shows the page again), so the movement covers the bar as well: the title, read once the
    /// screen rests, lies in the scrolling area of that movement. Then the page scrolls up under
    /// the bar: its movement joins that area, whose top edge is found where the bar ends, and the
    /// title lay above it. It stayed where it was, translated, and was cut off by that edge for
    /// good: not drawn at all, while the page around it was translated (as on the phone, after a
    /// swipe on a page shown again while Translate was on). A block that shows whole and stays
    /// where it is while its area moves, outside of that area, lies over the content, and the
    /// area's edge does not cut it off.
    func testTheTitleOfABarStaysDrawnAfterTheScreenSlidInAndThePageScrolls() {
        let screen = SyntheticScreen(seed: 5)
        let title = CGRect(x: 150, y: 20, width: 100, height: 20)
        let tracker = OverlayTracker()
        var time = 0.0, seed: UInt64 = 1
        var pending: (request: RecognitionRequest, blocks: [RecognizedBlock], at: TimeInterval)?
        var titleDrawn = 0, frames = 0
        /// what a pass reads of the screen moved sideways by `shift` and scrolled by `offset`
        func read(_ region: CGRect, shift: Int, offset: Int) -> [RecognizedBlock] {
            var blocks: [RecognizedBlock] = []
            let shown = title.offsetBy(dx: Double(shift), dy: 0)
            if region.contains(shown) { blocks.append(RecognizedBlock(text: "Titel", rect: shown)) }
            for index in 0..<50 {
                var block = SyntheticScreen.block(index, offset: offset, text: "Zeile \(index)")
                block.rect = block.rect.offsetBy(dx: Double(shift), dy: 0)
                guard block.rect.minY >= Double(SyntheticScreen.topBar), block.rect.maxY <= Double(SyntheticScreen.bottomBar),
                      region.contains(block.rect) else { continue }
                blocks.append(block)
            }
            return blocks
        }
        func frame(shift: Int, offset: Int, counting: Bool) {
            time += 1.0 / 30
            seed += 1
            var image = screen.thumbnail(offset: offset)
            if shift > 0 {
                // (moved right by `shift` frame pixels: what comes in on the left is the bar's grey)
                let moved = shift / SyntheticScreen.scale
                var pixels = [UInt8](repeating: 225, count: image.pixels.count)
                for y in 0..<image.height {
                    for x in moved..<image.width {
                        pixels[y * image.width + x] = image.pixels[y * image.width + x - moved]
                    }
                }
                image.pixels = pixels
            }
            let placed = tracker.advance(SyntheticPage.noisy(image, amount: 2, seed: seed), scale: SyntheticScreen.scale,
                                         time: time).placed
            if counting {
                frames += 1
                if placed.contains(where: { $0.text == "T Titel" }) { titleDrawn += 1 }
            }
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.blocks, time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                pending = (request, read(request.region, shift: shift, offset: offset), time + 0.1)
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                tracker.setTranslation("T " + text, for: text)
            }
        }
        for shift in stride(from: 200, through: 0, by: -20) {
            frame(shift: shift, offset: 500, counting: false)
        }
        for _ in 0..<45 {
            frame(shift: 0, offset: 500, counting: false)
        }
        XCTAssertTrue(tracker.blocks.contains { $0.text == "Titel" && $0.translation == "T Titel" })
        for step in 1...10 {
            frame(shift: 0, offset: 500 + 6 * step, counting: true)
        }
        for _ in 0..<60 {
            frame(shift: 0, offset: 560, counting: true)
        }
        XCTAssertEqual(titleDrawn, frames, "the title drawn in \(titleDrawn) of \(frames) frames")
    }

    /// As above, the screen slid in and the page scrolled under the bar, then rests: the title
    /// lies over the page's content. Then the title changes in place ("Titel 3" becomes
    /// "Titel 4", or "Titel" becomes "Titel neu": the bar of a list that counts its rows), and
    /// the new reading took the old block's area but not its mark, so the area's top edge cut it
    /// to nothing for as long as the page rested. A reading of other text in the place of a
    /// block over the content takes the mark with the area.
    func testTheTitleOfABarStaysDrawnWhenItsTextChangesInPlace() {
        for (initial, changed) in [("Titel 3", "Titel 4"), ("Titel", "Titel neu")] {
            let result = barTitleAtRest(initial: initial, changed: changed)
            XCTAssertGreaterThanOrEqual(result.drawn, result.frames - 30,
                                        "'\(changed)' drawn in \(result.drawn) of \(result.frames) frames")
            XCTAssertEqual(result.stale, 0, "the translation of '\(initial)' drawn after the change")
        }
    }

    /// As above, but the title does not change: something covers its right part for a third
    /// of a second (the ripple of a touch), so it is not found where it is. It lost its mark
    /// then, and once it was found again it was cut to nothing by the area's top edge for as
    /// long as the page rested. A block that is not found where it is keeps the mark; one that a
    /// movement carries while it is not found loses it.
    func testTheTitleOfABarStaysDrawnAfterItWasCoveredForAMoment() {
        let result = barTitleAtRest(initial: "Titel", changed: "Titel", coverFrames: 10)
        XCTAssertGreaterThanOrEqual(result.drawn, result.frames - 30,
                                    "the title drawn in \(result.drawn) of \(result.frames) frames")
    }

    /// The screen of `testTheTitleOfABarStaysDrawnAfterTheScreenSlidInAndThePageScrolls`; once
    /// the page rests the title becomes `changed` (other pixels where it is) or its right part is
    /// covered for `coverFrames` frames. Returns in how many of the 300 frames after that the
    /// translation of `changed` is drawn, and in how many from the fourth on the old one is.
    private func barTitleAtRest(initial: String, changed: String,
                                coverFrames: Int = 0) -> (drawn: Int, frames: Int, stale: Int) {
        let screen = SyntheticScreen(seed: 5)
        let title = CGRect(x: 150, y: 20, width: 100, height: 20)
        let tracker = OverlayTracker()
        var time = 0.0, seed: UInt64 = 1
        var pending: (request: RecognitionRequest, blocks: [RecognizedBlock], at: TimeInterval)?
        var titleText = initial, hasChanged = false, covering = 0
        func read(_ region: CGRect, shift: Int, offset: Int) -> [RecognizedBlock] {
            var blocks: [RecognizedBlock] = []
            let shown = title.offsetBy(dx: Double(shift), dy: 0)
            // (a region that holds at least half of the title reads all of its text, in the box
            // of what it holds of it)
            let part = shown.intersection(region)
            if !part.isNull, part.height >= shown.height, part.width * 2 >= shown.width {
                blocks.append(RecognizedBlock(text: titleText, rect: part))
            }
            for index in 0..<50 {
                var block = SyntheticScreen.block(index, offset: offset, text: "Zeile \(index)")
                block.rect = block.rect.offsetBy(dx: Double(shift), dy: 0)
                guard block.rect.minY >= Double(SyntheticScreen.topBar), block.rect.maxY <= Double(SyntheticScreen.bottomBar),
                      region.contains(block.rect) else { continue }
                blocks.append(block)
            }
            return blocks
        }
        func frame(shift: Int, offset: Int) -> [PlacedBlock] {
            time += 1.0 / 30
            seed += 1
            var image = screen.thumbnail(offset: offset)
            if shift > 0 {
                let moved = shift / SyntheticScreen.scale
                var pixels = [UInt8](repeating: 225, count: image.pixels.count)
                for y in 0..<image.height {
                    for x in moved..<image.width { pixels[y * image.width + x] = image.pixels[y * image.width + x - moved] }
                }
                image.pixels = pixels
            }
            if covering > 0 {
                // (the right part of the title, from thumbnail x 100 on, under a grey patch that
                // the recognizer reads through)
                covering -= 1
                for y in 5..<25 { for x in 100..<140 { image.pixels[y * image.width + x] = 120 } }
            } else if hasChanged && initial != changed {
                // (the changed letters at the title's end)
                for y in 10..<20 { for x in 115..<125 { image.pixels[y * image.width + x] = (x + y) % 2 == 0 ? 30 : 225 } }
            }
            let placed = tracker.advance(SyntheticPage.noisy(image, amount: 2, seed: seed), scale: SyntheticScreen.scale,
                                         time: time).placed
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.blocks, time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                pending = (request, read(request.region, shift: shift, offset: offset), time + 0.1)
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                tracker.setTranslation("T " + text, for: text)
            }
            return placed
        }
        for shift in stride(from: 200, through: 0, by: -20) { _ = frame(shift: shift, offset: 500) }
        for _ in 0..<45 { _ = frame(shift: 0, offset: 500) }
        for step in 1...10 { _ = frame(shift: 0, offset: 500 + 6 * step) }
        for _ in 0..<60 { _ = frame(shift: 0, offset: 560) }
        XCTAssertTrue(tracker.blocks.contains { $0.text == initial && $0.translation == "T " + initial })
        hasChanged = true
        covering = coverFrames
        titleText = changed
        var drawn = 0, stale = 0
        let frames = 300
        for index in 0..<frames {
            let placed = frame(shift: 0, offset: 560)
            if placed.contains(where: { $0.text == "T " + changed }) { drawn += 1 }
            if initial != changed, index >= 3, placed.contains(where: { $0.text == "T " + initial }) { stale += 1 }
        }
        return (drawn, frames, stale)
    }
}
