// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// What the tracker learns about the edges of a scrolling area while the content does not move
/// as one: Android (12 and later) stretches a page that is pulled past its end, the top of the
/// view farther than the bottom, and lets it spring back. Once the page rests, its last line
/// shows whole, so its translation must be drawn whole.
final class OverlayTrackerEdgeTests: XCTestCase {
    private static let width = 400, height = 800, scale = 2
    private static let topBar = 60, lineHeight = 24, linePitch = 60, firstLine = 100
    private static let lineLeft = 16, lineRight = 360

    /// A page of `lines` text lines on a light ground that goes on plain after the last one (the
    /// strokes cover about a third of a line, as letters do)
    private static func page(lines: Int, seed: UInt64, lastLineRight: Int = lineRight) -> (pixels: [UInt8], height: Int) {
        let pageHeight = firstLine + lines * linePitch + height
        var pixels = [UInt8](repeating: 240, count: width * pageHeight)
        var random = SyntheticPage.Random(state: seed)
        for line in 0..<lines {
            let top = firstLine + line * linePitch
            var x = lineLeft
            let right = line == lines - 1 ? lastLineRight : lineRight
            while x < right - 8 {
                let strokeWidth = 2 + random.below(4)
                let strokeTop = random.below(8), strokeBottom = lineHeight - random.below(8)
                for y in (top + strokeTop)..<(top + strokeBottom) {
                    for dx in 0..<strokeWidth where x + dx < right {
                        pixels[y * width + x + dx] = UInt8(20 + random.below(30))
                    }
                }
                x += strokeWidth + 4 + random.below(10)
            }
        }
        return (pixels, pageHeight)
    }

    /// The thumbnail of the page scrolled by `offset` below a title bar, stretched by `pull`
    /// frame pixels: content at the top of the view moves up by `pull`, content at the bottom
    /// edge of the frame by `bottomShare` of it, in between in proportion (a stretch, not a
    /// movement of the whole page)
    private static func frame(_ page: (pixels: [UInt8], height: Int), offset: Int, pull: Double,
                              bottomShare: Double = 0.4, bottomBar: Int? = nil, noiseSeed: UInt64) -> LumaImage {
        var frame = [UInt8](repeating: 225, count: width * height)
        let span = Double(height - topBar)
        for y in topBar..<(bottomBar ?? height) {
            // the row of the view at rest that shows at y: y = rest - pull × (1 - (1 - share) × t)
            // with t = (rest - topBar) / span, solved for rest
            let k = pull * (1 - bottomShare) / span
            let rest = (Double(y) + pull - k * Double(topBar)) / (1 + k)
            let source = Double(offset) + rest
            let low = Int(floor(source)), weight = source - Double(low)
            guard low >= 0, low + 1 < page.height else { continue }
            for x in 0..<width {
                let a = Double(page.pixels[low * width + x]), b = Double(page.pixels[(low + 1) * width + x])
                frame[y * width + x] = UInt8((a * (1 - weight) + b * weight).rounded())
            }
        }
        for x in 0..<width {
            frame[(topBar - 1) * width + x] = 190
        }
        if let bottomBar {
            // a navigation bar with a separator and a handle
            for x in 0..<width {
                frame[bottomBar * width + x] = 190
            }
            for y in (bottomBar + 18)..<(bottomBar + 24) {
                for x in 140..<260 { frame[y * width + x] = 60 }
            }
        }
        for y in 20..<40 {
            for x in 150..<250 where (x / 5) % 2 == 0 {
                frame[y * width + x] = 30
            }
        }
        let image = LumaImage(width: width, height: height, pixels: frame).downsampled(by: scale)
        return SyntheticPage.noisy(image, amount: 2, seed: noiseSeed)
    }

    private static func block(_ line: Int, offset: Int) -> RecognizedBlock {
        RecognizedBlock(text: "Line \(line)", rect: CGRect(x: lineLeft, y: firstLine + line * linePitch - offset,
                                                          width: lineRight - lineLeft, height: lineHeight))
    }

