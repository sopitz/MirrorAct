// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Which lines `TextLayout.blocks` joins into one paragraph, on layouts and scripts other than the
/// Android pages of `TextLayoutTests`: iPhone and iPad screens in Apple's fonts, right-to-left
/// text and lists. The lines are what Vision read on pictures of such screens drawn with Core
/// Text (the text sizes and spacing of iOS); their boxes are Vision's, to the pixel.
final class TextLayoutJoinTests: XCTestCase {
    private static let iPhone = CGSize(width: 1170, height: 2532)
    private static let iPad = CGSize(width: 1640, height: 2360)

    /// A line as Vision gave it: left, top, width and height in pixels of a screen of `size`
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                      on size: CGSize = iPhone) -> RecognizedLine {
        RecognizedLine(text: text, rect: CGRect(x: x / size.width, y: y / size.height,
                                                width: width / size.width, height: height / size.height))
    }

    // MARK: Right to left

    /// An Arabic chat on an iPhone (SF Arabic, 17 points): the lines of a bubble end at the same
    /// right edge, their left edges and centres lie far apart. The receipts below the last two
    /// bubbles end at about the same right edge too, but in a smaller size and further down.
    func testLinesOfARightToLeftParagraphShareTheirRightEdge() {
        let lines = [
            line("9:40", 541, 335, 81, 33),
            line("نعم، في العاشرة أمام المكتبة. هل", 429, 401, 658, 95),
            line("ما زلنا سنلتقي غدا؟ رائع، سأحضر", 444, 469, 643, 78),
            line("المستندات التي", 776, 541, 316, 63),
            line("سأتأخر خمس دقائق، آسف! شكرا", 136, 676, 645, 81),
            line("جزيلا! نعم، في العاشرة أمام المكتبة.", 77, 735, 707, 73),
            line("رائع، سأحضر المستندات التي تحدثنا", 81, 799, 706, 66),
            line("عنها الأسبوع", 541, 861, 239, 59),
            line("هل ما زلنا سنلتقي غدا؟ شكرا جزيلا!", 76, 988, 712, 82),
            line("رائع، سأحضر", 537, 1060, 250, 66),
            line("هل ما زلنا سنلتقي غدا؟", 611, 1873, 475, 70),
            line("تم التحديث الان", 883, 1987, 213, 37),
            line("نعم، في العاشرة أمام المكتبة.", 499, 2044, 585, 93),
            line("تم التحديث الان", 883, 2159, 214, 40),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: Self.iPhone).map(\.text), [
            "9:40",
            "نعم، في العاشرة أمام المكتبة. هل ما زلنا سنلتقي غدا؟ رائع، سأحضر المستندات التي",
            "سأتأخر خمس دقائق، آسف! شكرا جزيلا! نعم، في العاشرة أمام المكتبة. رائع، سأحضر المستندات التي تحدثنا عنها الأسبوع",
            "هل ما زلنا سنلتقي غدا؟ شكرا جزيلا! رائع، سأحضر",
            "هل ما زلنا سنلتقي غدا؟", "تم التحديث الان", "نعم، في العاشرة أمام المكتبة.", "تم التحديث الان",
        ])
    }

    /// Right edges join lines of right-to-left text only: on an iPhone, the title of the
    /// navigation bar ends where the heading of the page scrolled up below it ends
    func testLeftToRightLinesThatOnlyShareTheirRightEdgeAreSeparate() {
        let lines = [
            line("Einstellungen", 423, 190, 321, 48),
            line("Was Sie mitbringen sollten", 52, 272, 681, 52),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: Self.iPhone).map(\.text),
                       ["Einstellungen", "Was Sie mitbringen sollten"])
        XCTAssertTrue(TextLayout.isRightToLeft("تم التحديث الان"))
        XCTAssertTrue(TextLayout.isRightToLeft("البطارية Wi-Fi"))
        XCTAssertFalse(TextLayout.isRightToLeft("Wi-Fi البطارية Bluetooth"))
        XCTAssertFalse(TextLayout.isRightToLeft("9:41"))
    }
}
