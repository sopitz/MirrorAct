// SPDX-License-Identifier: GPL-3.0-or-later
import CoreText
import Foundation
import XCTest
@testable import MirrorAct

/// Texts that differ only in their numbers: a summary whose value ticks in place, and the rows of
/// a list that look alike but for a number. No translation is drawn over a text it was not made
/// from: one whose numbers differ from those of the text under it is wrong, however much else the
/// two texts share. The screens are those of a phone 1080 × 2400 (thumbnails at scale 3), as in
/// the lab.
final class OverlayTrackerNumbersTests: XCTestCase {
    typealias Line = OverlayTrackerRestTests.Line
    private static let scale = 3, width = 1080, height = 2400

    /// The thumbnail of a plain page with `lines` (without noise)
    private static func picture(_ lines: [Line]) -> LumaImage {
        var gray = [UInt8](repeating: 245, count: width * height)
        gray.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            for line in lines where line.top + line.height > 0 && line.top < Double(height) {
                line.draw(in: context, frameHeight: height)
            }
        }
        return gray.withUnsafeBytes { bytes in
            LumaImage.downsampled(from: bytes.baseAddress!, width: width, height: height, bytesPerRow: width,
                                  format: .luma8, scale: scale)
        }
    }

    /// Runs the tracker over frames at `times` whose lines `lines(frame)` gives; passes take 0.3 s
    /// and read what the lines showed when they started (`read`); what is asked for is translated
    /// at once ("T " + text), unless `translates` is false. `each` gets the frame's number, its
    /// lines and what was placed. Returns the texts sent for translation.
    @discardableResult
    private func run(_ tracker: OverlayTracker, times: [TimeInterval], seed: UInt64, lines: (Int) -> [Line],
                     read: (Int, Line, CGRect) -> RecognizedBlock? = { _, line, region in line.reading(in: region) },
                     translates: Bool = true, each: (Int, [Line], [PlacedBlock]) -> Void = { _, _, _ in }) -> [String] {
        var sent: [String] = []
        var seed = seed
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        for (frame, time) in times.enumerated() {
            seed += 1
            let shown = lines(frame)
            let picture = SyntheticPage.noisy(Self.picture(shown), amount: 2, seed: seed)
            let placed = tracker.advance(picture, scale: Self.scale, time: time).placed
            each(frame, shown, placed)
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                pending = (request, shown.compactMap { read(frame, $0, request.region) }, time + 0.3)
            }
            guard translates else { continue }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                sent.append(text)
                tracker.setTranslation("T " + text, for: text)
            }
        }
        return sent
    }

    /// A row read at the place of a translated row that looks alike but for its number (the other
    /// row slid there, or a reading of a pass while the list moved was carried there) is another
    /// text: the old row's translation is not shown over it while its own is on the way, though
    /// their words are mostly the same (`TextSimilarity.isRelated`). Text with the same numbers
    /// still shows the old translation meanwhile.
    func testARowReadWithOtherNumbersDoesNotShowTheOldTranslation() {
        XCTAssertTrue(TextSimilarity.hasOtherNumbers("Ordner 12 synchronisieren", "Ordner 23 synchronisieren"))
        XCTAssertTrue(TextSimilarity.hasOtherNumbers("49 % belegt, 79 GB", "50 % belegt, 78 GB frei"))
        XCTAssertFalse(TextSimilarity.hasOtherNumbers("Speicherplatz", "Speicherplatz 41 % belegt"))
        XCTAssertFalse(TextSimilarity.hasOtherNumbers("sind 13 neue Nachrichten", "Seit dem Abgleich sind 13 neue Nachrichten"))
        XCTAssertFalse(TextSimilarity.hasOtherNumbers("Line 2", "Line 2 and what follows"))

        let tracker = OverlayTracker()
        let row = Line(text: "Ordner 12 synchronisieren", top: 800, fontSize: 52)
        var placed: [PlacedBlock] = []
        run(tracker, times: (0..<60).map { Double($0) / 30 }, seed: 3, lines: { _ in [row] }) { _, _, now in
            placed = now
        }
        XCTAssertEqual(placed.map(\.text), ["T " + row.text])
        // (the other row shows at the same place and is read; nothing is translated meanwhile)
        let other = Line(text: "Ordner 23 synchronisieren", top: 800, fontSize: 52)
        run(tracker, times: (60..<120).map { Double($0) / 30 }, seed: 99, lines: { _ in [other] }, translates: false)
        XCTAssertEqual(tracker.blocks.map(\.text), [other.text])
        XCTAssertEqual(tracker.blocks.map(\.translation), [nil])
    }
}
