// SPDX-License-Identifier: GPL-3.0-or-later
import CoreText
import Foundation
import XCTest
@testable import MirrorAct

/// What changes in place is read at once: a change in a line is read with the whole line, and
/// text typed into a field is translated as soon as it shows. Screens of a phone 1080 × 2400
/// (thumbnails at scale 3), as in the lab.
final class OverlayTrackerChangingTests: XCTestCase {
    typealias Line = OverlayTrackerRestTests.Line
    private static let scale = 3, width = 1080, height = 2400

    /// What a frame shows: lines, carets (frame pixels, filled dark) and bars (thumbnail pixels,
    /// filled dark after the reduction)
    private struct Scene {
        var lines: [Line]
        var carets: [CGRect] = []
        var bars: [ThumbnailRect] = []

        var key: String {
            lines.map { "\($0.text)@\($0.top),\($0.left),\($0.fontSize)" }.joined(separator: "|")
                + carets.map { "c\($0)" }.joined()
        }
    }

    private var pictures: [String: LumaImage] = [:]

    /// The thumbnail of a scene, without noise
    private func picture(_ scene: Scene) -> LumaImage {
        let key = scene.key
        var base: LumaImage
        if let known = pictures[key] {
            base = known
        } else {
            var gray = [UInt8](repeating: 245, count: Self.width * Self.height)
            gray.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: Self.width, height: Self.height,
                                              bitsPerComponent: 8, bytesPerRow: Self.width,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                for line in scene.lines {
                    line.draw(in: context, frameHeight: Self.height)
                }
                context.setFillColor(CGColor(gray: 0.1, alpha: 1))
                for caret in scene.carets {
                    context.fill(CGRect(x: caret.minX, y: Double(Self.height) - caret.maxY, width: caret.width,
                                        height: caret.height))
                }
            }
            base = gray.withUnsafeBytes { bytes in
                LumaImage.downsampled(from: bytes.baseAddress!, width: Self.width, height: Self.height,
                                      bytesPerRow: Self.width, format: .luma8, scale: Self.scale)
            }
            if pictures.count > 64 { pictures = [:] }
            pictures[key] = base
        }
        for bar in scene.bars {
            for y in bar.y..<bar.maxY {
                for x in bar.x..<bar.maxX {
                    base[x, y] = 60
                }
            }
        }
        return base
    }

    private struct Run {
        /// when each pass began
        var passes: [TimeInterval] = []
        var sent: [String] = []
        func passes(from start: TimeInterval, to end: TimeInterval) -> Int {
            passes.filter { $0 >= start && $0 < end }.count
        }
    }

    /// Shows `scene(time)` at `fps` from `start` for `seconds`; passes take 0.3 s and read the
    /// lines of the frame they began on in their region; what is asked for is translated at once
    /// ("T " + text; a text without letters comes back as it is, as from a translator: nothing
    /// to show). `each` gets every frame's time and the texts drawn into it.
    private func run(_ tracker: OverlayTracker, from start: TimeInterval, seconds: Double, fps: Double = 30,
                     seed: inout UInt64, scene: (TimeInterval) -> Scene,
                     each: (TimeInterval, [String]) -> Void = { _, _ in },
                     begun: (CGRect) -> Void = { _ in }) -> Run {
        var result = Run()
        var pending: (request: RecognitionRequest, answer: [RecognizedBlock], at: TimeInterval)?
        var frame = 0
        while true {
            let time = start + Double(frame) / fps
            guard time < start + seconds else { break }
            frame += 1
            seed += 1
            let shown = scene(time)
            let image = SyntheticPage.noisy(picture(shown), amount: 2, seed: seed)
            let placed = tracker.advance(image, scale: Self.scale, time: time).placed.map(\.text)
            each(time, placed)
            if let job = pending, time >= job.at {
                tracker.finishRecognition(job.request, blocks: job.answer, time: time)
                pending = nil
            }
            if pending == nil, let due = tracker.recognitionDue, due <= time,
               let request = tracker.beginRecognition(time: time) {
                result.passes.append(time)
                begun(request.region)
                pending = (request, shown.lines.compactMap { $0.reading(in: request.region) }, time + 0.3)
            }
            for text in tracker.textsAwaitingTranslation(limit: 50, time: time) {
                result.sent.append(text)
                tracker.setTranslation(text.contains(where: \.isLetter) ? "T " + text : text, for: text)
            }
        }
        return result
    }

    // MARK: Scenes

    private static let heading = Line(text: "Wasserkocher bestellen", top: 600, fontSize: 63)
    private static let note = Line(text: "Die Lieferung dauert drei Tage", top: 1500, fontSize: 42,
                                   fontName: "Helvetica")

    /// The text of a field and its caret, 4 pixels wide, 2 pixels after the text
    private static func field(_ text: String) -> (line: Line, caret: CGRect) {
        let line = Line(text: text, top: 1000, fontSize: 48, fontName: "Helvetica")
        let font = CTFontCreateWithName(line.fontName as CFString, line.fontSize, nil)
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font]))
        let end = line.left + Double(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        return (line, CGRect(x: end + 2, y: line.top - 4, width: 4, height: line.height + 8))
    }

    // MARK: What is read at once

    /// For each (time, text): how long after that time the translation of `text` was first
    /// drawn (nil = never), with `scene` shown from 0 to `seconds`
    private func delays(_ configuration: OverlayTracker.Configuration, seconds: Double,
                        scene: (TimeInterval) -> Scene, checks: [(time: TimeInterval, text: String)]) -> [Double?] {
        var seed: UInt64 = 3
        var result = [Double?](repeating: nil, count: checks.count)
        _ = run(OverlayTracker(configuration: configuration), from: 0, seconds: seconds, seed: &seed,
                scene: scene) { time, placed in
            for (index, check) in checks.enumerated() where result[index] == nil && time >= check.time
                && placed.contains("T " + check.text) {
                result[index] = time - check.time
            }
        }
        return result
    }

    /// A word typed at once at the end of a field's text (no caret on the page): the change is
    /// read with the whole line, and the new text is translated within a second. Read with only
    /// the room around the change, the line was cut on the left, read again a little farther
    /// each time, and translated after 1.5 s, by the fifth pass.
    func testAWordTypedAtTheEndOfALineIsReadWithItsLine() {
        func scene(_ time: TimeInterval) -> Scene {
            let text = time < 4 ? "Wasserkocher" : "Wasserkocher Kanne"
            let counter = Line(text: "Noch \(40 - text.count) Zeichen", top: 1090, fontSize: 36, fontName: "Helvetica")
            return Scene(lines: [Self.heading, Self.field(text).line, counter, Self.note])
        }
        var regions: [CGRect] = []
        var seed: UInt64 = 3
        var drawn: TimeInterval?
        let tracker = OverlayTracker()
        let result = run(tracker, from: 0, seconds: 7, seed: &seed, scene: scene) { time, placed in
            if drawn == nil, placed.contains("T Wasserkocher Kanne") { drawn = time }
        } begun: { regions.append($0) }
        print("CHANGING word: drawn \(drawn.map { $0 - 4 } ?? -1) passes \(result.passes.filter { $0 >= 4 })")
        XCTAssertLessThan((drawn ?? .infinity) - 4, 1)
        XCTAssertEqual(result.sent.filter { $0.hasPrefix("Wasserkocher") && $0 != Self.heading.text }, ["Wasserkocher", "Wasserkocher Kanne"])
        XCTAssertLessThanOrEqual(result.passes(from: 4, to: 7), 2, "\(regions)")
    }

    /// A line with a mark at its end that changes in every frame (an animation that never comes
    /// to rest): when the line's text changes, it is translated within a second, as before the
    /// line was read whole with a change in it
    func testATextBesideAnAnimationIsTranslatedWithinASecond() {
        func scene(_ time: TimeInterval) -> Scene {
            let field = Self.field(time < 4 ? "Wird geladen" : "Wird gesichert")
            let step = Int((time * 30).rounded()) % 8
            let mark = CGRect(x: field.caret.minX + 20 + Double(step) * 4, y: field.caret.minY + 8, width: 6, height: 30)
            return Scene(lines: [Self.heading, field.line, Self.note], carets: [mark])
        }
        let delay = delays(OverlayTracker.Configuration(), seconds: 7, scene: scene, checks: [(4, "Wird gesichert")])
        print("CHANGING animation: \(delay)")
        XCTAssertLessThan(delay[0] ?? .infinity, 1)
    }
}
