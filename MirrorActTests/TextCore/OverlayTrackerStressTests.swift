// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Inputs that the bench does not produce: sizes at the limits, odd rectangles and texts,
/// calls out of order, long runs. The tracker must not crash, hang or grow without bound, and
/// must stay deterministic.
final class OverlayTrackerStressTests: XCTestCase {
    private typealias Page = SyntheticPage

    /// A debug build is fifty to a hundred times slower: there the long runs are shorter
    private static var length: Int {
        #if DEBUG
        return 1
        #else
        return 5
        #endif
    }

    /// A page window scrolled to `top`, `width` × `height` frame pixels reduced by `scale`
    private static func frame(_ page: [UInt8], pageWidth: Int, top: Int, width: Int, height: Int,
                              scale: Int) -> LumaImage {
        Page.thumbnail(page, pageWidth: pageWidth, left: 0, top: top, width: width, height: height, scale: scale)
    }

    /// Plays frames, reads every region when due (returning `blocks` mapped into the region)
    /// and translates everything; returns the number of calls made
    @discardableResult
    private static func drive(_ tracker: OverlayTracker, frames: [LumaImage], scale: Int, start: TimeInterval = 0,
                              step: TimeInterval = 1.0 / 60, blocks: (RecognitionRequest) -> [RecognizedBlock]) -> Int {
        var time = start
        var calls = 0
        var pending: (request: RecognitionRequest, finish: TimeInterval)?
        for image in frames {
            let update = tracker.advance(image, scale: scale, time: time)
            calls += 1
            for placed in update.placed {
                XCTAssertTrue(placed.rect.minX.isFinite && placed.rect.minY.isFinite && placed.rect.width.isFinite
                              && placed.rect.height.isFinite, "placed rectangles are finite")
            }
            if let running = pending, time >= running.finish {
                tracker.finishRecognition(running.request, blocks: blocks(running.request), time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                pending = (request, time + 0.1)
            }
            for text in tracker.textsAwaitingTranslation(limit: 40, time: time) {
                tracker.setTranslation("T:" + text, for: text)
            }
            time += step
        }
        return calls
    }

    func testTinyAndEmptyPicturesDoNotCrash() {
        let sizes = [(0, 0), (1, 1), (1, 7), (7, 1), (2, 3), (7, 7), (8, 8), (9, 5), (17, 3), (3, 17), (16, 16)]
        for (width, height) in sizes {
            for scale in [1, 2, 6] {
                let tracker = OverlayTracker()
                var frames: [LumaImage] = []
                for index in 0..<12 {
                    var image = LumaImage(width: width, height: height, fill: 240)
                    for pixel in image.pixels.indices where (pixel + index) % 3 == 0 {
                        image.pixels[pixel] = 20
                    }
                    frames.append(image)
                }
                OverlayTrackerStressTests.drive(tracker, frames: frames, scale: scale) { request in
                    [RecognizedBlock(text: "tiny", rect: request.region),
                     RecognizedBlock(text: "line", rect: CGRect(x: 0, y: 0, width: 1, height: 1))]
                }
            }
        }
    }

    func testOddRectanglesAndTextsFromTheRecognizer() {
        let width = 390, height = 844
        let page = Page.page(width: width * 2, height: height * 2 + 400, seed: 5)
        var frames: [LumaImage] = []
        for index in 0..<(18 * OverlayTrackerStressTests.length) {
            frames.append(OverlayTrackerStressTests.frame(page, pageWidth: width * 2, top: index < 6 ? 0 : (index - 6) * 5,
                                                         width: width * 2, height: height * 2, scale: 2))
        }
        let tracker = OverlayTracker()
        OverlayTrackerStressTests.drive(tracker, frames: frames, scale: 2) { request in
            let region = request.region
            var blocks: [RecognizedBlock] = [
                RecognizedBlock(text: "", rect: CGRect(x: region.minX + 10, y: region.minY + 10, width: 50, height: 20)),
                RecognizedBlock(text: "   \n ", rect: CGRect(x: region.minX + 70, y: region.minY + 10, width: 50, height: 20)),
                RecognizedBlock(text: "zero", rect: CGRect(x: region.minX + 5, y: region.minY + 5, width: 0, height: 0)),
                RecognizedBlock(text: "negative", rect: CGRect(x: region.midX, y: region.midY, width: -40, height: -12)),
                RecognizedBlock(text: "one pixel high", rect: CGRect(x: region.minX + 20, y: region.midY, width: 200, height: 1)),
                RecognizedBlock(text: "one pixel wide", rect: CGRect(x: region.midX, y: region.minY + 30, width: 1, height: 60)),
                RecognizedBlock(text: "outside", rect: CGRect(x: -500, y: -500, width: 100, height: 30)),
                RecognizedBlock(text: "far outside", rect: CGRect(x: 1e9, y: 1e9, width: 100, height: 30)),
                RecognizedBlock(text: "huge", rect: CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7), lineCount: 0),
                RecognizedBlock(text: "edge", rect: CGRect(x: 0, y: region.maxY - 20, width: 120, height: 20)),
                RecognizedBlock(text: "corner", rect: CGRect(x: CGFloat(width * 2) - 30, y: CGFloat(height * 2) - 30,
                                                            width: 30, height: 30)),
                RecognizedBlock(text: String(repeating: "long text ", count: 3000),
                                rect: CGRect(x: region.minX + 4, y: region.minY + 40, width: 300, height: 400), lineCount: 20),
                RecognizedBlock(text: "nan", rect: CGRect(x: CGFloat.nan, y: 10, width: 10, height: 10)),
                RecognizedBlock(text: "inf", rect: CGRect(x: 10, y: CGFloat.infinity, width: 10, height: 10)),
            ]
            // the same text many times
            for row in 0..<40 {
                blocks.append(RecognizedBlock(text: "same", rect: CGRect(x: region.minX + 8, y: region.minY + CGFloat(row * 30),
                                                                         width: 80, height: 24)))
            }
            return blocks
        }
        // and the same texts again, read differently
        XCTAssertNoThrow(tracker.blocks.map(\.text))
    }

