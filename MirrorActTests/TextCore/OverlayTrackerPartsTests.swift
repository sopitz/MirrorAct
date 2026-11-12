// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Synthetic pictures for the building blocks of `OverlayTracker`: a page of "text" (dark strokes
/// on a light ground) drawn at full resolution, reduced by box averages like real thumbnails.
enum SyntheticPage {
    /// A deterministic sequence (no system randomness in tests either)
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    /// Full-resolution page: lines of "words" (strokes of random widths) with gaps. `period` > 0
    /// repeats the same line every `period` pixels (rows that look alike).
    static func page(width: Int, height: Int, seed: UInt64, lineHeight: Int = 24, lineGap: Int = 20,
                     period: Int = 0) -> [UInt8] {
        var pixels = [UInt8](repeating: 240, count: width * height)
        var random = Random(state: seed)
        var line: [UInt8] = []
        func drawLine(top: Int) {
            for y in top..<min(height, top + lineHeight) {
                for x in 0..<width where line[(y - top) * width + x] != 0 {
                    pixels[y * width + x] = line[(y - top) * width + x]
                }
            }
        }
        func makeLine() {
            line = [UInt8](repeating: 0, count: lineHeight * width)
            var x = 16 + random.below(20)
            while x < width - 40 {
                let word = 20 + random.below(60)
                var stroke = x
                while stroke < min(width - 16, x + word) {
                    let strokeWidth = 2 + random.below(4)
                    let top = random.below(lineHeight / 3), bottom = lineHeight - random.below(lineHeight / 3)
                    for y in top..<bottom {
                        for dx in 0..<strokeWidth where stroke + dx < width {
                            line[y * width + stroke + dx] = UInt8(20 + random.below(30))
                        }
                    }
                    stroke += strokeWidth + 2 + random.below(5)
                }
                x += word + 12 + random.below(20)
            }
        }
        makeLine()
        var top = 30
        while top + lineHeight < height {
            if period == 0 { makeLine() }
            drawLine(top: top)
            top += period > 0 ? period : lineHeight + lineGap + random.below(lineGap)
        }
        return pixels
    }

    /// The thumbnail of the part of `page` that starts at (left, top), `width` × `height` pixels
    /// of the page, reduced by `scale`
    static func thumbnail(_ page: [UInt8], pageWidth: Int, left: Int, top: Int, width: Int, height: Int,
                          scale: Int) -> LumaImage {
        var window = [UInt8](repeating: 240, count: width * height)
        let pageHeight = page.count / pageWidth
        for y in 0..<height where top + y >= 0 && top + y < pageHeight {
            for x in 0..<width where left + x >= 0 && left + x < pageWidth {
                window[y * width + x] = page[(top + y) * pageWidth + left + x]
            }
        }
        return LumaImage(width: width, height: height, pixels: window).downsampled(by: scale)
    }

    /// Adds noise of ±`amount` to every pixel (deterministic)
    static func noisy(_ image: LumaImage, amount: Int, seed: UInt64) -> LumaImage {
        var copy = image
        var random = Random(state: seed)
        for index in copy.pixels.indices {
            let value = Int(copy.pixels[index]) + random.below(2 * amount + 1) - amount
            copy.pixels[index] = UInt8(min(255, max(0, value)))
        }
        return copy
    }
}

final class PatchMatcherTests: XCTestCase {
    private let configuration = OverlayTracker.Configuration()

    /// A block is found again to a fraction of a thumbnail pixel at every phase of the reduction
    func testPatchIsLocatedBetweenPixels() throws {
        let scale = 4, width = 400, height = 400
        let page = SyntheticPage.page(width: width, height: height + 64, seed: 7)
        let reference = SyntheticPage.thumbnail(page, pageWidth: width, left: 0, top: 0, width: width, height: height,
                                                scale: scale)
        let patchRect = ThumbnailRect(x: 3, y: 6, width: 80, height: 10)
        let patch = try XCTUnwrap(BlockPatch(image: reference, rect: patchRect))
        let matcher = PatchMatcher(configuration: configuration)
        var worst = 0.0
        for shift in 0..<(3 * scale) {
            // the page moved up by `shift` full pixels
            let moved = SyntheticPage.noisy(SyntheticPage.thumbnail(page, pageWidth: width, left: 0, top: shift,
                                                                    width: width, height: height, scale: scale),
                                            amount: 2, seed: UInt64(shift))
            let truth = Double(patchRect.y) - Double(shift) / Double(scale)
            // start from the nearest whole pixel, as a frame-to-frame estimate might
            let start = truth.rounded()
            let found = try XCTUnwrap(matcher.locate(patch, in: moved, x: Double(patchRect.x), y: start,
                                                     part: ThumbnailRect(x: 0, y: 0, width: patch.width, height: patch.height),
                                                     radius: 2))
            worst = max(worst, abs(found.y - truth), abs(found.x - Double(patchRect.x)))
            let inner = ThumbnailRect(x: 1, y: 1, width: patch.width - 2, height: patch.height - 2)
            XCTAssertEqual(matcher.visiblePart(patch, in: moved, x: found.x, y: found.y, inner: inner), inner,
                           "all of it shows at shift \(shift)")
        }
        print(String(format: "[parts] worst error locating a patch: %.3f thumbnail pixels", worst))
        XCTAssertLessThan(worst, 0.2)
    }
}

