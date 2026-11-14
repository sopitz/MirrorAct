// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import MirrorAct

/// A value that changes in its line on a still page (a storage summary, "49 % belegt, 79 GB
/// frei") is a change in place: the line is read and translated again at every change, for as
/// long as it changes.
final class OverlayTrackerValueTickTests: XCTestCase {
    private static let scale = 3

    /// A thumbnail of the lab's phone showing a test page with a value that ticks every three
    /// seconds (`Frames/ValueTick/<number>.png`, 360 × 800, grey, as the app made them)
    private func thumbnail(_ number: Int) throws -> LumaImage {
        let name = String(format: "%03d", number)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "png"), "frame \(name)")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return LumaImage(width: image.width, height: image.height, pixels: pixels)
    }

    /// The frames, and the summary under the title "Speicherplatz" in each, as Vision read the
    /// thumbnail (thumbnail pixels): 49 %, the tick to 50 %, 48 % (later in the cycle), the tick
    /// to 49 % and the tick to 50 %
    private static let frames: [(number: Int, summary: String, box: CGRect)] = [
        (29, "49 % belegt, 79 GB frei", CGRect(x: 18, y: 486, width: 140, height: 16)),
        (30, "50 % belegt, 78 GB frei", CGRect(x: 18, y: 486, width: 140, height: 16)),
        (149, "48 % belegt, 80 GB frei", CGRect(x: 16, y: 486, width: 142, height: 16)),
        (150, "49 % belegt, 79 GB frei", CGRect(x: 18, y: 486, width: 140, height: 16)),
        (173, "50 % belegt, 78 GB frei", CGRect(x: 18, y: 486, width: 140, height: 16)),
    ]
    private static let title = ("Speicherplatz", CGRect(x: 16, y: 454, width: 112, height: 20))

    /// What Vision reads of the lines in `region` (frame pixels): a line of which the region holds
    /// nine tenths of the height, as far as its letters reach into the region (by their share of
    /// its width)
    private static func recognize(_ lines: [(String, CGRect)], in region: CGRect) -> [RecognizedBlock] {
        var blocks: [RecognizedBlock] = []
        let factor = Double(scale)
        for (text, thumbnailBox) in lines {
            let box = CGRect(x: thumbnailBox.minX * factor, y: thumbnailBox.minY * factor,
                             width: thumbnailBox.width * factor, height: thumbnailBox.height * factor)
            let part = box.intersection(region)
            guard !part.isNull, part.height >= 0.9 * box.height, part.width >= 0.1 * box.width else { continue }
            let letters = Array(text)
            let from = Int(((part.minX - box.minX) / box.width * Double(letters.count)).rounded(.up))
            let to = Int(((part.maxX - box.minX) / box.width * Double(letters.count)).rounded(.down))
            guard to > from else { continue }
            let shown = String(letters[from..<to]).trimmingCharacters(in: .whitespaces)
            guard !shown.isEmpty else { continue }
            blocks.append(RecognizedBlock(text: shown, rect: CGRect(x: part.minX, y: box.minY, width: part.width,
                                                                    height: box.height)))
        }
        return blocks
    }

    /// The tick from 49 to 50 % changes the strokes of the digits and nothing else in the line.
    /// Before, the estimator took it for the line moving by a twelfth of a pixel (6 tiles), and
    /// a later tick (48 to 49 %) for that line moving again with its top edge found inside the
    /// line: neither is a movement.
    func testDigitsThatChangeInTheirLineAreNoMovement() throws {
        let estimator = MotionEstimator(configuration: OverlayTracker.Configuration())
        for (before, after) in [(29, 30), (149, 150), (150, 173)] {
            XCTAssertTrue(estimator.analyze(previous: try thumbnail(before), current: try thumbnail(after), priors: []))
            XCTAssertEqual(estimator.motions, [], "frames \(before) to \(after)")
            XCTAssertGreaterThan(estimator.changedTiles, 0, "frames \(before) to \(after): the digits changed")
        }
    }

    /// A line of text that really moves by less than a pixel, from rest (a ticker that starts,
    /// the last frames of a slow drag), is still found as a movement
    func testALineThatReallyMovesByLessThanAPixelIsAMovement() throws {
        let still = try thumbnail(29)
        for step in [0.5, 0.75] {
            // the summary's line, moved to the right by `step` (each pixel between two of the frame)
            var pixels = still.pixels
            for y in 480..<506 {
                for x in 8..<172 {
                    let here = Double(still[x, y]), left = Double(still[x - 1, y])
                    pixels[y * still.width + x] = UInt8((here * (1 - step) + left * step).rounded())
                }
            }
            let moved = LumaImage(width: still.width, height: still.height, pixels: pixels)
            let estimator = MotionEstimator(configuration: OverlayTracker.Configuration())
            XCTAssertTrue(estimator.analyze(previous: still, current: moved, priors: []))
            XCTAssertEqual(estimator.motions.count, 1, "step \(step)")
            XCTAssertEqual(estimator.motions.first?.dx ?? 0, step, accuracy: 0.25, "step \(step)")
        }
    }

    /// The page stands still and the summary ticks: it is translated anew at every value. Before,
    /// the tick to 50 % made a scrolling area of the line, the tick to 49 % gave that area a top
    /// edge inside the line, and every reading of the line at rest counted as cut there: the
    /// summary stayed untranslated for as long as the page stood (in the lab, in every run).
    func testAValueThatTicksInItsLineIsTranslatedAtEveryValue() throws {
        let tracker = OverlayTracker()
        var pending: (request: RecognitionRequest, blocks: [RecognizedBlock], at: TimeInterval)?
        var time = 0.0
        for (index, frame) in Self.frames.enumerated() {
            let picture = try thumbnail(frame.number)
            let lines = [Self.title, (frame.summary, frame.box)]
            var drawnAt: TimeInterval?
            let end = time + 3
            while time < end {
                let placed = tracker.advance(picture, scale: Self.scale, time: time).placed
                if drawnAt == nil, placed.contains(where: { $0.text == "T " + frame.summary }) { drawnAt = time }
                if let job = pending, time >= job.at {
                    tracker.finishRecognition(job.request, blocks: job.blocks, time: time)
                    pending = nil
                }
                if pending == nil, let due = tracker.recognitionDue, due <= time,
                   let request = tracker.beginRecognition(time: time) {
                    pending = (request, Self.recognize(lines, in: request.region), time + 0.08)
                }
                for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                    tracker.setTranslation("T " + text, for: text)
                }
                time += 1.0 / 60
            }
            XCTAssertNotNil(drawnAt, "frame \(index + 1): '\(frame.summary)' translated")
            XCTAssertEqual(tracker.scrollingAreas, [], "frame \(index + 1): nothing moved")
        }
        XCTAssertNil(tracker.recognitionDue, "the reading stops on the still page")
    }
}