    func testThreeHundredBlocksOnAScrollingScreen() {
        let width = 780, height = 1688
        let page = Page.page(width: width, height: height + 1200, seed: 9, lineHeight: 10, lineGap: 4)
        var frames: [LumaImage] = []
        for index in 0..<(16 * OverlayTrackerStressTests.length) {
            frames.append(OverlayTrackerStressTests.frame(page, pageWidth: width, top: index < 8 ? 0 : (index - 8) * 7,
                                                         width: width, height: height, scale: 2))
        }
        let tracker = OverlayTracker()
        let start = ProcessInfo.processInfo.systemUptime
        OverlayTrackerStressTests.drive(tracker, frames: frames, scale: 2) { request in
            var blocks: [RecognizedBlock] = []
            let region = request.region
            var y = region.minY + 4
            while y + 10 < region.maxY, blocks.count < 300 {
                for column in 0..<3 {
                    blocks.append(RecognizedBlock(text: "block \(Int(y)) \(column)",
                                                  rect: CGRect(x: region.minX + 8 + CGFloat(column * 250), y: y, width: 200,
                                                               height: 10)))
                }
                y += 14
            }
            return blocks
        }
        let seconds = ProcessInfo.processInfo.systemUptime - start
        XCTAssertLessThan(seconds, 120, "300 blocks must not make the tracker crawl")
        XCTAssertLessThanOrEqual(tracker.blocks.count, 2000)
    }

