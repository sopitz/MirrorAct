// SPDX-License-Identifier: GPL-3.0-or-later
import CoreText
import Foundation
import XCTest
@testable import MirrorAct

/// A countdown of one line that ticks once a second on a still page, right under a text field
/// (the lab's page counter-caret.html: "Noch NN Sekunden bis zur Abfahrt", 20 down to 1 and
/// round again). No frame shows a translation with a number that the screen does not show, the
/// line is read whole again at every value (one pass a tick), and once it stops it is translated
/// and stays so. Screens of a phone 1080 × 2400 (thumbnails at scale 3), as in the lab.
final class OverlayTrackerCountdownTests: XCTestCase {
    typealias Line = OverlayTrackerRestTests.Line
    private static let scale = 3, width = 1080, height = 2400

    /// The page: what lies above the countdown, the countdown and what lies below it
    private struct Page {
        /// the countdown 40 CSS pixels lower, under a line of its own (counter-gap.html)
        var gap = false
        /// the field has the focus: its caret blinks after its text
        var caret = true
        /// the recognizer joins the field's text and the countdown into one paragraph of two lines
        /// (as `TextLayout` did on the phone in two runs of five)
        var joined = false

        static let title = Line(text: "Suche im Katalog", top: 315, fontSize: 64, left: 52)
        static let fieldText = Line(text: "Wasserkocher", top: 518, fontSize: 58, left: 77, fontName: "Helvetica")
        /// the field's frame: a line of 3 pixels, grey 146 (frame pixels)
        static let field = CGRect(x: 53, y: 437, width: 878, height: 208)
        static let caret = CGRect(x: 452, y: 512, width: 4, height: 66)

        var shift: Double { gap ? 180 : 0 }

        func countdown(_ value: Int) -> Line {
            Line(text: "Noch \(value) Sekunden bis zur Abfahrt", top: 686 + shift, fontSize: 52, left: 55,
                 fontName: "Helvetica")
        }

        /// the lines below the countdown: a paragraph of two lines, a heading and a paragraph
        var below: [Line] {
            var lines: [Line] = []
            if gap {
                lines.append(Line(text: "Geben Sie oben ein Wort ein.", top: 690, fontSize: 46, left: 52,
                                  fontName: "Helvetica"))
            }
            lines.append(Line(text: "Geben Sie oben ein Wort ein, nach dem", top: 787 + shift, fontSize: 46, left: 52,
                              fontName: "Helvetica"))
            lines.append(Line(text: "gesucht werden soll.", top: 857 + shift, fontSize: 46, left: 52, fontName: "Helvetica"))
            lines.append(Line(text: "Ein ruhiger Absatz", top: 993 + shift, fontSize: 56, left: 52))
            return lines
        }
    }

    private var pictures: [String: LumaImage] = [:]

