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

    /// A list whose rows look alike (the same icon and separator, text that differs at its end),
    /// at a pitch of an even number of thumbnail pixels, creeps by one frame pixel (half a
    /// thumbnail pixel) a frame, as at the end of a flick. The edges of all rows lie on rows of the
    /// same parity, and a fit that looks at every other row only measured some steps a few tenths
    /// of a pixel off; there the step failed its own check, and a movement of a few rows, which
    /// explains such a picture almost as well, was taken instead. Measured on every row, the
    /// step holds up: the list creeps, it does not jump.
    func testACreepOverRowsThatLookAlikeDoesNotJumpByRows() {
        let width = 400, height = 800
        for period in [92, 100] {
            var page = SyntheticPage.page(width: width, height: 1400, seed: 41, period: period)
            let other = SyntheticPage.page(width: width, height: 1400, seed: 42, lineHeight: 24, lineGap: 68)
            // every row the same but for its right end, with a separator and an icon
            for y in 0..<1400 {
                for x in 300..<width {
                    page[y * width + x] = other[y * width + x]
                }
            }
            for top in stride(from: 20, to: 1400, by: period) {
                for y in top..<min(1400, top + 2) {
                    for x in 0..<width {
                        page[y * width + x] = 150
                    }
                }
                for y in (top + 22)..<min(1400, top + 62) {
                    for x in 16..<56 {
                        page[y * width + x] = 90
                    }
                }
            }
            func frame(_ top: Int) -> LumaImage {
                SyntheticPage.noisy(SyntheticPage.thumbnail(page, pageWidth: width, left: 0, top: top, width: width,
                                                            height: height, scale: 2), amount: 2, seed: UInt64(top))
            }
            let estimator = MotionEstimator(configuration: configuration)
            var priors: [FrameMotion] = []
            var previous = frame(200)
            for top in 201...232 {
                let current = frame(top)
                if estimator.analyze(previous: previous, current: current, priors: priors) {
                    priors = estimator.motions
                }
                for motion in estimator.motions {
                    XCTAssertLessThan(abs(motion.dy), 2, "period \(period), offset \(top): a creep, not a jump of rows")
                }
                previous = current
            }
        }
    }

    /// A list whose rows look alike glides by about a row a frame and stops. In the first frame of
    /// rest the link repairs the picture it blurred while it moved: standing still explains every
    /// tile but a fit of it on every other row came out a tenth of a pixel off (the edges of all
    /// rows lie on rows of the same parity), so it was not taken as rest; the movement of the frame
    /// before explains the picture almost as well, a row away, and kept winning. Measured on every
    /// row, standing still is no movement at all, and nothing moves.
    func testRowsThatLookAlikeComeToRestWhileTheLinkRepairsThePicture() {
        let width = 400, height = 800, period = 92
        var page = SyntheticPage.page(width: width, height: 3000, seed: 51, period: period)
        let other = SyntheticPage.page(width: width, height: 3000, seed: 52, lineHeight: 24, lineGap: 56)
        // every row the same but for its right end
        for y in 0..<3000 {
            for x in 280..<width {
                page[y * width + x] = other[y * width + x]
            }
        }
        func frame(_ top: Int, noise: UInt64) -> LumaImage {
            SyntheticPage.noisy(SyntheticPage.thumbnail(page, pageWidth: width, left: 0, top: top, width: width,
                                                        height: height, scale: 2), amount: 2, seed: noise)
        }
        for speed in [period - 4, period - 2, period + 2] {
            let estimator = MotionEstimator(configuration: configuration)
            let tops = [300, 300 + speed, 300 + 2 * speed, 300 + 3 * speed]
            var previous = frame(tops[0], noise: 1)
            var priors: [FrameMotion] = []
            for (index, top) in tops.dropFirst().enumerated() {
                // (blurred where it moves fast)
                let current = MotionEstimatorTests.softened(frame(top, noise: UInt64(index + 2)), share: 60,
                                                            seed: UInt64(index + 10))
                XCTAssertTrue(estimator.analyze(previous: previous, current: current, priors: priors))
                XCTAssertEqual(estimator.motions.first?.dy ?? 0, -Double(speed) / 2, accuracy: 0.5, "speed \(speed)")
                priors = estimator.motions
                previous = current
            }
            // at rest: the same place, repaired
            _ = estimator.analyze(previous: previous, current: frame(tops[3], noise: 9), priors: priors)
            XCTAssertTrue(estimator.motions.allSatisfy { abs($0.dx) < 1 && abs($0.dy) < 1 },
                          "speed \(speed): at rest, not a row on: \(estimator.motions.map(\.dy))")
        }
    }

    /// `share` percent of the blocks of 8 × 8 pixels blurred, the way a video link loses detail in
    /// a fast movement (deterministic)
    private static func softened(_ image: LumaImage, share: Int, seed: UInt64) -> LumaImage {
        var copy = image
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func at(_ x: Int, _ y: Int) -> Int {
            Int(image[min(image.width - 1, max(0, x)), min(image.height - 1, max(0, y))])
        }
        for top in stride(from: 0, to: image.height, by: 8) {
            for left in stride(from: 0, to: image.width, by: 8) {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                guard Int(state % 100) < share else { continue }
                for y in top..<min(image.height, top + 8) {
                    for x in left..<min(image.width, left + 8) {
                        let near = (at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1)) / 4
                        let far = (at(x - 2, y) + at(x + 2, y) + at(x, y - 2) + at(x, y + 2)) / 4
                        copy[x, y] = UInt8((4 * at(x, y) + 3 * (2 * near + at(x, y) + far)) / 16)
                    }
                }
            }
        }
        return copy
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

    /// A confirm read in flight (after movement) makes the pass count as a first reading, even when
    /// it lies over a reread: what it finds cut off is read again at rest, not taken as it shows
    /// (a page that springs back after a flick would otherwise show half-read paragraphs)
    func testAConfirmInFlightMakesThePassAFirstReading() throws {
        let plan = ReadingPlan(configuration: configuration)
        let place = CGRect(x: 0, y: 200, width: 200, height: 40)
        plan.add(UnreadArea(rect: place, kind: .reread, since: 5, attempts: 1))
        plan.add(UnreadArea(rect: bounds, kind: .confirm, since: 5))
        _ = try XCTUnwrap(plan.takeRegion(at: 5, lastMotion: -1000, bounds: bounds, isFullyVisible: { _ in true }))
        XCTAssertEqual(plan.inFlight.map(\.kind), [.reread, .confirm])
        XCTAssertNil(plan.rereadAttemptsInFlight)
        // a place read at rest rides along
        plan.finishPass(succeeded: true)
        plan.add(UnreadArea(rect: place, kind: .reread, since: 6, attempts: 1))
        plan.add(UnreadArea(rect: CGRect(x: 0, y: 236, width: 200, height: 20), kind: .rest, since: 6))
        _ = try XCTUnwrap(plan.takeRegion(at: 6.2, lastMotion: 5.8, bounds: bounds, isFullyVisible: { _ in true }))
        XCTAssertEqual(Set(plan.inFlight.map(\.kind)), [.reread, .rest])
        XCTAssertEqual(plan.rereadAttemptsInFlight, 1)
    }

    /// A place outside of every scrolling area waits for the motion near it, which the clock
    /// tells for its place: the plan hands it the area id and the place
    func testAPlaceOutsideOfEveryAreaAsksTheClockForItsPlace() {
        let plan = ReadingPlan(configuration: configuration)
        let place = CGRect(x: 0, y: 300, width: 200, height: 30)
        plan.add(UnreadArea(rect: place, kind: .confirm, since: 5))
        var asked: [(Int, CGRect)] = []
        let due = plan.due(lastMotion: 9, isFullyVisible: { _ in true }, areaMotion: { id, rect, _ in
            asked.append((id, rect))
            return 4
        })
        XCTAssertEqual(due ?? 0, 5, accuracy: 1e-9, "the motion near it ended before it was asked for")
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, -1)
        XCTAssertEqual(asked.first?.1, place)
        XCTAssertEqual(plan.due(lastMotion: 9, isFullyVisible: { _ in true }) ?? 0, 9 + configuration.confirmDelay,
                       accuracy: 1e-9, "without a clock: the picture as a whole")
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

    /// A label on a bar that stays, right beside the edge of a page that scrolls, stays where it
    /// is while a pass reads it: the tiles across the edge move in part and carry the points of
    /// the pass that lie in them on the bar's side, and a reading that lay in no scrolling area
    /// does not take its movement from such a point (a tab label read while the page moved was
    /// placed a few lines up in the page, carried along with it, or lost)
    func testALabelOnABarBesideThePageStaysWhileThePageMoves() throws {
        let screen = SyntheticScreen(seed: 8)
        let width = SyntheticScreen.width, height = SyntheticScreen.height
        // the page begins in the middle of a tile row of the thumbnails (tiles of 8 thumbnail
        // pixels, a pass of the whole frame has its points in the first row of every other one)
        let barEdge = 58
        let label = CGRect(x: 160, y: 36, width: 80, height: 16)
        func thumbnail(offset: Int, noiseSeed: UInt64) -> LumaImage {
            var frame = [UInt8](repeating: 225, count: width * height)
            for y in barEdge..<SyntheticScreen.bottomBar where y + offset >= 0 && y + offset < screen.pageHeight {
                for x in 0..<width {
                    frame[y * width + x] = screen.page[(y + offset) * width + x]
                }
            }
            for x in 0..<width {
                frame[(barEdge - 1) * width + x] = 190
                frame[SyntheticScreen.bottomBar * width + x] = 190
            }
            for y in Int(label.minY)..<Int(label.maxY) {
                for x in Int(label.minX)..<Int(label.maxX) where (x / 4) % 3 != 0 {
                    frame[y * width + x] = 30
                }
            }
            let image = LumaImage(width: width, height: height, pixels: frame).downsampled(by: scale)
            return SyntheticPage.noisy(image, amount: 2, seed: noiseSeed)
        }
        let tracker = OverlayTracker()
        let start = 200
        _ = tracker.advance(thumbnail(offset: start, noiseSeed: 1), scale: scale, time: 0)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 1))
        XCTAssertTrue(request.isFullFrame)
        // the page moves down: what comes into view at its top edge passes the label's tiles
        var offset = start
        for frame in 1...12 {
            offset = start - 6 * frame
            _ = tracker.advance(thumbnail(offset: offset, noiseSeed: UInt64(frame + 1)), scale: scale,
                                time: 1 + Double(frame) / 60)
        }
        tracker.finishRecognition(request, blocks: [RecognizedBlock(text: "Label", rect: label),
                                                    SyntheticScreen.block(4, offset: start, text: "Four")],
                                  time: 1.25)
        let rects = Dictionary(uniqueKeysWithValues: tracker.blocks.map { ($0.text, $0.rect) })
        let placed = try XCTUnwrap(rects["Label"], "the label is kept")
        XCTAssertEqual(placed.minY, label.minY, accuracy: 1.0, "the label stays on the bar")
        XCTAssertEqual(placed.minX, label.minX, accuracy: 1.0)
        XCTAssertEqual(rects["Four"]?.minY ?? 0, SyntheticScreen.block(4, offset: offset, text: "").rect.minY,
                       accuracy: 1.0, "the line moved with the page")
    }

    /// A pass read during a fast glide over rows that look alike: by the time it ends, its row has
    /// slid under the bar, and a tile under it missed a frame of the movement (damaged), so its
    /// tiles say it went a frame's movement less – about a row. The row that looks alike there is
    /// no place for it: the picture under it moves with the page, so nothing stays there the way a
    /// header that sticks does. It is not taken there (it may be kept under the bar, once), and
    /// its translation is not drawn while it is out of view; a row the same pass read that is
    /// still in view is taken where the page carried it, so the pass did place what it read.
    func testARowReadWhileGlidingIsNotPlacedOnTheRowThatLooksAlikeWhereItsTilesStopped() throws {
        let width = SyntheticScreen.width, height = SyntheticScreen.height, period = 80
        var page = SyntheticPage.page(width: width, height: 2000, seed: 31, period: period)
        let other = SyntheticPage.page(width: width, height: 2000, seed: 32, lineHeight: 24, lineGap: 56)
        // every row the same but for its right end
        for y in 0..<2000 {
            for x in 280..<width {
                page[y * width + x] = other[y * width + x]
            }
        }
        let bar = SyntheticScreen.topBar
        /// The page scrolled by `offset` frame pixels under a bar, with a damaged square at (x, y)
        /// of the thumbnail
        func frame(offset: Int, damageAt damage: (x: Int, y: Int)? = nil) -> LumaImage {
            var pixels = [UInt8](repeating: 225, count: width * height)
            for y in bar..<height where y + offset < 2000 {
                for x in 0..<width {
                    pixels[y * width + x] = page[(y + offset) * width + x]
                }
            }
            for x in 0..<width {
                pixels[(bar - 1) * width + x] = 190
            }
            for y in 20..<40 {
                for x in 150..<250 where (x / 5) % 2 == 0 {
                    pixels[y * width + x] = 30
                }
            }
            var image = LumaImage(width: width, height: height, pixels: pixels).downsampled(by: scale)
            if let damage {
                for y in (damage.y - 14)..<(damage.y + 14) {
                    for x in (damage.x - 16)..<(damage.x + 16) {
                        image[x, y] = (x / 2 + y / 2) % 2 == 0 ? 15 : 245
                    }
                }
            }
            return image
        }
        let tracker = OverlayTracker()
        let start = 110, speed = period - 4
        // the row read: its top at 320 in the frame the pass starts on; four frames later its own
        // place is under the bar, and the next row is 4 frame pixels from where its tiles went
        let row = RecognizedBlock(text: "Row", rect: CGRect(x: 16, y: 320, width: 254, height: 24))
        _ = tracker.advance(frame(offset: start), scale: scale, time: 0)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 0.5))
        // (the point that carries the row over to the current frame: the one nearest its centre,
        // where it is after the first frame)
        let probe = (x: 72, y: 168 - speed / scale)
        for step in 1...4 {
            let update = tracker.advance(frame(offset: start + speed * step, damageAt: step == 2 ? probe : nil),
                                         scale: scale, time: 0.5 + Double(step) / 60)
            XCTAssertEqual(update.change, .scrolled, "frame \(step)")
        }
        // (a row read by the same pass that is still in view: taken where its area carried it)
        let second = RecognizedBlock(text: "Second", rect: CGRect(x: 16, y: 640, width: 254, height: 24))
        tracker.finishRecognition(request, blocks: [row, second], time: 0.5 + 4.5 / 60)
        let seconds = tracker.blocks.filter { $0.text == "Second" }
        XCTAssertEqual(seconds.count, 1, "the row in view is kept once")
        XCTAssertEqual(seconds.first?.rect.minY ?? 0, Double(640 - 4 * speed), accuracy: 2.0,
                       "the row in view is where the page carried it")
        let rows = tracker.blocks.filter { $0.text == "Row" }
        XCTAssertLessThanOrEqual(rows.count, 1, "the row is kept once at most: \(rows.map(\.rect))")
        for block in rows {
            XCTAssertLessThanOrEqual(block.rect.minY, Double(bar),
                                     "the row is under the bar, not on the row that looks alike: \(block.rect)")
        }
        tracker.setTranslation("T Row", for: "Row")
        for step in 5...6 {
            let update = tracker.advance(frame(offset: start + speed * step), scale: scale,
                                         time: 0.5 + Double(step) / 60)
            XCTAssertFalse(update.placed.contains { $0.text == "T Row" },
                           "frame \(step): the row is out of view, its translation is not drawn")
        }
    }

    /// The screen of `SyntheticScreen` with the page scrolled by `offset`; without `tabBar`, the
    /// page reaches down to a thin plain strip with a pill in it at the lower edge of the screen
    /// (where a keyboard was), with it the bottom bar of `SyntheticScreen` lies over the page
    private static func screenWithTabBar(_ screen: SyntheticScreen, offset: Int, tabBar: Bool, noise: UInt64) -> LumaImage {
        var image = screen.thumbnail(offset: offset)
        let page = SyntheticPage.thumbnail(screen.page, pageWidth: SyntheticScreen.width, left: 0, top: offset,
                                           width: SyntheticScreen.width, height: SyntheticScreen.height,
                                           scale: SyntheticScreen.scale)
        let width = SyntheticScreen.width / 2, height = SyntheticScreen.height / 2
        if !tabBar {
            for y in (SyntheticScreen.bottomBar / 2)..<height {
                for x in 0..<width {
                    let isPill = y >= height - 6 && y < height - 3 && x >= 70 && x < 130
                    image[x, y] = y >= height - 10 ? (isPill ? 40 : 225) : page[x, y]
                }
            }
        }
        return SyntheticPage.noisy(image, amount: 2, seed: noise)
    }

    /// A paragraph runs under the bottom bar, and the box of its reading ends a pixel or two
    /// inside the bar (it takes in the bar's edge). The bar came only after the page had moved
    /// down to the lower edge of the screen (a keyboard went away), so the scrolling area still
    /// reaches down there: nothing tells that the reading is cut off at the bar. The page moves
    /// down while the reading is on its way; carried with it to the frame shown when the pass
    /// ends, the lowest line has slid under the bar, and the box reaches into the bar as far as
    /// the page moved. The rows of the patch at its lower edge show the bar as the bar shows
    /// there still, but they stayed where they were read: what lies over the text behind them is
    /// found all the same, and nothing is drawn over the bar.
    func testAReadingCarriedUnderTheBottomBarIsCutAtTheBar() throws {
        let screen = SyntheticScreen(seed: 12)
        let tracker = OverlayTracker()
        let bar = SyntheticScreen.bottomBar
        // line 10 shows 10 frame pixels above the bar when the pass starts, none when it ends
        let start = SyntheticScreen.firstLine + 10 * SyntheticScreen.linePitch - (bar - 10)
        var time = 0.0
        // the page scrolls up to its place without the bar, rests, and the bar comes
        for frame in 0..<8 {
            _ = tracker.advance(Self.screenWithTabBar(screen, offset: start - 8 * (8 - frame), tabBar: false,
                                                      noise: UInt64(frame + 1)), scale: scale, time: time)
            time += 1.0 / 60
        }
        for frame in 0..<4 {
            _ = tracker.advance(Self.screenWithTabBar(screen, offset: start, tabBar: frame > 0, noise: UInt64(frame + 11)),
                                scale: scale, time: time)
            time += 1.0 / 60
        }
        time += 1
        let request = try XCTUnwrap(tracker.beginRecognition(time: time))
        // the page moves down by 14 frame pixels while the reading is on its way
        let offset = start - 14
        time += 1.0 / 60
        _ = tracker.advance(Self.screenWithTabBar(screen, offset: offset, tabBar: true, noise: 21), scale: scale, time: time)
        // lines 9 and 10 as one paragraph, in the pixels of the frame the pass started on, down
        // to 5 frame pixels into the bar
        let top = SyntheticScreen.block(9, offset: start, text: "").rect.minY
        let paragraph = RecognizedBlock(text: "Nine and ten",
                                        rect: CGRect(x: Double(SyntheticScreen.lineLeft), y: top,
                                                     width: Double(SyntheticScreen.lineRight - SyntheticScreen.lineLeft),
                                                     height: Double(bar + 5) - top),
                                        lineCount: 2)
        tracker.finishRecognition(request, blocks: [paragraph], time: time + 0.01)
        // (its translation is known: the paragraph was translated before)
        tracker.setTranslation("T Nine and ten", for: "Nine and ten")
        // the page rests: no frame comes, the translation is drawn into the last one
        let update = tracker.advance(Self.screenWithTabBar(screen, offset: offset, tabBar: true, noise: 21), scale: scale,
                                     time: time + 0.1)
        let placed = try XCTUnwrap(update.placed.first { $0.text == "T Nine and ten" }, "the paragraph is translated")
        let drawn = placed.visibleRect ?? placed.rect
        XCTAssertLessThanOrEqual(drawn.maxY, Double(bar + scale), "nothing is drawn over the bar: \(drawn)")
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

    /// A floating button learned while the page scrolled is still known when the page creeps
    /// the last pixel or two before it rests: a paragraph read at rest whose box reaches under
    /// the button (the recognizer's box takes in the part of the line beside it) is not drawn
    /// over the button
    func testAFloatingButtonIsNotForgottenAsTheScrollComesToRest() throws {
        let screen = SyntheticScreen(seed: 6)
        let tracker = OverlayTracker()
        // the button, in thumbnail pixels: an outline, a plus in its middle; over the right end
        // of the lines
        let button = (x: 160, y: 200, side: 28)
        func frame(offset: Int) -> LumaImage {
            var image = screen.thumbnail(offset: offset)
            for y in button.y..<(button.y + button.side) {
                for x in button.x..<(button.x + button.side) {
                    let inPlus = (abs(x - button.x - button.side / 2) < 2 && abs(y - button.y - button.side / 2) < 8)
                        || (abs(y - button.y - button.side / 2) < 2 && abs(x - button.x - button.side / 2) < 8)
                    let isEdge = x == button.x || y == button.y || x == button.x + button.side - 1
                        || y == button.y + button.side - 1
                    image[x, y] = inPlus ? 250 : (isEdge ? 20 : 90)
                }
            }
            return image
        }
        // line 10 ends at rest with its lower part beside and under the button
        let rest = SyntheticScreen.firstLine + 10 * SyntheticScreen.linePitch - (button.y * scale + 40)
        // 3 thumbnail pixels a frame, then 1, then rest
        var offsets = (0..<20).map { rest - 4 - 6 * (19 - $0) }
        offsets += [rest - 2, rest, rest, rest]
        var time = 0.0
        for offset in offsets {
            _ = tracker.advance(frame(offset: offset), scale: scale, time: time)
            time += 1.0 / 60
        }
        time += 1
        let request = try XCTUnwrap(tracker.beginRecognition(time: time))
        let line = SyntheticScreen.block(10, offset: rest, text: "Ten")
        let buttonRect = CGRect(x: button.x * scale, y: button.y * scale, width: button.side * scale,
                                height: button.side * scale)
        XCTAssertTrue(line.rect.intersects(buttonRect), "the box of the line reaches under the button")
        tracker.finishRecognition(request, blocks: [line], time: time + 0.2)
        for text in tracker.textsAwaitingTranslation(limit: 5, time: time + 0.2) {
            tracker.setTranslation("T " + text, for: text)
        }
        let update = tracker.advance(frame(offset: rest), scale: scale, time: time + 0.3)
        let placed = try XCTUnwrap(update.placed.first { $0.text == "T Ten" }, "the line is translated beside the button")
        let drawn = placed.visibleRect ?? placed.rect
        let overlap = drawn.intersection(buttonRect)
        XCTAssertTrue(overlap.isNull || overlap.width <= Double(scale) || overlap.height <= Double(scale),
                      "nothing is drawn over the button: \(drawn)")
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

extension OverlayTrackerFollowingTests {
    /// The title in the top bar of `SyntheticScreen`, frame pixels
    private static let titleRect = CGRect(x: 120, y: 12, width: 160, height: 36)

    /// Strokes like the lines of `SyntheticScreen`, on the bar's grey, in a band of frame pixels
    private static func titleStrokes(seed: UInt64, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 225, count: width * height)
        var random = SyntheticPage.Random(state: seed)
        var x = 4
        while x < width - 8 {
            let strokeWidth = 2 + random.below(4)
            let strokeTop = 4 + random.below(8), strokeBottom = height - 4 - random.below(8)
            let level = UInt8(20 + random.below(30))
            for y in strokeTop..<strokeBottom {
                for dx in 0..<strokeWidth where x + dx < width - 4 {
                    pixels[y * width + x + dx] = level
                }
            }
            x += strokeWidth + 2 + random.below(6)
        }
        return pixels
    }

    /// The screen, its page scrolled by `offset` frame pixels, with a title of its own written over
    /// the top bar: the strokes of `seed`, from `split` (frame pixels into the title) on those of
    /// `other`; with `badge`, a small mark on either side of the title; noise is added once, to the
    /// whole frame
    private static func screenWithTitle(_ screen: SyntheticScreen, offset: Int = 0, seed: UInt64, other: UInt64,
                                        split: Int, badge: Bool = false, noise: UInt64) -> LumaImage {
        var image = screen.thumbnail(offset: offset)
        let width = Int(titleRect.width), height = Int(titleRect.height)
        let first = titleStrokes(seed: seed, width: width, height: height)
        let second = titleStrokes(seed: other, width: width, height: height)
        // (the bar without the title of `SyntheticScreen`)
        for y in 0..<(SyntheticScreen.topBar - 2) / 2 {
            for x in 0..<SyntheticScreen.width / 2 {
                image[x, y] = 225
            }
        }
        for y in 0..<height / 2 {
            for x in 0..<width / 2 {
                var sum = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let column = 2 * x + dx, index = (2 * y + dy) * width + column
                        sum += Int(column < split ? first[index] : second[index])
                    }
                }
                image[Int(titleRect.minX) / 2 + x, Int(titleRect.minY) / 2 + y] = UInt8(sum / 4)
            }
        }
        if badge {
            for y in 9..<20 {
                for x in 146..<152 { image[x, y] = 40 }
                for x in 52..<58 { image[x, y] = 40 }
            }
        }
        return SyntheticPage.noisy(image, amount: 2, seed: noise)
    }

    /// The title of a bar (it lies in no scrolling area) is replaced in place by another one
    /// that looks alike, as when another screen comes. Its patch fits the new title a fraction
    /// of a pixel away about as well as the check of a block allows, but much worse than when it
    /// was read: its translation is no longer drawn. The same title, only noisier, keeps it.
    func testATitleReplacedInPlaceLosesItsTranslation() throws {
        let screen = SyntheticScreen(seed: 9)
        let title = RecognizedBlock(text: "Title", rect: Self.titleRect)
        for replaced in [false, true] {
            let tracker = OverlayTracker()
            _ = tracker.advance(Self.screenWithTitle(screen, seed: 40, other: 40, split: 0, noise: 7), scale: scale,
                                time: 0)
            let request = try XCTUnwrap(tracker.beginRecognition(time: 1))
            tracker.finishRecognition(request, blocks: [title], time: 1.2)
            for text in tracker.textsAwaitingTranslation(limit: 50, time: 1.2) {
                tracker.setTranslation("T " + text, for: text)
            }
            let before = tracker.advance(Self.screenWithTitle(screen, seed: 40, other: 40, split: 0, noise: 8),
                                         scale: scale, time: 1.3)
            XCTAssertTrue(before.placed.contains { $0.text == "T Title" })
            // (the last third of its letters are others)
            let frame = Self.screenWithTitle(screen, seed: 40, other: replaced ? 43 : 40, split: 100, noise: 9)
            for time in [1.35, 1.4] {
                let drawn = tracker.advance(frame, scale: scale, time: time).placed.contains { $0.text == "T Title" }
                XCTAssertEqual(drawn, !replaced, "replaced \(replaced), at \(time)")
            }
        }
    }

    /// The same while the page below the bar scrolls (3 frame pixels per frame, then it rests).
    /// The first changed frame makes the title doubtful; the next ones carry it, and that does
    /// not end the doubt while it fits as badly: the old translation does not come back over the
    /// new title. The same title, unchanged, stays drawn over the moving page.
    func testATitleReplacedWhileThePageBelowScrollsLosesItsTranslation() throws {
        let screen = SyntheticScreen(seed: 9)
        let title = RecognizedBlock(text: "Title", rect: Self.titleRect)
        // (read where the page is already scrolled: its lines lie under the whole bar)
        let start = 120
        for replaced in [false, true] {
            let tracker = OverlayTracker()
            _ = tracker.advance(Self.screenWithTitle(screen, offset: start, seed: 40, other: 40, split: 0, noise: 7),
                                scale: scale, time: 0)
            let request = try XCTUnwrap(tracker.beginRecognition(time: 1))
            tracker.finishRecognition(request, blocks: [title], time: 1.2)
            for text in tracker.textsAwaitingTranslation(limit: 50, time: 1.2) {
                tracker.setTranslation("T " + text, for: text)
            }
            let before = tracker.advance(Self.screenWithTitle(screen, offset: start, seed: 40, other: 40, split: 0,
                                                              noise: 8), scale: scale, time: 1.3)
            XCTAssertTrue(before.placed.contains { $0.text == "T Title" }, "replaced \(replaced)")
            // (four frames that scroll, two at rest)
            for step in 0..<6 {
                let time = 1.35 + 0.05 * Double(step)
                let frame = Self.screenWithTitle(screen, offset: start + 3 * min(step + 1, 4), seed: 40,
                                                 other: replaced ? 43 : 40, split: 100, noise: 9 + UInt64(step))
                let drawn = tracker.advance(frame, scale: scale, time: time).placed.contains { $0.text == "T Title" }
                XCTAssertEqual(drawn, !replaced, "replaced \(replaced), at \(time)")
            }
        }
    }

    /// A badge appears beside a bar title, and a pass begins over the bar, title included; while
    /// it runs, the title is replaced in place by one that looks alike, and it becomes doubtful.
    /// The pass then reads the old title from the picture it began with: that must not confirm
    /// the doubtful block (the old translation would come back over the new title and stay
    /// there, since nothing changes under it at rest); its place is read again instead. The same
    /// title, unchanged, keeps its translation.
    func testAPassThatBeganBeforeATitleWasReplacedDoesNotBringItsTranslationBack() {
        let screen = SyntheticScreen(seed: 9)
        let badgeAt = 2.0, replaceAt = 2.5, duration = 0.3, end = 6.0
        for replaced in [false, true] {
            let tracker = OverlayTracker()
            var running: (request: RecognitionRequest, start: Double, replacedAtStart: Bool)?
            var staleReading = false
            var drawnAfterReplacement = 0, drawnAtEnd = false
            var step = 0
            var time = 0.0
            while time <= end {
                let changed = replaced && time >= replaceAt
                let frame = Self.screenWithTitle(screen, offset: 120, seed: 40, other: changed ? 43 : 40,
                                                 split: changed ? 100 : 0, badge: time >= badgeAt,
                                                 noise: 7 + UInt64(step))
                let output = tracker.advance(frame, scale: scale, time: time)
                if let pass = running, time - pass.start >= duration {
                    // (a pass reads what showed when it began)
                    let text = pass.replacedAtStart ? "Other title" : "Title"
                    let region = pass.request.region
                    var blocks: [RecognizedBlock] = []
                    if region.contains(Self.titleRect) {
                        blocks.append(RecognizedBlock(text: text, rect: Self.titleRect))
                        if replaced, !pass.replacedAtStart, time >= replaceAt { staleReading = true }
                    } else if region.intersects(Self.titleRect) {
                        // (the part inside the region)
                        let part = region.intersection(Self.titleRect)
                        let count = max(1, Int(Double(text.count) * Double(part.width / Self.titleRect.width)))
                        blocks.append(RecognizedBlock(text: String(text.prefix(count)), rect: part))
                    }
                    tracker.finishRecognition(pass.request, blocks: blocks, time: time)
                    for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                        tracker.setTranslation("T " + text, for: text)
                    }
                    running = nil
                }
                if running == nil, let request = tracker.beginRecognition(time: time) {
                    running = (request, time, changed)
                }
                let drawn = output.placed.contains { $0.text == "T Title" }
                if time >= replaceAt, drawn { drawnAfterReplacement += 1 }
                drawnAtEnd = drawn
                step += 1
                time = Double(step) * 0.05
            }
            if replaced {
                XCTAssertTrue(staleReading, "a pass that began before the title was replaced read it after")
                XCTAssertEqual(drawnAfterReplacement, 0, "the old translation over the new title")
            } else {
                XCTAssertTrue(drawnAtEnd, "the unchanged title keeps its translation")
            }
        }
    }
}