    func testThousandsOfFramesWithoutRecognitionStayBounded() {
        let width = 200, height = 360
        let page = Page.page(width: width, height: height + 1500, seed: 3)
        let tracker = OverlayTracker()
        var time = 0.0
        // one reading to have a block, then frames that scroll back and forth and now and then
        // change, never read again
        _ = tracker.advance(OverlayTrackerStressTests.frame(page, pageWidth: width, top: 0, width: width, height: height,
                                                            scale: 1), scale: 1, time: time)
        if let request = tracker.beginRecognition(time: time + 1) {
            tracker.finishRecognition(request, blocks: [RecognizedBlock(text: "a", rect: CGRect(x: 10, y: 30, width: 150,
                                                                                                    height: 24))], time: time + 1)
        }
        var top = 0
        var direction = 3
        var firstSeconds = 0.0, lastSeconds = 0.0
        let count = OverlayTrackerStressTests.length > 1 ? 2000 : 100
        for index in 0..<count {
            time += 1.0 / 60
            top += direction
            if top > 1400 || top < 0 { direction = -direction }
            var image = OverlayTrackerStressTests.frame(page, pageWidth: width, top: max(0, top), width: width, height: height,
                                                        scale: 1)
            if index % 97 == 0 { image = Page.noisy(image, amount: 40, seed: UInt64(index)) }
            let start = ProcessInfo.processInfo.systemUptime
            _ = tracker.advance(image, scale: 1, time: time)
            let seconds = ProcessInfo.processInfo.systemUptime - start
            if index < 300 { firstSeconds += seconds }
            if index >= count - 300 { lastSeconds += seconds }
        }
        XCTAssertLessThanOrEqual(tracker.blocks.count, 1, "no blocks are made up without reading")
        XCTAssertNotNil(tracker.recognitionDue, "something is due after all that moving")
        // (what the tracker keeps does not grow with time: the last frames take no longer than the first)
        XCTAssertLessThan(lastSeconds, 3 * firstSeconds + 0.05)
    }

    func testTimeGoingBackwardsOrStandingStill() {
        let width = 360, height = 640
        let page = Page.page(width: width, height: height + 600, seed: 4)
        let tracker = OverlayTracker()
        let times: [TimeInterval] = [5, 5, 4, 4.5, 100, 3, 3, 3, -1, 0, 0, 1e9, -1e9, 7]
        for (index, time) in times.enumerated() {
            let image = OverlayTrackerStressTests.frame(page, pageWidth: width, top: index * 9, width: width, height: height,
                                                        scale: 1)
            _ = tracker.advance(image, scale: 1, time: time)
            if let request = tracker.beginRecognition(time: time) {
                tracker.finishRecognition(request, blocks: [RecognizedBlock(text: "t\(index)",
                                                                            rect: CGRect(x: 10, y: 40, width: 120, height: 24))],
                                          time: time - 10)
            }
            _ = tracker.textsAwaitingTranslation(limit: 5, time: time)
            _ = tracker.isSettled(at: time)
        }
    }