    /// The thumbnail of the page showing `value`, with or without the caret (no noise)
    private func picture(_ page: Page, value: Int, caretOn: Bool) -> LumaImage {
        let key = "\(page.gap) \(value) \(caretOn)"
        if let known = pictures[key] { return known }
        var gray = [UInt8](repeating: 255, count: Self.width * Self.height)
        gray.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: Self.width, height: Self.height,
                                          bitsPerComponent: 8, bytesPerRow: Self.width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            for line in [Page.title, Page.fieldText, page.countdown(value)] + page.below {
                line.draw(in: context, frameHeight: Self.height)
            }
            func flipped(_ rect: CGRect) -> CGRect {
                CGRect(x: rect.minX, y: Double(Self.height) - rect.maxY, width: rect.width, height: rect.height)
            }
            context.setStrokeColor(CGColor(gray: 146 / 255, alpha: 1))
            context.setLineWidth(3)
            context.stroke(flipped(Page.field).insetBy(dx: 1.5, dy: 1.5))
            if caretOn {
                context.setFillColor(CGColor(gray: 0.1, alpha: 1))
                context.fill(flipped(Page.caret))
            }
        }
        let image = gray.withUnsafeBytes { bytes in
            LumaImage.downsampled(from: bytes.baseAddress!, width: Self.width, height: Self.height, bytesPerRow: Self.width,
                                  format: .luma8, scale: Self.scale)
        }
        if pictures.count > 96 { pictures = [:] }
        pictures[key] = image
        return image
    }

    /// What the recognizer reads of the page in `region` (frame pixels): each line as far as it
    /// lies in it (`Line.reading`), the two lines of the paragraph below as one block, and with
    /// `Page.joined` the field's text and the countdown as one block of two lines when both were
    /// read whole
    private static func readings(_ page: Page, value: Int, in region: CGRect) -> [RecognizedBlock] {
        var result: [RecognizedBlock] = []
        for line in [Page.title] { if let reading = line.reading(in: region) { result.append(reading) } }
        let field = Page.fieldText.reading(in: region), countdown = page.countdown(value).reading(in: region)
        if page.joined, let field, let countdown, field.text == Page.fieldText.text,
           countdown.text == page.countdown(value).text {
            result.append(RecognizedBlock(text: field.text + " " + countdown.text, rect: field.rect.union(countdown.rect),
                                          lineCount: 2))
        } else {
            result += [field, countdown].compactMap { $0 }
        }
        let below = page.below.compactMap { $0.reading(in: region) }
        var paragraph: [RecognizedBlock] = []
        for reading in below {
            if reading.text.hasPrefix("Geben Sie oben ein Wort ein,") || reading.text.hasPrefix("gesucht") {
                paragraph.append(reading)
            } else {
                result.append(reading)
            }
        }
        if let first = paragraph.first {
            result.append(RecognizedBlock(text: paragraph.map(\.text).joined(separator: " "),
                                          rect: paragraph.dropFirst().reduce(first.rect) { $0.union($1.rect) },
                                          lineCount: paragraph.count))
        }
        return result
    }

    /// What a run showed of the countdown line, frame by frame
    struct Outcome {
        /// frames that show a translation of it with its number, with another number, none
        var right = 0, wrong = 0, untranslated = 0
        var wrongExamples: [String] = []
        /// values shown (each for its second) of which a frame drew the translation
        var valuesDrawn = 0, values = 0
        /// passes begun while it ticked, and while it stood still after
        var passesTicking = 0, passesStill = 0
        /// texts of it sent while it ticked
        var sentTicking: [String] = []
        /// when the stopped value was first drawn after the stop (nil: never), and frames after
        /// that without it
        var drawnAfterStop: Double?
        var missingAfterDrawn = 0
    }

    /// Shows `page` for `ticking` seconds with the countdown ticking from `first` once a second
    /// (20 after 1), then `still` seconds on its last value, at `fps`; passes take `passTime` and
    /// read the frame they began on; what is asked for is translated at once ("T " + text).
    /// Counts from `from` on.
    private func run(_ page: Page, first: Int = 16, ticking: Double, still: Double, fps: Double = 30,
                     passTime: Double = 0.3, from: Double = 2,
                     configuration: OverlayTracker.Configuration = OverlayTracker.Configuration(),
                     alter: (TimeInterval, [RecognizedBlock]) -> [RecognizedBlock] = { $1 }) -> Outcome {
        let tracker = OverlayTracker(configuration: configuration)
        var outcome = Outcome()
        var seed: UInt64 = 11
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        func value(_ time: TimeInterval) -> Int {
            let ticks = Int(min(time, ticking - 0.001))
            return (first - 1 - ticks % 20 + 20) % 20 + 1
        }
        var lastValue = -1, drawnThisValue = false
        var frame = 0
        while true {
            let time = Double(frame) / fps
            guard time < ticking + still else { break }
            frame += 1
            seed += 1
            let shown = value(time)
            let caretOn = page.caret && Int(time / 0.5) % 2 == 0
            let image = SyntheticPage.noisy(picture(page, value: shown, caretOn: caretOn), amount: 2, seed: seed)
            let placed = tracker.advance(image, scale: Self.scale, time: time).placed
            if time >= from {
                let text = page.countdown(shown).text
                let over = placed.filter { $0.text.hasPrefix("T ") && $0.text.contains("Sekunden") }
                if over.isEmpty {
                    outcome.untranslated += 1
                } else if over.allSatisfy({ TextSimilarity.numbers(of: $0.text) == TextSimilarity.numbers(of: text) }) {
                    outcome.right += 1
                } else {
                    outcome.wrong += 1
                    if outcome.wrongExamples.count < 4 {
                        outcome.wrongExamples.append(String(format: "%.2f s: ", time)
                            + over.map(\.text).joined(separator: " / ") + " over " + text)
                    }
                }
                let isRight = !over.isEmpty && over.allSatisfy { TextSimilarity.numbers(of: $0.text) == TextSimilarity.numbers(of: text) }
                if time < ticking {
                    if shown != lastValue {
                        if lastValue >= 0 {
                            outcome.values += 1
                            if drawnThisValue { outcome.valuesDrawn += 1 }
                        }
                        lastValue = shown
                        drawnThisValue = false
                    }
                    if isRight { drawnThisValue = true }
                } else if outcome.drawnAfterStop == nil {
                    if isRight { outcome.drawnAfterStop = time - ticking }
                } else if !isRight {
                    outcome.missingAfterDrawn += 1
                }
            }
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                if time >= from { if time < ticking { outcome.passesTicking += 1 } else { outcome.passesStill += 1 } }
                pending = (request, alter(time, Self.readings(page, value: shown, in: request.region)), time + passTime)
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                if time >= from, time < ticking, text.contains("Sekunden") { outcome.sentTicking.append(text) }
                tracker.setTranslation("T " + text, for: text)
            }
        }
        return outcome
    }

    private func describe(_ outcome: Outcome) -> String {
        "right \(outcome.right) wrong \(outcome.wrong) untranslated \(outcome.untranslated); values drawn "
            + "\(outcome.valuesDrawn) of \(outcome.values); passes \(outcome.passesTicking) ticking, "
            + "\(outcome.passesStill) still; sent \(outcome.sentTicking.count); drawn after stop "
            + (outcome.drawnAfterStop.map { String(format: "%.2f s", $0) } ?? "never")
            + ", missing after \(outcome.missingAfterDrawn); \(outcome.wrongExamples)"
    }

    // MARK: Tests

    /// The settings of a run: a release build plays the countdown from 16 for 45 s at 30 frames a
    /// second and 8 s still after it; a debug build from 12 for 14 s at 10 frames a second (the
    /// ticks 11 to 10, 10 to 9 and 1 to 20 included, where the line changes its width) and 3 s
    /// still (`TestBuild`)
    private static var everything: Bool { TestBuild.playsEverything }
    private static var first: Int { everything ? 16 : 12 }
    private static var ticking: Double { everything ? 45 : 14 }
    private static var still: Double { everything ? 8 : 3 }
    private static var fps: Double { everything ? 30 : 10 }

    private func check(_ outcome: Outcome, _ name: String, passesPerValue: Double, drawnShare: Int = 8) {
        XCTAssertEqual(outcome.wrong, 0, "\(name): \(outcome.wrongExamples)")
        XCTAssertGreaterThanOrEqual(outcome.valuesDrawn * 10, outcome.values * drawnShare, "\(name): \(describe(outcome))")
        XCTAssertLessThanOrEqual(Double(outcome.passesTicking), passesPerValue * Double(outcome.values) + 2,
                                 "\(name): \(describe(outcome))")
        XCTAssertLessThanOrEqual(outcome.drawnAfterStop ?? .infinity, 1.5, "\(name): \(describe(outcome))")
        XCTAssertEqual(outcome.missingAfterDrawn, 0, "\(name): \(describe(outcome))")
    }

    /// The countdown as a line of its own under the field, close to it or 40 CSS pixels lower:
    /// where its number changes its width (11 to 10, 10 to 9, 1 to 20), the rest of the line
    /// moves sideways. `MotionEstimator` takes that for a movement of a part of the line, its
    /// block is carried with it and not found: lost. The change at the next tick is read with
    /// the whole line the lost block lay on (`addChangedAreas`), as with a block that is found.
    /// No frame shows another number, at least eight values in ten are drawn, about one pass a
    /// value, and the last one within 1.5 s once it stops. (Before, the line rule needed a
    /// block that was found: the changes were read around the digits only, the cut readings
    /// asked a little more each time, and that place lay across the edge of the scrolling area
    /// the sideways step had made, so it was never due: the line stayed untranslated until a
    /// tick that changed its width again, 22 values of 42 drawn.)
    func testACountdownWhoseNumberChangesItsWidthIsReadAtEveryValue() {
        let cases: [(String, Page)] = Self.everything
            ? [("no focus", Page(caret: false)), ("gap", Page(gap: true))]
            : [("no focus", Page(caret: false))]
        for (name, page) in cases {
            let outcome = run(page, first: Self.first, ticking: Self.ticking, still: Self.still, fps: Self.fps)
            print("COUNTDOWN \(name): \(describe(outcome))")
            // (with the caret: its two pictures, read at the first blinks)
            check(outcome, name, passesPerValue: page.caret ? 2 : 1.5)
        }
    }
}