extension PatchMatcherTests {
    /// A line that differs in a few letters is not taken for the line that was read; the same
    /// line between pixels is
    func testOtherLettersAreNotTheSameLine() throws {
        let scale = 2, width = 400, height = 200
        // two pages whose lines are equal but for their right part
        var first = SyntheticPage.page(width: width, height: height, seed: 11, period: 60)
        var second = first
        let other = SyntheticPage.page(width: width, height: height, seed: 12, period: 60)
        for y in 0..<height {
            for x in 260..<width {
                second[y * width + x] = other[y * width + x]
            }
        }
        first = Array(first)
        let reference = SyntheticPage.thumbnail(first, pageWidth: width, left: 0, top: 0, width: width, height: height,
                                                scale: scale)
        let patchRect = ThumbnailRect(x: 7, y: 14, width: 180, height: 14)
        let patch = try XCTUnwrap(BlockPatch(image: reference, rect: patchRect))
        let inner = ThumbnailRect(x: 1, y: 1, width: patch.width - 2, height: patch.height - 2)
        let matcher = PatchMatcher(configuration: configuration)
        // the same line, half a pixel lower
        let same = SyntheticPage.noisy(SyntheticPage.thumbnail(first, pageWidth: width, left: 0, top: -1, width: width,
                                                               height: height, scale: scale), amount: 2, seed: 5)
        XCTAssertEqual(matcher.visiblePart(patch, in: same, x: 7, y: 14.5, inner: inner), inner)
        // the same place on the page with other words at the end
        let alike = SyntheticPage.noisy(SyntheticPage.thumbnail(second, pageWidth: width, left: 0, top: 0, width: width,
                                                                height: height, scale: scale), amount: 2, seed: 6)
        let seen = matcher.visiblePart(patch, in: alike, x: 7, y: 14, inner: inner)
        XCTAssertNotEqual(seen, inner, "the other words must not pass for the line that was read")
    }
}

/// A phone screen 400 × 800 (thumbnails 200 × 400 at scale 2): a bar above and below, between
/// them a page of text lines at known places that scrolls
struct SyntheticScreen {
    static let width = 400, height = 800, scale = 2
    static let topBar = 60, bottomBar = 740
    static let lineHeight = 24, linePitch = 60, firstLine = 100, lineLeft = 16, lineRight = 360

    let page: [UInt8]
    let pageHeight = 3000

    init(seed: UInt64) {
        var pixels = [UInt8](repeating: 240, count: SyntheticScreen.width * pageHeight)
        var random = SyntheticPage.Random(state: seed)
        var top = SyntheticScreen.firstLine
        while top + SyntheticScreen.lineHeight < pageHeight {
            var x = SyntheticScreen.lineLeft
            while x < SyntheticScreen.lineRight - 8 {
                let strokeWidth = 2 + random.below(4)
                let strokeTop = random.below(8), strokeBottom = SyntheticScreen.lineHeight - random.below(8)
                for y in (top + strokeTop)..<(top + strokeBottom) {
                    for dx in 0..<strokeWidth where x + dx < SyntheticScreen.lineRight {
                        pixels[y * SyntheticScreen.width + x + dx] = UInt8(20 + random.below(30))
                    }
                }
                x += strokeWidth + 2 + random.below(6)
            }
            top += SyntheticScreen.linePitch
        }
        page = pixels
    }

