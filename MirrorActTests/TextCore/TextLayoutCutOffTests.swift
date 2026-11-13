// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Lines cut off by a bar: which are garbage beyond doubt (never translated, not copied), which
/// only may be cut off (translated once the picture rests), and which are complete. The lines are
/// what Vision read, boxes and confidences to the tenth of a pixel: on pages drawn the way iOS
/// and Android draw them (system fonts, a tab bar that hides the lower part of a line, opaque or
/// translucent), on lines drawn in wide type, and on an Android phone.
final class TextLayoutCutOffTests: XCTestCase {
    private let iPhone = CGSize(width: 1170, height: 2532)
    private let iPhoneIsland = CGSize(width: 1290, height: 2796)
    private let iPad = CGSize(width: 1640, height: 2360)
    private let android = CGSize(width: 1080, height: 2400)

    /// A line as Vision gave it: left, top, width and height in pixels of a picture of `size`
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                      confidence: Double? = nil, in size: CGSize) -> RecognizedLine {
        RecognizedLine(text: text, rect: CGRect(x: x / size.width, y: y / size.height, width: width / size.width,
                                                height: height / size.height), confidence: confidence)
    }

    private func block(_ text: String, in blocks: [TextBlock], file: StaticString = #filePath,
                       line: UInt = #line) throws -> TextBlock {
        try XCTUnwrap(blocks.first { $0.text == text }, "no block \(text)", file: file, line: line)
    }

    /// iPhone, SF 17 pt: the translucent tab bar (249 pixels high) hides the lower 65 % of the
    /// first line of a paragraph, 239 pixels above the bottom edge. Its box is half as high as
    /// its text size, and the line above it belongs to another paragraph.
    func testALineUnderATabBarOfIOSIsGarbage() throws {
        let lines = [
            line("Eintrittskarten. Biegen Sie an der zweiten Ampel", 47.8, 2035.0, 986.0, 48.0, confidence: 1, in: iPhone),
            line("links ab und folgen Sie den Schildern zum Bahnhof.", 44.2, 2097.7, 1055.9, 48.3, confidence: 1,
                 in: iPhone),
            line("Übrigens lassen", 47.7, 2155.7, 327.7, 53.4, confidence: 1, in: iPhone),
            line("Nialiafamia darrant inanhall Nartaablandaia dae", 51.5, 2267.0, 1041.2, 26.0, confidence: 0.3, in: iPhone),
            line("Start", 80.9, 2388.5, 73.6, 22.1, confidence: 1, in: iPhone),
            line("Suche", 305.1, 2387.6, 92.5, 27.5, confidence: 1, in: iPhone),
        ]
        let blocks = TextLayout.blocks(lines, imageSize: iPhone)
        let garbage = try block("Nialiafamia darrant inanhall Nartaablandaia dae", in: blocks)
        XCTAssertTrue(garbage.isGarbled)
        XCTAssertEqual(garbage.cutOffEdges, FrameMotion.top | FrameMotion.bottom)
        XCTAssertEqual(blocks.filter(\.isGarbled).count, 1)
        // the tab labels below it are complete
        XCTAssertEqual(try block("Start", in: blocks).cutOffEdges, 0)
        let text = TextLayout.plainText(lines, imageSize: iPhone)
        XCTAssertFalse(text.contains("Nialiafamia"))
        XCTAssertTrue(text.contains("Übrigens lassen"))
    }

    /// The same bar over a row of a form, and over an item of the settings on an iPhone with a
    /// Dynamic Island (Hiragino), read with the least confidence: no line next to them to compare
    func testLinesUnderTheTabBarOfFormsAndSettingsAreGarbage() throws {
        let form = [
            line("Töne & Haptik", 80.8, 2122.7, 298.3, 53.1, confidence: 1, in: iPhone),
            line("Nie", 1015.5, 2130.9, 69.9, 36.8, confidence: 1, in: iPhone),
            line("An-aina O llallialait", 62.5, 2270.7, 316.4, 18.4, confidence: 0.3, in: iPhone),
            line("Start", 80.9, 2388.5, 73.6, 22.1, confidence: 1, in: iPhone),
        ]
        let formBlocks = TextLayout.blocks(form, imageSize: iPhone)
        XCTAssertEqual(formBlocks.map(\.isGarbled), [false, false, true, false])
        XCTAssertFalse(TextLayout.plainText(form, imageSize: iPhone).contains("An-aina"))
        let settings = [
            line("Wi-Fi", 186.6, 2210.8, 194.7, 61.0, confidence: 1, in: iPhoneIsland),
            line("自宅のネットワークに接続済み", 194.7, 2275.8, 787.0, 57.2, confidence: 1, in: iPhoneIsland),
            line("并于H", 222.9, 2522.8, 178.9, 38.5, confidence: 0.3, in: iPhoneIsland),
            line("ホーム", 81.1, 2649.7, 89.2, 32.5, confidence: 1, in: iPhoneIsland),
        ]
        let settingsBlocks = TextLayout.blocks(settings, imageSize: iPhoneIsland)
        XCTAssertEqual(settingsBlocks.filter(\.isGarbled).map(\.text), ["并于H"])
        XCTAssertTrue(TextLayout.plainText(settings, imageSize: iPhoneIsland).contains("自宅のネットワークに接続済み"))
    }

    /// Arabic and Thai lines have tall letters, too: an Arabic chat line under the tab bar of an
    /// iPhone (Geeza Pro) and a Thai row under the tab bar of an iPad (Thonburi)
    func testArabicAndThaiLinesCanLookCutOff() throws {
        let chat = [
            line("خمس دقائق، آسف!", 765.3, 2020.0, 316.4, 52.0, confidence: 1, in: iPhone),
            line("شكرا جزيلا! سأتأخر خمس دقائق، آسف!", 426.8, 2138.0, 654.9, 52.0, confidence: 1, in: iPhone),
            line("السليلات", 879.3, 2263.3, 202.4, 25.8, confidence: 0.5, in: iPhone),
        ]
        let chatBlocks = TextLayout.blocks(chat, imageSize: iPhone)
        XCTAssertTrue(try block("السليلات", in: chatBlocks).isGarbled)
        XCTAssertFalse(try block("خمس دقائق، آسف!", in: chatBlocks).isGarbled)
        XCTAssertTrue(TextLayout.looksCutOff("السليلات", width: 202.4, height: 25.8))
        let row = [
            line("Wi-Fi", 44.6, 2013.5, 82.3, 30.9, confidence: 1, in: iPad),
            line("ปิด", 58.3, 2089.0, 58.3, 41.2, confidence: 1, in: iPad),
            line("กดดดก็ดลอกดเสค่อด", 65.2, 2209.0, 356.8, 24.1, confidence: 0.3, in: iPad),
        ]
        XCTAssertEqual(TextLayout.blocks(row, imageSize: iPad).map(\.isGarbled), [false, false, true])
    }

    /// Complete lines in wide type right above the bottom edge: Menlo, and a label in Helvetica
    /// Bold spaced by 0.3 of its size, which Vision reads with a confidence of 0.5. Measured by
    /// their width their boxes are low, but they are no garbage: they are copied, and they are only
    /// held back (`cutOffEdges`) until the picture rests.
    func testCompleteLinesInWideTypeAtTheBottomAreNoGarbage() throws {
        let lines = [
            line("Bitte Licht still stellen", 59, 1207, 599, 35, confidence: 1, in: android),
            line("Fill in the title field", 59, 2313, 554, 38, confidence: 1, in: android),
            line("Hilfe", 700, 2330, 146, 38, confidence: 0.5, in: android),
        ]
        let blocks = TextLayout.blocks(lines, imageSize: android)
        XCTAssertEqual(blocks.map(\.isGarbled), [false, false, false])
        XCTAssertEqual(try block("Bitte Licht still stellen", in: blocks).cutOffEdges, 0)
        XCTAssertEqual(TextLayout.plainText(lines, imageSize: android),
                       "Bitte Licht still stellen\nFill in the title field\nHilfe")
    }

    /// Android (the lab's page): the last line is cut in half by the navigation bar, and Vision
    /// read its upper half as garbage, sure of it (1). The paragraph above is clearly higher: the
    /// line is garbage beyond doubt. Its paragraph is complete as far as it shows.
    func testALineCutOffBelowItsParagraphIsGarbage() throws {
        let lines = [
            line("Une recette simple", 52, 2138, 512, 63, confidence: 1, in: android),
            line("Faites fondre le beurre dans une poêle, ajoutez", 52, 2250, 975, 52, confidence: 1, in: android),
            line("lan dianana aalinán an finan lamallan at", 45, 2316, 829, 28, confidence: 1, in: android),
        ]
        let blocks = TextLayout.blocks(lines, imageSize: android)
        XCTAssertEqual(blocks.map(\.isGarbled), [false, false, true])
        XCTAssertEqual(blocks.map(\.cutOffEdges), [0, FrameMotion.bottom, FrameMotion.top | FrameMotion.bottom])
        XCTAssertEqual(TextLayout.plainText(lines, imageSize: android),
                       "Une recette simple\nFaites fondre le beurre dans une poêle, ajoutez")
        // with a recognizer that reports no confidence the same
        let unsure = lines.map { RecognizedLine(text: $0.text, rect: $0.rect) }
        XCTAssertEqual(TextLayout.blocks(unsure, imageSize: android).map(\.isGarbled), [false, false, true])
    }

    /// Android: the last line under the navigation bar, in a box two thirds as high as the line
    /// above. Vision was not sure of it (0.5): that and the higher line next to it make it garbage
    /// beyond doubt. Of the same box alone it cannot be told: it may be cut off, so it is no line
    /// of the paragraph and held back until the picture rests, but it is copied.
    func testAPartOfALineIsGarbageWhenTheRecognizerIsNotSureOfIt() throws {
        let lines = [
            line("Text bleiben und nicht zittern, springen oder", 52, 2243, 916, 49, confidence: 0.5, in: android),
            line("an ainer alten Stalle ctahen hlaihen menn der", 49, 2309, 948, 32, confidence: 0.5, in: android),
        ]
        let blocks = TextLayout.blocks(lines, imageSize: android)
        XCTAssertEqual(blocks.map(\.text), ["Text bleiben und nicht zittern, springen oder",
                                            "an ainer alten Stalle ctahen hlaihen menn der"])
        XCTAssertEqual(blocks.map(\.cutOffEdges), [FrameMotion.bottom, FrameMotion.top | FrameMotion.bottom])
        XCTAssertEqual(blocks.map(\.isGarbled), [false, true])
        XCTAssertEqual(TextLayout.plainText(lines, imageSize: android), "Text bleiben und nicht zittern, springen oder")
        for confidence in [1, nil] as [Double?] {
            let sure = lines.map { RecognizedLine(text: $0.text, rect: $0.rect, confidence: confidence) }
            let held = TextLayout.blocks(sure, imageSize: android)
            XCTAssertEqual(held.map(\.cutOffEdges), [0, FrameMotion.top | FrameMotion.bottom])
            XCTAssertEqual(held.map(\.isGarbled), [false, false])
            XCTAssertEqual(TextLayout.plainText(sure, imageSize: android).components(separatedBy: "\n").count, 2)
        }
    }

    /// The same low box in the middle of the screen, with a higher line next to it, may be cut
    /// off (by a header that sticks, a keyboard), but there it is never garbage beyond doubt
    func testNothingInTheMiddleOfTheScreenIsGarbageBeyondDoubt() {
        let lines = [
            line("Faites fondre le beurre dans une poêle, ajoutez", 52, 1250, 975, 52, confidence: 0.3, in: android),
            line("lan dianana aalinán an finan lamallan at", 45, 1316, 829, 28, confidence: 0.3, in: android),
        ]
        let blocks = TextLayout.blocks(lines, imageSize: android)
        XCTAssertEqual(blocks.map(\.isGarbled), [false, false])
        XCTAssertEqual(blocks.map(\.cutOffEdges), [FrameMotion.bottom, FrameMotion.top | FrameMotion.bottom])
    }

    /// The status bar (clock and icons, read as letters) is left out of what is translated, as
    /// out of what is copied
    func testTheStatusBarIsNoContent() {
        let lines = [
            line("12:47 L", 42, 17, 139, 35, in: android),
            line("7:22 kg", 40, 16, 150, 34, in: android),
            line("< Testlabor", 41, 103, 377, 66, in: android),
        ]
        XCTAssertEqual(TextLayout.content(lines, imageSize: android).map(\.text), ["< Testlabor"])
    }
}