    /// The page scrolls to its end above a navigation bar (the edge of its scrolling area is found
    /// at the bar), then is pulled past its end and springs back, stretched as Android does it,
    /// three times. Its last line, a short label, moves less than the rest while it stretches,
    /// so the movement seems to end above it, in two frames in a row. At rest the label is
    /// translated and drawn, and nothing cuts it at its bottom: no edge is kept above the bar.
    /// (Before, the edge learned in those frames was kept at rest: the label was drawn cut
    /// through its letters, or never translated.)
    func testTheLastLineIsDrawnWholeAfterThePageSprangBackFromAStretch() throws {
        for (share, peak) in [(0.5, 42.0), (0.6, 42.0), (0.6, 30.0), (0.9, 60.0)] {
            let lines = 12, bar = 760
            let page = Self.page(lines: lines, seed: 41, lastLineRight: 140)
            // at rest the last line lies from y 600 to 624, plain page below it down to the bar
            let rest = Self.firstLine + (lines - 1) * Self.linePitch - 600
            let tracker = OverlayTracker()
            var time = 0.0
            var seed: UInt64 = 1
            var offset = rest - 240
            func show(_ pull: Double) -> FrameUpdate {
                seed += 1
                time += 1.0 / 60
                return tracker.advance(Self.frame(page, offset: offset, pull: pull, bottomShare: share, bottomBar: bar,
                                                  noiseSeed: seed), scale: Self.scale, time: time)
            }
            func readWhatIsDue() {
                guard let due = tracker.recognitionDue, due <= time, let request = tracker.beginRecognition(time: time)
                else { return }
                let blocks = (0..<lines).map { Self.block($0, offset: offset) }.filter {
                    request.region.contains($0.rect) && $0.rect.minY >= Double(Self.topBar) && $0.rect.maxY <= Double(bar)
                }
                tracker.finishRecognition(request, blocks: blocks, time: time)
                for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                    tracker.setTranslation("T " + text, for: text)
                }
            }
            for _ in 0..<60 {
                _ = show(0)
                readWhatIsDue()
            }
            // to the end of the page, 4 pixels a frame
            while offset < rest {
                offset += 4
                _ = show(0)
                readWhatIsDue()
            }
            for _ in 0..<60 {
                _ = show(0)
                readWhatIsDue()
            }
            XCTAssertTrue(tracker.scrollingAreas.contains { $0.knownEdges & FrameMotion.bottom != 0
                && abs($0.rect.maxY - Double(bar)) <= Double(Self.scale) }, "the edge at the bar is known")
            // pulled up quickly, held a moment, let go: it springs back fast at first, then slowly
            let pulls = [0.14, 0.33, 0.57, 0.8, 0.95, 1, 1, 0.95, 0.86, 0.71, 0.55, 0.4, 0.29, 0.19, 0.12, 0.07, 0.05,
                         0.03, 0.015, 0.007]
            for _ in 0..<3 {
                for pull in pulls {
                    _ = show(pull * peak)
                    readWhatIsDue()
                }
                for _ in 0..<60 {
                    _ = show(0)
                    readWhatIsDue()
                }
            }
            var update = show(0)
            for _ in 0..<120 {
                update = show(0)
                readWhatIsDue()
            }
            let label = "stretched to \(Int(share * 100)) % at the bottom, by \(Int(peak)) pixels"
            XCTAssertFalse(tracker.scrollingAreas.contains { $0.knownEdges & FrameMotion.bottom != 0
                && $0.rect.maxY < Double(bar - Self.scale) }, "no edge is kept above the bar (\(label)): \(tracker.scrollingAreas)")
            let truth = Self.block(lines - 1, offset: offset).rect
            let last = try XCTUnwrap(update.placed.first { $0.text == "T Line \(lines - 1)" },
                                     "the last line is drawn (\(label))")
            let drawn = last.visibleRect ?? last.rect
            XCTAssertGreaterThanOrEqual(drawn.maxY, truth.maxY - 1, "nothing cuts the last line at its bottom (\(label))")
            XCTAssertGreaterThanOrEqual(drawn.height, 0.75 * truth.height, "most of the last line is drawn (\(label))")
        }
    }

    /// The page scrolls below a title bar down to the bottom of the frame. Then a bar comes up at
    /// the bottom and the page scrolls on above it, which gives its scrolling area a bottom edge
    /// found to the pixel, above where its content was seen before. On the still page the bar
    /// goes away and a line shows across that edge (a banner that has gone; the handle of
    /// Android's navigation bar, learned as an edge while a screen slid in, under a row of the
    /// next screen). The line is read at rest, translated and drawn whole: what lies beyond the
    /// edge no longer shows what it did when the edge was found, the page's ground goes on there,
    /// so the area reaches as far as its content was seen again. Before, the line was taken for
    /// cut off at that edge and never translated.
    func testALineAcrossAnEdgeThatNoLongerHoldsIsTranslatedWhole() throws {
        let lines = 30
        let page = Self.page(lines: lines, seed: 43)
        let barTop = 684
        func frame(offset: Int, bar: Bool, noiseSeed: UInt64) -> LumaImage {
            var image = Self.frame(page, offset: offset, pull: 0, noiseSeed: noiseSeed)
            guard bar else { return image }
            // an opaque bar with a separator and two buttons (thumbnail pixels)
            for y in (barTop / Self.scale)..<(Self.height / Self.scale) {
                for x in 0..<image.width {
                    let button = y >= barTop / Self.scale + 12 && y < barTop / Self.scale + 30
                        && (x % 100 >= 20 && x % 100 < 60)
                    image[x, y] = y == barTop / Self.scale ? 150 : (button ? 90 : 205)
                }
            }
            return image
        }
        // at rest line 16 lies from y 666 to 690, across the bar's edge at 684 (its middle above it)
        let rest = Self.firstLine + 16 * Self.linePitch - 666
        let tracker = OverlayTracker()
        var time = 0.0
        var seed: UInt64 = 1
        var bar = false
        var offset = rest - 400
        var reads = 0
        func show() -> FrameUpdate {
            seed += 1
            time += 1.0 / 60
            return tracker.advance(frame(offset: offset, bar: bar, noiseSeed: seed), scale: Self.scale, time: time)
        }
        func readWhatIsDue() {
            guard let due = tracker.recognitionDue, due <= time, let request = tracker.beginRecognition(time: time) else {
                return
            }
            reads += 1
            let region = request.region
            let visible = (0..<lines).map { Self.block($0, offset: offset) }.filter { block in
                region.contains(block.rect) && block.rect.minY >= Double(Self.topBar)
                    && (bar ? block.rect.maxY <= Double(barTop) : block.rect.maxY <= Double(Self.height))
            }
            tracker.finishRecognition(request, blocks: visible, time: time)
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                tracker.setTranslation("T " + text, for: text)
            }
        }
        for _ in 0..<60 {
            _ = show()
            readWhatIsDue()
        }
        // scrolled, the content reaching the bottom of the frame
        while offset < rest - 240 {
            offset += 4
            _ = show()
            readWhatIsDue()
        }
        for _ in 0..<30 {
            _ = show()
            readWhatIsDue()
        }
        // the bar comes up, and the page is scrolled on to its place, 4 pixels a frame
        bar = true
        for _ in 0..<30 {
            _ = show()
            readWhatIsDue()
        }
        while offset < rest {
            offset += 4
            _ = show()
            readWhatIsDue()
        }
        for _ in 0..<60 {
            _ = show()
            readWhatIsDue()
        }
        let edges = tracker.scrollingAreas.filter { $0.knownEdges & FrameMotion.bottom != 0 }
        XCTAssertTrue(edges.contains { abs($0.rect.maxY - Double(barTop)) <= Double(Self.scale) },
                      "the bar's edge was found to the pixel: \(tracker.scrollingAreas)")
        // the bar goes away
        bar = false
        var update = show()
        for _ in 0..<180 {
            update = show()
            readWhatIsDue()
        }
        let across = try XCTUnwrap(update.placed.first { $0.text == "T Line 16" }, "the line across the old edge is drawn")
        XCTAssertNil(across.visibleRect, "drawn whole, not cut to \(String(describing: across.visibleRect))")
        let below = (17..<lines).filter { Self.block($0, offset: offset).rect.maxY <= Double(Self.height) }
        for line in below {
            XCTAssertTrue(update.placed.contains { $0.text == "T Line \(line)" && $0.visibleRect == nil }, "line \(line)")
        }
        // and the still page is not read on and on: nothing in a minute
        let readsAtRest = reads
        for _ in 0..<3600 {
            _ = show()
            readWhatIsDue()
        }
        XCTAssertEqual(reads, readsAtRest, "nothing is read on the still page")
    }
}