    /// The thumbnail with the page scrolled by `offset` full pixels (content moves up)
    func thumbnail(offset: Int, noiseSeed: UInt64? = nil) -> LumaImage {
        let width = SyntheticScreen.width, height = SyntheticScreen.height
        var frame = [UInt8](repeating: 225, count: width * height)
        for y in SyntheticScreen.topBar..<SyntheticScreen.bottomBar {
            let source = y + offset
            guard source >= 0, source < pageHeight else { continue }
            for x in 0..<width {
                frame[y * width + x] = page[source * width + x]
            }
        }
        // the separators of the bars and a title
        for x in 0..<width {
            frame[(SyntheticScreen.topBar - 1) * width + x] = 190
            frame[SyntheticScreen.bottomBar * width + x] = 190
        }
        for y in 20..<40 {
            for x in 150..<250 where (x / 5) % 2 == 0 {
                frame[y * width + x] = 30
            }
        }
        let image = LumaImage(width: width, height: height, pixels: frame).downsampled(by: SyntheticScreen.scale)
        guard let seed = noiseSeed else { return image }
        return SyntheticPage.noisy(image, amount: 2, seed: seed)
    }

    /// The recognized block of line `index` when the page is scrolled by `offset` (frame pixels)
    static func block(_ index: Int, offset: Int, text: String) -> RecognizedBlock {
        RecognizedBlock(text: text, rect: CGRect(x: lineLeft, y: firstLine + index * linePitch - offset,
                                                 width: lineRight - lineLeft, height: lineHeight))
    }
}

final class MotionEstimatorTests: XCTestCase {
    private let configuration = OverlayTracker.Configuration()

    /// A page between bars that moves by whole and half thumbnail pixels: one movement, measured
    /// to a fraction of a pixel, and the moving area ends where the bar begins
    func testScrollBetweenBarsIsMeasuredBetweenPixels() {
        let screen = SyntheticScreen(seed: 3)
        let estimator = MotionEstimator(configuration: configuration)
        for step in [3, 4, 7, 40] {
            let before = screen.thumbnail(offset: 500, noiseSeed: 1)
            let after = screen.thumbnail(offset: 500 + step, noiseSeed: 2)
            XCTAssertTrue(estimator.analyze(previous: before, current: after, priors: []))
            XCTAssertEqual(estimator.motions.count, 1, "step \(step)")
            guard let motion = estimator.motions.first else { continue }
            XCTAssertEqual(motion.dy, -Double(step) / 2, accuracy: 0.2, "step \(step)")
            XCTAssertEqual(motion.dx, 0, accuracy: 0.1)
            if motion.refinedEdges & FrameMotion.top != 0 {
                XCTAssertEqual(motion.area.y, SyntheticScreen.topBar / 2, "the area begins below the bar")
            }
            XCTAssertGreaterThanOrEqual(motion.area.y, SyntheticScreen.topBar / 2 - 1, "nothing of the bar moves")
            XCTAssertLessThanOrEqual(motion.area.maxY, SyntheticScreen.bottomBar / 2 + 1)
        }
    }

    /// A page whose lines repeat at about the same distance starts to move: the small step is
    /// found, not a step of a line more
    func testFirstStepOnAPageOfSimilarLines() {
        let screen = SyntheticScreen(seed: 4)
        let estimator = MotionEstimator(configuration: configuration)
        let before = screen.thumbnail(offset: 600, noiseSeed: 7)
        let after = screen.thumbnail(offset: 612, noiseSeed: 1)
        XCTAssertTrue(estimator.analyze(previous: before, current: after, priors: []))
        XCTAssertEqual(estimator.motions.first?.dy ?? 0, -6, accuracy: 0.2)
    }

    /// Noise of the link alone is not a change, and a picture moved sideways is found sideways
    func testNoiseIsNoChangeAndSidewaysMovementIsFound() {
        let estimator = MotionEstimator(configuration: configuration)
        let page = SyntheticPage.page(width: 400, height: 800, seed: 9)
        let still = SyntheticPage.thumbnail(page, pageWidth: 400, left: 0, top: 0, width: 400, height: 800, scale: 2)
        XCTAssertFalse(estimator.analyze(previous: SyntheticPage.noisy(still, amount: 2, seed: 1),
                                         current: SyntheticPage.noisy(still, amount: 2, seed: 2), priors: []))
        let moved = SyntheticPage.thumbnail(page, pageWidth: 400, left: 12, top: 0, width: 400, height: 800, scale: 2)
        XCTAssertTrue(estimator.analyze(previous: still, current: moved, priors: []))
        XCTAssertEqual(estimator.motions.first?.dx ?? 0, -6, accuracy: 0.2)
        XCTAssertEqual(estimator.motions.first?.dy ?? 1, 0, accuracy: 0.1)
    }

