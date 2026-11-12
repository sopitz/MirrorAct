// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Order of the recognized lines and paragraphs (Foundation only: also runs on Linux)
final class TextLayoutTests: XCTestCase {
    private let size = CGSize(width: 1170, height: 2532)

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> RecognizedLine {
        RecognizedLine(text: text, rect: CGRect(x: x, y: y, width: width, height: height))
    }

    private var screen: [RecognizedLine] {
        [
            line("third line.", 0.1, 0.348, 0.3, 0.02),
            line("Title", 0.4, 0.1, 0.2, 0.03),
            line("First line of a", 0.1, 0.30, 0.6, 0.02),
            line("paragraph that goes", 0.1, 0.324, 0.7, 0.02),
            line("Value", 0.7, 0.5, 0.2, 0.02),
            line("Label", 0.1, 0.501, 0.2, 0.02),
            line("9:41", 0.1, 0.02, 0.1, 0.015),
        ]
    }

    func testPlainTextReadsTopToBottomAndLeftToRight() {
        XCTAssertEqual(TextLayout.plainText(screen),
                       "9:41\nTitle\nFirst line of a\nparagraph that goes\nthird line.\nLabel Value")
    }

    func testLinesOfAParagraphBecomeOneBlock() throws {
        let blocks = TextLayout.blocks(screen, imageSize: size)
        XCTAssertEqual(blocks.map(\.text),
                       ["9:41", "Title", "First line of a paragraph that goes third line.", "Label", "Value"])
        let paragraph = try XCTUnwrap(blocks.first { $0.lineCount == 3 })
        XCTAssertEqual(paragraph.rect.minY, 0.30, accuracy: 0.0001)
        XCTAssertEqual(paragraph.rect.maxY, 0.368, accuracy: 0.0001)
        XCTAssertEqual(paragraph.rect.width, 0.7, accuracy: 0.0001)
    }

    func testOnlyTextWithLettersIsTranslated() {
        XCTAssertFalse(TextLayout.isTranslatable("9:41"))
        XCTAssertFalse(TextLayout.isTranslatable("€ 12.50"))
        XCTAssertTrue(TextLayout.isTranslatable("OK"))
    }
}
