// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// What the tracker does with readings that may be cut off by a bar that stays (Android's
/// translucent navigation bar, a title bar) on a still screen: a paragraph held back for a line
/// next to it, and a line that only may be cut off, are translated once the picture rests and
/// their place was read again; a line that is garbage beyond doubt never is. The lines are those
/// Vision read on the lab's page on an Android phone (1080 × 2400).
final class OverlayTrackerCutOffTests: XCTestCase {
    private let phone = CGSize(width: 1080, height: 2400)

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                      confidence: Double? = nil) -> RecognizedLine {
        RecognizedLine(text: text, rect: CGRect(x: x / phone.width, y: y / phone.height,
                                                width: width / phone.width, height: height / phone.height),
                       confidence: confidence)
    }

    /// The texts the tracker asked to translate while a still picture of `lines` was shown for
    /// `seconds` at 30 frames per second, every pass answered with the paragraphs `TextLayout`
    /// makes of the lines inside its region (translations come back at once), and how many passes
    /// it asked for
    private func translate(_ lines: [RecognizedLine], seconds: Double = 10) -> (texts: [String], passes: Int) {
        // the picture: a light page with a texture where the lines are, reduced by 3
        let scale = 3
        var page = LumaImage(width: Int(phone.width) / scale, height: Int(phone.height) / scale, fill: 240)
        for line in lines {
            let rect = CGRect(x: line.rect.minX * phone.width / CGFloat(scale), y: line.rect.minY * phone.height / CGFloat(scale),
                              width: line.rect.width * phone.width / CGFloat(scale),
                              height: line.rect.height * phone.height / CGFloat(scale))
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) where (x / 3 + y / 5) % 2 == 0 { page[x, y] = 40 }
            }
        }
        let tracker = OverlayTracker()
        var texts: [String] = []
        var passes = 0
        for frame in 0..<Int(seconds * 30) {
            let time = Double(frame) / 30
            _ = tracker.advance(page, scale: scale, time: time)
            guard let due = tracker.recognitionDue, due <= time, let request = tracker.beginRecognition(time: time) else {
                continue
            }
            passes += 1
            let region = request.region
            let inside = lines.filter { line in
                region.contains(CGRect(x: line.rect.minX * phone.width, y: line.rect.minY * phone.height,
                                       width: line.rect.width * phone.width, height: line.rect.height * phone.height))
            }
            let blocks = TextLayout.blocks(TextLayout.content(inside, imageSize: phone), imageSize: phone)
                .filter { TextLayout.isTranslatable($0.text) }
                .map { block in
                    RecognizedBlock(text: block.text, rect: CGRect(x: block.rect.minX * phone.width,
                                                                   y: block.rect.minY * phone.height,
                                                                   width: block.rect.width * phone.width,
                                                                   height: block.rect.height * phone.height),
                                    lineCount: block.lineCount, confidence: block.confidence,
                                    cutOffEdges: block.cutOffEdges, isGarbled: block.isGarbled)
                }
            tracker.finishRecognition(request, blocks: blocks, time: time + 0.02)
            let asked = tracker.textsAwaitingTranslation(limit: 40, time: time + 0.03)
            for text in asked {
                tracker.setTranslation("T:" + text, for: text)
            }
            texts += asked
        }
        return (texts, passes)
    }

    /// The last line on the screen is cut in half by the navigation bar and read as garbage; the
    /// paragraph above it is held back for it at first, and translated once the place was read
    /// again at rest. The garbage never is, and the screen is not read on and on.
    func testAParagraphNextToAGarbledLineIsTranslatedAtRest() {
        let lines = [
            line("Une recette simple", 52, 2138, 512, 63),
            line("Faites fondre le beurre dans une poêle, ajoutez", 52, 2250, 975, 52),
            line("lan dianana aalinán an finan lamallan at", 45, 2316, 829, 28),
        ]
        let result = translate(lines)
        XCTAssertEqual(result.texts.sorted(), ["Faites fondre le beurre dans une poêle, ajoutez", "Une recette simple"])
        XCTAssertLessThanOrEqual(result.passes, 4)
    }

    /// The lower part of the last line is hidden by the bar; Vision read the rest nearly right, in
    /// a box two thirds as high as the line above. Reported with a confidence of 0.5 it is garbage
    /// and never translated; the paragraph is. From the box alone (a recognizer that reports no
    /// confidence, or one sure of it) it may only be cut off: it is translated once the picture
    /// rests, as it shows.
    func testAPartOfALineIsTranslatedAtRestUnlessItIsGarbage() {
        let paragraph = "Zum Schluss noch ein langer Absatz, damit die Seite weit genug nach unten reicht. Beim "
            + "Scrollen sollen die Übersetzungen auf ihrem Text bleiben und nicht zittern, springen oder"
        func lines(_ confidence: Double?) -> [RecognizedLine] {
            [
                line("Zum Schluss noch ein langer Absatz, damit", 49, 2037, 909, 53, confidence: confidence),
                line("die Seite weit genug nach unten reicht. Beim", 52, 2103, 923, 53, confidence: confidence),
                line("Scrollen sollen die Übersetzungen auf ihrem", 52, 2162, 917, 64, confidence: confidence),
                line("Text bleiben und nicht zittern, springen oder", 52, 2243, 916, 49, confidence: confidence),
                line("an ainer alten Stalle ctahen hlaihen menn der", 49, 2309, 948, 32, confidence: confidence),
            ]
        }
        XCTAssertEqual(translate(lines(0.5)).texts, [paragraph])
        XCTAssertEqual(translate(lines(nil)).texts.sorted(), [paragraph, "an ainer alten Stalle ctahen hlaihen menn der"].sorted())
    }

    /// Complete lines in wide type right above the bottom edge (Menlo, letter-spaced Helvetica
    /// Bold): their boxes are low for the size measured from their width, so they are held back
    /// at first, but they are translated on a still screen
    func testCompleteLinesInWideTypeAreTranslatedAtRest() {
        let lines = [
            line("Bitte Licht still stellen", 59, 1207, 599, 35, confidence: 1),
            line("Fill in the title field", 59, 2313, 554, 38, confidence: 1),
            line("Hilfe", 700, 2330, 146, 38, confidence: 0.5),
        ]
        XCTAssertEqual(translate(lines).texts.sorted(), ["Bitte Licht still stellen", "Fill in the title field", "Hilfe"])
    }

    /// What Vision reads in the status bar (the clock, icons read as letters) is not translated
    func testTheStatusBarIsNotTranslated() {
        let lines = [
            line("7:22 kg", 40, 16, 150, 34, confidence: 0.5),
            line("VAD", 894, 16, 114, 34, confidence: 0.3),
            line("< Testlabor", 41, 103, 377, 66, confidence: 1),
        ]
        XCTAssertEqual(translate(lines).texts, ["< Testlabor"])
    }
}