    /// Rows that look alike repeat every row: moved by half a row, up and down explain the
    /// picture almost equally. The movement of the frame before decides, and the true one is
    /// found where the rows differ.
    func testRowsThatLookAlikeKeepTheirDirection() {
        let width = 400, height = 800, period = 80
        var first = SyntheticPage.page(width: width, height: height + 400, seed: 21, period: period)
        let other = SyntheticPage.page(width: width, height: height + 400, seed: 22, lineHeight: 24, lineGap: 56)
        // every row the same but for its right end
        for y in 0..<(height + 400) {
            for x in 280..<width {
                first[y * width + x] = other[y * width + x]
            }
        }
        let estimator = MotionEstimator(configuration: configuration)
        let before = SyntheticPage.thumbnail(first, pageWidth: width, left: 0, top: 100, width: width, height: height,
                                             scale: 2)
        let after = SyntheticPage.thumbnail(first, pageWidth: width, left: 0, top: 100 - period / 2, width: width,
                                            height: height, scale: 2)
        XCTAssertTrue(estimator.analyze(previous: before, current: after, priors: []))
        XCTAssertEqual(estimator.motions.first?.dy ?? 0, Double(period) / 4, accuracy: 0.3,
                       "down by half a row, not up by half a row")
    }
}

final class ReadingPlanTests: XCTestCase {
    private let configuration = OverlayTracker.Configuration()
    private let bounds = CGRect(x: 0, y: 0, width: 200, height: 400)

    /// What scrolled in is read at once, with a margin into what was read before, not the frame
    func testStripIsReadAtOnceWithAMargin() throws {
        let plan = ReadingPlan(configuration: configuration)
        plan.add(UnreadArea(rect: CGRect(x: 0, y: 340, width: 200, height: 30), kind: .strip, since: 5))
        XCTAssertEqual(plan.due(lastMotion: 5, isFullyVisible: { _ in true }), 5)
        let region = try XCTUnwrap(plan.takeRegion(at: 5, lastMotion: 5, bounds: bounds, isFullyVisible: { _ in true }))
        XCTAssertLessThan(region.height, 0.3 * bounds.height, "only the strip")
        XCTAssertLessThanOrEqual(region.minY, 340 - configuration.readMargin)
        XCTAssertTrue(plan.areas.isEmpty)
        plan.finishPass(succeeded: false)
        XCTAssertEqual(plan.areas.count, 1, "a pass that failed leaves it to be read")
    }

    /// A part that keeps changing (a video) does not keep the rest of a new screen from being read
    func testAChangeIsCutOutOfAnOlderOne() {
        let plan = ReadingPlan(configuration: configuration)
        plan.add(UnreadArea(rect: bounds, kind: .changed, since: 0))
        for tick in 1...30 {
            plan.add(UnreadArea(rect: CGRect(x: 0, y: 100, width: 200, height: 80), kind: .changed,
                                since: Double(tick) / 30))
        }
        XCTAssertEqual(plan.due(lastMotion: -1000, isFullyVisible: { _ in true }) ?? 99, configuration.settleTime,
                       accuracy: 1e-9)
    }

    /// A place to read again as a whole is not cut into slivers by a pass that reads a part of it
    func testRereadIsTakenWholeOrLeftWhole() throws {
        let plan = ReadingPlan(configuration: configuration)
        plan.add(UnreadArea(rect: CGRect(x: 0, y: 0, width: 200, height: 30), kind: .strip, since: 1))
        plan.add(UnreadArea(rect: CGRect(x: 0, y: 40, width: 200, height: 100), kind: .reread, since: 1))
        // (the place cannot be seen completely yet: only the strip is due, and its margin reaches into the place)
        _ = try XCTUnwrap(plan.takeRegion(at: 1, lastMotion: 1, bounds: bounds, isFullyVisible: { $0.maxY < 100 }))
        XCTAssertEqual(plan.areas.filter { $0.kind == .reread }.map(\.rect), [CGRect(x: 0, y: 40, width: 200, height: 100)])
    }
}

final class OverlayTrackerFollowingTests: XCTestCase {
    private let scale = SyntheticScreen.scale

    /// Reads the screen at rest and gives every block a translation
    private func readAtRest(_ tracker: OverlayTracker, _ screen: SyntheticScreen, offset: Int, lines: [Int],
                            time: TimeInterval) throws {
        let frame = screen.thumbnail(offset: offset, noiseSeed: 7)
        _ = tracker.advance(frame, scale: scale, time: time)
        let request = try XCTUnwrap(tracker.beginRecognition(time: time + 1))
        tracker.finishRecognition(request, blocks: lines.map { SyntheticScreen.block($0, offset: offset, text: "Line \($0)") },
                                  time: time + 1.2)
        for text in tracker.textsAwaitingTranslation(limit: 50, time: time + 1.2) {
            tracker.setTranslation("T " + text, for: text)
        }
    }