    func testCallsOutOfOrder() {
        let width = 360, height = 640
        let page = Page.page(width: width, height: height + 600, seed: 6)
        let tracker = OverlayTracker()
        // before any frame
        XCTAssertNil(tracker.beginRecognition(time: 0))
        XCTAssertNil(tracker.recognitionDue)
        let stray = RecognitionRequest(id: 99, region: CGRect(x: 0, y: 0, width: 10, height: 10), isFullFrame: false)
        tracker.finishRecognition(stray, blocks: [RecognizedBlock(text: "x", rect: CGRect(x: 1, y: 1, width: 5, height: 5))],
                                  time: 0)
        tracker.abandonRecognition(stray)
        tracker.setTranslation("y", for: "never seen")
        tracker.translationFailed(for: "never seen", time: 0)
        XCTAssertTrue(tracker.blocks.isEmpty)

        let first = OverlayTrackerStressTests.frame(page, pageWidth: width, top: 0, width: width, height: height, scale: 1)
        _ = tracker.advance(first, scale: 1, time: 0)
        guard let request = tracker.beginRecognition(time: 1) else { return XCTFail("a first picture must be read") }
        XCTAssertNil(tracker.beginRecognition(time: 1), "one pass at a time")
        // the size changes while the pass runs: its result no longer applies
        let small = OverlayTrackerStressTests.frame(page, pageWidth: width, top: 0, width: width / 2, height: height / 2,
                                                    scale: 1)
        XCTAssertEqual(tracker.advance(small, scale: 1, time: 1.1).change, .resized)
        tracker.finishRecognition(request, blocks: [RecognizedBlock(text: "old", rect: CGRect(x: 300, y: 600, width: 50,
                                                                                                 height: 20))], time: 1.2)
        XCTAssertFalse(tracker.blocks.contains { $0.text == "old" }, "a pass on a picture of another size is dropped")
        // finished twice, abandoned after finishing, an outdated request
        tracker.finishRecognition(request, blocks: [], time: 1.3)
        tracker.abandonRecognition(request)
        guard let second = tracker.beginRecognition(time: 2) else { return XCTFail("the new size must be read") }
        tracker.abandonRecognition(second)
        tracker.finishRecognition(second, blocks: [RecognizedBlock(text: "late", rect: CGRect(x: 4, y: 4, width: 40,
                                                                                                 height: 12))], time: 2.1)
        XCTAssertFalse(tracker.blocks.contains { $0.text == "late" }, "an abandoned pass brings nothing")
        XCTAssertNotNil(tracker.recognitionDue, "what an abandoned pass was to read is still due")
        tracker.reset()
        XCTAssertTrue(tracker.blocks.isEmpty)
        XCTAssertNil(tracker.recognitionDue)
    }

    func testScaleOneAndLargeThumbnails() {
        // a frame that is not reduced, and a thumbnail far larger than any the caller makes
        for (width, height) in [(400, 300), OverlayTrackerStressTests.length > 1 ? (1600, 1200) : (900, 700)] {
            let page = Page.page(width: width, height: height + 200, seed: 8)
            var frames: [LumaImage] = []
            for index in 0..<8 {
                frames.append(OverlayTrackerStressTests.frame(page, pageWidth: width, top: index * 13, width: width,
                                                             height: height, scale: 1))
            }
            let tracker = OverlayTracker()
            OverlayTrackerStressTests.drive(tracker, frames: frames, scale: 1) { request in
                [RecognizedBlock(text: "big", rect: CGRect(x: request.region.minX + 16, y: request.region.minY + 30,
                                                           width: 300, height: 24))]
            }
        }
    }

    func testRandomPicturesAreDeterministic() {
        func run() -> [FrameUpdate] {
            var random = Page.Random(state: 77)
            let tracker = OverlayTracker()
            var updates: [FrameUpdate] = []
            let width = 200, height = 300
            let page = Page.page(width: width, height: height + 800, seed: 11)
            var top = 0
            for index in 0..<(OverlayTrackerStressTests.length > 1 ? 240 : 20) {
                let kind = random.below(10)
                if kind < 6 { top = max(0, min(800, top + random.below(41) - 20)) }
                var image = OverlayTrackerStressTests.frame(page, pageWidth: width, top: top, width: width, height: height,
                                                            scale: 1)
                if kind == 7 { image = Page.noisy(image, amount: 60, seed: UInt64(index)) }
                if kind == 8 {
                    for pixel in image.pixels.indices { image.pixels[pixel] = UInt8(random.below(256)) }
                }
                let time = Double(index) / 60
                updates.append(tracker.advance(image, scale: 1, time: time))
                if let request = tracker.beginRecognition(time: time) {
                    var blocks: [RecognizedBlock] = []
                    for _ in 0..<random.below(6) {
                        blocks.append(RecognizedBlock(text: "w\(random.below(5))",
                                                      rect: CGRect(x: random.below(220) - 10, y: random.below(320) - 10,
                                                                   width: random.below(120), height: random.below(40))))
                    }
                    tracker.finishRecognition(request, blocks: blocks, time: time)
                }
                for text in tracker.textsAwaitingTranslation(limit: 3, time: time) {
                    tracker.setTranslation(text.uppercased() + "!", for: text)
                }
            }
            return updates
        }
        XCTAssertEqual(run(), run())
    }
}
