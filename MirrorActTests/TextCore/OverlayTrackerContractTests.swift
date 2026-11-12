// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// What every implementation of `OverlayTracker` must do, whatever it does to follow moving
/// content (Foundation only, like the core)
final class OverlayTrackerContractTests: XCTestCase {
    private let scale = 2
    private let width = 200, height = 400     // thumbnail; frames are 400 × 800

    /// a light page with dark "text" bars at the given thumbnail rows
    private func page(bars: [Int] = [40, 120, 200]) -> LumaImage {
        var image = LumaImage(width: width, height: height, fill: 240)
        for top in bars {
            for y in top..<(top + 10) {
                for x in 20..<160 where (x / 6) % 2 == 0 { image[x, y] = 30 }
            }
        }
        return image
    }

    private func block(_ text: String, row: Int) -> RecognizedBlock {
        RecognizedBlock(text: text, rect: CGRect(x: 40, y: row * scale, width: 280, height: 20))
    }

    private func readPage(_ tracker: OverlayTracker, at time: TimeInterval) throws -> RecognitionRequest {
        try XCTUnwrap(tracker.beginRecognition(time: time), "a still picture with unread parts must be read")
    }

    func testFirstFrameIsReadCompletelyOnceItIsStill() throws {
        let tracker = OverlayTracker()
        let update = tracker.advance(page(), scale: scale, time: 10)
        XCTAssertEqual(update.change, .first)
        XCTAssertTrue(update.placed.isEmpty)
        let due = try XCTUnwrap(update.recognitionDue)
        XCTAssertLessThanOrEqual(due, 10 + 1, "the first reading must not wait long")
        let request = try readPage(tracker, at: due)
        XCTAssertTrue(request.isFullFrame)
        XCTAssertEqual(request.region, CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertNil(tracker.beginRecognition(time: due + 1), "one pass at a time")
        XCTAssertNil(tracker.recognitionDue)
    }

    func testTranslationsAppearOnTheirBlocksAndStayOnAStillPicture() throws {
        let tracker = OverlayTracker()
        _ = tracker.advance(page(), scale: scale, time: 0)
        let request = try readPage(tracker, at: 1)
        tracker.finishRecognition(request, blocks: [block("Einstellungen", row: 40), block("WLAN", row: 120)], time: 1.1)
        XCTAssertEqual(tracker.blocks.map(\.text), ["Einstellungen", "WLAN"])
        XCTAssertTrue(tracker.advance(page(), scale: scale, time: 1.2).placed.isEmpty, "nothing is drawn before it is translated")

        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 1.2), ["Einstellungen", "WLAN"])
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 1.3), [], "requested texts are not offered twice")
        tracker.setTranslation("Settings", for: "Einstellungen")
        tracker.setTranslation("wlan", for: "WLAN")   // same text: nothing to show

        let update = tracker.advance(page(), scale: scale, time: 1.4)
        XCTAssertEqual(update.change, .unchanged)
        XCTAssertEqual(update.placed.map(\.text), ["Settings"])
        XCTAssertEqual(update.placed.first?.rect, CGRect(x: 40, y: 80, width: 280, height: 20))
        XCTAssertNil(update.recognitionDue, "a picture that was read and did not change is not read again")
    }

    func testFailedTranslationsAreOfferedAgainLater() throws {
        let tracker = OverlayTracker()
        _ = tracker.advance(page(), scale: scale, time: 0)
        tracker.finishRecognition(try readPage(tracker, at: 1), blocks: [block("Einstellungen", row: 40)], time: 1)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 1), ["Einstellungen"])
        tracker.translationFailed(for: "Einstellungen", time: 2)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 2.5), [])
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 2 + tracker.configuration.retryDelay + 0.1), ["Einstellungen"])
    }

    func testTranslationsAreRememberedForTextThatComesBack() throws {
        let tracker = OverlayTracker()
        _ = tracker.advance(page(), scale: scale, time: 0)
        tracker.finishRecognition(try readPage(tracker, at: 1), blocks: [block("Einstellungen", row: 40)], time: 1)
        _ = tracker.textsAwaitingTranslation(limit: 10, time: 1)
        tracker.setTranslation("Settings", for: "Einstellungen")

        // another screen, then the first one again
        _ = tracker.advance(LumaImage(width: width, height: height, fill: 20), scale: scale, time: 2)
        XCTAssertTrue(tracker.advance(LumaImage(width: width, height: height, fill: 20), scale: scale, time: 2.1).placed.isEmpty)
        tracker.finishRecognition(try readPage(tracker, at: 3), blocks: [], time: 3)
        _ = tracker.advance(page(), scale: scale, time: 4)
        tracker.finishRecognition(try readPage(tracker, at: 5), blocks: [block("Einstellungen", row: 40)], time: 5)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 5), [], "known text needs no new translation")
        XCTAssertEqual(tracker.advance(page(), scale: scale, time: 5.1).placed.map(\.text), ["Settings"])

        tracker.forgetTranslations()
        XCTAssertTrue(tracker.advance(page(), scale: scale, time: 5.2).placed.isEmpty)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 5.2), ["Einstellungen"])
    }

    func testAChangedPictureIsReadAgainAndStaleResultsAreNotShown() throws {
        let tracker = OverlayTracker()
        _ = tracker.advance(page(), scale: scale, time: 0)
        let request = try readPage(tracker, at: 1)
        // the screen changes completely while the pass is running
        let other = page(bars: [300, 340])
        XCTAssertEqual(tracker.advance(other, scale: scale, time: 1.05).change, .changed)
        tracker.finishRecognition(request, blocks: [block("Einstellungen", row: 40)], time: 1.1)
        _ = tracker.textsAwaitingTranslation(limit: 10, time: 1.1)
        tracker.setTranslation("Settings", for: "Einstellungen")
        let update = tracker.advance(other, scale: scale, time: 1.2)
        XCTAssertTrue(update.placed.isEmpty, "text of the old screen must not be drawn onto the new one")
        XCTAssertNotNil(update.recognitionDue, "the new screen must be read")
    }

    func testAbandonedPassIsRepeatedAndResizeForgetsThePicture() throws {
        let tracker = OverlayTracker()
        _ = tracker.advance(page(), scale: scale, time: 0)
        tracker.abandonRecognition(try readPage(tracker, at: 1))
        XCTAssertNotNil(tracker.recognitionDue)
        tracker.finishRecognition(try readPage(tracker, at: 2), blocks: [block("Einstellungen", row: 40)], time: 2)
        _ = tracker.textsAwaitingTranslation(limit: 10, time: 2)
        tracker.setTranslation("Settings", for: "Einstellungen")
        XCTAssertEqual(tracker.advance(page(), scale: scale, time: 2.1).placed.count, 1)

        let rotated = LumaImage(width: height, height: width, fill: 240)
        let update = tracker.advance(rotated, scale: scale, time: 3)
        XCTAssertEqual(update.change, .resized)
        XCTAssertTrue(update.placed.isEmpty)
        XCTAssertTrue(tracker.blocks.isEmpty)
        XCTAssertNotNil(update.recognitionDue)
    }

    func testResetWhileAPassRunsStartsReadingAgain() throws {
        // (the caller drops the pass of a turn that was turned off: it never finishes or abandons it)
        let tracker = OverlayTracker()
        _ = tracker.advance(page(), scale: scale, time: 0)
        let stale = try readPage(tracker, at: 1)
        tracker.reset()

        let update = tracker.advance(page(), scale: scale, time: 2)
        XCTAssertEqual(update.change, .first)
        let due = try XCTUnwrap(update.recognitionDue, "after a reset the picture must be read again")
        let request = try readPage(tracker, at: max(due, 2))
        XCTAssertNotEqual(request, stale)
        XCTAssertTrue(request.isFullFrame)

        // the dropped pass may still come back late: it must change nothing
        tracker.finishRecognition(stale, blocks: [block("Einstellungen", row: 40)], time: 2.1)
        tracker.abandonRecognition(stale)
        XCTAssertTrue(tracker.blocks.isEmpty)
        XCTAssertNil(tracker.beginRecognition(time: 3), "the new pass is still running")
        tracker.finishRecognition(request, blocks: [block("WLAN", row: 120)], time: 3)
        XCTAssertEqual(tracker.blocks.map(\.text), ["WLAN"])
    }

    func testResetForgetsHowTheEarlierScreenLooked() throws {
        let tracker = OverlayTracker()
        // a turn on a light page, with frames the estimator compares
        _ = tracker.advance(page(), scale: scale, time: 0)
        tracker.finishRecognition(try readPage(tracker, at: 1), blocks: [], time: 1)
        _ = tracker.advance(page(bars: [40, 120]), scale: scale, time: 2)
        _ = tracker.advance(page(bars: [40]), scale: scale, time: 3)
        tracker.reset()

        // the next turn, on a dark screen that is read completely and then only flickers by a
        // grey level (link noise)
        let dark = LumaImage(width: width, height: height, fill: 20)
        _ = tracker.advance(dark, scale: scale, time: 10)
        tracker.finishRecognition(try readPage(tracker, at: 11), blocks: [], time: 11)
        var flicker = dark
        flicker[5, 5] = 21
        let update = tracker.advance(flicker, scale: scale, time: 12)
        XCTAssertEqual(update.change, .unchanged, "the screen of the earlier turn is no reference for this one")
        XCTAssertNil(update.recognitionDue, "a picture that was read and did not change is not read again")
    }

    func testThumbnailsAreBoxAverages() {
        let luma: [UInt8] = [0, 10, 20, 30, 99,
                             40, 50, 60, 70, 99,
                             1, 1, 1, 1, 99]
        let small = luma.withUnsafeBytes {
            LumaImage.downsampled(from: $0.baseAddress!, width: 5, height: 3, bytesPerRow: 5, format: .luma8, scale: 2)
        }
        XCTAssertEqual(small, LumaImage(width: 2, height: 1, pixels: [25, 45]))

        // BGRA: (B + 2 G + R) / 4 per pixel
        let bgra: [UInt8] = [10, 20, 30, 255, 100, 100, 100, 255]
        let gray = bgra.withUnsafeBytes {
            LumaImage.downsampled(from: $0.baseAddress!, width: 2, height: 1, bytesPerRow: 8, format: .bgra8, scale: 1)
        }
        XCTAssertEqual(gray.pixels, [20, 100])
        XCTAssertEqual(LumaImage.scale(forFrameWidth: 1170, height: 2532), 3)
        XCTAssertEqual(LumaImage.scale(forFrameWidth: 400, height: 800), 1)
        XCTAssertEqual(LumaImage.scale(forFrameWidth: 2732, height: 2048), 6)
    }

    func testBlockColors() {
        let white = RGBColor(red: 250, green: 250, blue: 250), blue = RGBColor(red: 0, green: 90, blue: 220)
        let dark = RGBColor(red: 20, green: 20, blue: 24)
        var pixels = [RGBColor](repeating: white, count: 80) + [RGBColor](repeating: dark, count: 15)
        pixels += [RGBColor](repeating: RGBColor(red: 130, green: 130, blue: 132), count: 5)   // edges of the strokes
        let onWhite = BlockColors.estimate(pixels: pixels)
        XCTAssertEqual(onWhite.background, white)
        XCTAssertEqual(onWhite.foreground, dark)

        let button = BlockColors.estimate(pixels: [RGBColor](repeating: blue, count: 70) + [RGBColor](repeating: .white, count: 30))
        XCTAssertEqual(button.background, blue)
        XCTAssertEqual(button.foreground, .white)

        let plain = BlockColors.estimate(pixels: [RGBColor](repeating: dark, count: 10))
        XCTAssertEqual(plain.background, dark)
        XCTAssertEqual(plain.foreground, .white, "no second color: readable contrast")
        XCTAssertEqual(BlockColors.estimate(pixels: []), .blackOnWhite)
    }
}