    /// Translations move with their text frame by frame, to a fraction of a thumbnail pixel,
    /// are cut where the text slides under the bar and are gone once it is under it
    func testTranslationsFollowTheTextAndSlideUnderTheBar() throws {
        let screen = SyntheticScreen(seed: 5)
        let tracker = OverlayTracker()
        let start = 300
        try readAtRest(tracker, screen, offset: start, lines: [5, 6, 7], time: 0)
        var worst = 0.0
        var sawCut = false
        for frame in 1...40 {
            let offset = start + 5 * frame
            let update = tracker.advance(screen.thumbnail(offset: offset, noiseSeed: UInt64(frame)), scale: scale,
                                         time: 2 + Double(frame) / 60)
            XCTAssertEqual(update.change, .scrolled)
            for placed in update.placed {
                let line = Int(placed.text.dropFirst("T Line ".count)) ?? -1
                let truth = SyntheticScreen.block(line, offset: offset, text: "").rect
                worst = max(worst, abs(placed.rect.midY - truth.midY) / Double(scale))
                let drawn = placed.visibleRect ?? placed.rect
                XCTAssertGreaterThanOrEqual(drawn.minY, Double(SyntheticScreen.topBar) - Double(scale),
                                            "nothing is drawn over the bar (frame \(frame), line \(line))")
                if placed.visibleRect != nil { sawCut = true }
            }
            // line 5 is under the bar once its bottom passed the bar's edge
            let lineFive = SyntheticScreen.block(5, offset: offset, text: "").rect
            if lineFive.maxY < Double(SyntheticScreen.topBar) {
                XCTAssertFalse(update.placed.contains { $0.text == "T Line 5" }, "frame \(frame)")
            }
        }
        print(String(format: "[parts] worst error of a translation while scrolling: %.3f thumbnail pixels", worst))
        XCTAssertLessThan(worst, 0.6)
        XCTAssertTrue(sawCut, "a translation is cut while its text slides under the bar")
    }

    /// A pass reads the frame it started on; its blocks are carried over to the frame that is
    /// shown when it ends, and checked against it
    func testResultsOfAPassAreCarriedToTheCurrentFrame() throws {
        let screen = SyntheticScreen(seed: 8)
        let tracker = OverlayTracker()
        let start = 200
        _ = tracker.advance(screen.thumbnail(offset: start, noiseSeed: 1), scale: scale, time: 0)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 1))
        var offset = start
        for frame in 1...12 {
            offset = start + 6 * frame
            _ = tracker.advance(screen.thumbnail(offset: offset, noiseSeed: UInt64(frame + 1)), scale: scale,
                                time: 1 + Double(frame) / 60)
        }
        // the blocks in the pixels of the frame the pass started on
        tracker.finishRecognition(request, blocks: [SyntheticScreen.block(4, offset: start, text: "Four"),
                                                    SyntheticScreen.block(6, offset: start, text: "Six")], time: 1.25)
        let rects = Dictionary(uniqueKeysWithValues: tracker.blocks.map { ($0.text, $0.rect) })
        XCTAssertEqual(rects["Four"]?.minY ?? 0, SyntheticScreen.block(4, offset: offset, text: "").rect.minY,
                       accuracy: 1.0)
        XCTAssertEqual(rects["Six"]?.minY ?? 0, SyntheticScreen.block(6, offset: offset, text: "").rect.minY,
                       accuracy: 1.0)
    }

    /// A paragraph read again keeps its block and translation when the reading differs by a
    /// letter or the rectangle by a pixel; text that grew shows the old translation as stale
    /// until its own is there; other text replaces it
    func testReadingsOfTheSamePlaceAreMerged() throws {
        let screen = SyntheticScreen(seed: 11)
        let tracker = OverlayTracker()
        try readAtRest(tracker, screen, offset: 0, lines: [2], time: 0)
        let first = try XCTUnwrap(tracker.blocks.first)
        XCTAssertEqual(first.translation, "T Line 2")
        var time = 3.0
        var mark = 0
        /// Something changes right below the line: its place is read again, with this result
        func readAgain(_ block: RecognizedBlock) throws {
            mark += 1
            var frame = screen.thumbnail(offset: 0, noiseSeed: 7)
            let below = (SyntheticScreen.firstLine + 2 * SyntheticScreen.linePitch + SyntheticScreen.lineHeight) / 2 + 4
            // (a line across the screen, a different one each time)
            for y in below..<(below + 2) {
                for x in stride(from: 8 + mark % 3, to: 190, by: 3) {
                    frame[x, y] = 0
                }
            }
            _ = tracker.advance(frame, scale: scale, time: time)
            time += 1
            let request = try XCTUnwrap(tracker.beginRecognition(time: time), "the change is read")
            XCTAssertFalse(request.isFullFrame)
            tracker.finishRecognition(request, blocks: [block], time: time + 0.1)
            time += 1
        }
        var again = SyntheticScreen.block(2, offset: 0, text: "Line 2")
        again.rect = again.rect.offsetBy(dx: 1, dy: -1)
        try readAgain(again)
        XCTAssertEqual(tracker.blocks.map(\.id), [first.id])
        XCTAssertEqual(tracker.blocks.first?.translation, "T Line 2")
        XCTAssertEqual(tracker.blocks.first?.rect, first.rect, "a pixel off is the same rectangle (the drawn text stays)")

        var misread = SyntheticScreen.block(2, offset: 0, text: "Linc 2")
        misread.rect = again.rect
        try readAgain(misread)
        XCTAssertEqual(tracker.blocks.first?.translation, "T Line 2", "a letter read differently keeps the translation")

        var grown = SyntheticScreen.block(2, offset: 0, text: "Line 2 and what follows")
        grown.rect.size.height += 2
        grown.lineCount = 2
        try readAgain(grown)
        XCTAssertEqual(tracker.blocks.first?.text, "Line 2 and what follows")
        XCTAssertEqual(tracker.blocks.first?.translation, "T Line 2", "shown until its own translation is there")
        XCTAssertEqual(tracker.blocks.first?.isStale, true)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 5, time: time), ["Line 2 and what follows"])

        try readAgain(SyntheticScreen.block(2, offset: 0, text: "Something else entirely"))
        XCTAssertNil(tracker.blocks.first?.translation, "other text does not show the old translation")
        XCTAssertNotEqual(tracker.blocks.first?.id, first.id)
    }

    /// A still screen of a wireless source sends one frame: the reading is due by time alone,
    /// and once read nothing is read again
    func testStillScreenIsReadOnceWithoutFurtherFrames() throws {
        let screen = SyntheticScreen(seed: 2)
        let tracker = OverlayTracker()
        let update = tracker.advance(screen.thumbnail(offset: 100), scale: scale, time: 10)
        let due = try XCTUnwrap(update.recognitionDue)
        XCTAssertLessThanOrEqual(due, 10.2)
        let request = try XCTUnwrap(tracker.beginRecognition(time: due))
        XCTAssertTrue(request.isFullFrame)
        tracker.finishRecognition(request, blocks: [SyntheticScreen.block(3, offset: 100, text: "Three")], time: due + 0.25)
        XCTAssertNil(tracker.recognitionDue, "a still picture that was read is not read again")
        XCTAssertEqual(tracker.advance(screen.thumbnail(offset: 100), scale: scale, time: due + 0.3).change, .unchanged)
    }

    /// While the page scrolls, what came into view is read at once as a strip, not the frame
    func testOnlyTheStripThatCameIntoViewIsRead() throws {
        let screen = SyntheticScreen(seed: 4)
        let tracker = OverlayTracker()
        try readAtRest(tracker, screen, offset: 600, lines: [9, 10, 11, 12, 13, 14, 15, 16, 17, 18], time: 0)
        XCTAssertNil(tracker.recognitionDue)
        var request: RecognitionRequest?
        for frame in 1...6 where request == nil {
            let time = 2 + Double(frame) / 60
            let update = tracker.advance(screen.thumbnail(offset: 600 + 12 * frame, noiseSeed: UInt64(frame)),
                                         scale: scale, time: time)
            if let due = update.recognitionDue, due <= time { request = tracker.beginRecognition(time: time) }
        }
        let strip = try XCTUnwrap(request, "the strip that came in is read while the page moves")
        XCTAssertFalse(strip.isFullFrame)
        XCTAssertLessThan(strip.region.height, 0.3 * Double(SyntheticScreen.height))
        XCTAssertGreaterThan(strip.region.maxY, Double(SyntheticScreen.bottomBar) - 40, "at the edge where content enters")
    }
}
