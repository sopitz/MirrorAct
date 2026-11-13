// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Order of the recognized lines and paragraphs (Foundation only, like the core). The lines are
/// what Vision read on an Android phone of 1080 × 2400 pixels: a web page with text of 18, 23 and
/// 30 CSS pixels and the system settings, in German. Their boxes are Vision's, to the pixel.
final class TextLayoutTests: XCTestCase {
    private let phone = CGSize(width: 1080, height: 2400)

    /// A line as Vision gave it: left, top, width and height in pixels of the phone's screen
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> RecognizedLine {
        RecognizedLine(text: text, rect: CGRect(x: x / phone.width, y: y / phone.height,
                                                width: width / phone.width, height: height / phone.height))
    }

    /// Top of the lab page: a heading, a paragraph of six lines, two labels and two buttons. The
    /// boxes of the paragraph's lines are 39 to 67 pixels high for one and the same font.
    private var page: [RecognizedLine] {
        [
            line("Willkommen im Testlabor", 56, 303, 906, 70),
            line("Diese Seite ist ein Prüfstand für die", 52, 460, 735, 39),
            line("Texterkennung. Sie enthält Überschriften,", 52, 520, 864, 59),
            line("längere Absätze, kurze Beschriftungen und", 45, 597, 899, 52),
            line("farbige Schaltflächen, damit man sehen kann,", 49, 666, 962, 53),
            line("ob die Übersetzung an der richtigen Stelle", 52, 723, 872, 67),
            line("erscheint.", 52, 802, 206, 43),
            line("Benutzername", 52, 907, 254, 35),
            line("Passwort vergessen?", 52, 998, 373, 42),
            line("Jetzt anmelden", 108, 1113, 331, 42),
            line("Abbrechen", 108, 1269, 237, 47),
        ]
    }

    func testLinesOfOneParagraphStayTogetherWhateverTheHeightOfTheirBoxes() throws {
        let blocks = TextLayout.blocks(page.shuffled(), imageSize: phone)
        XCTAssertEqual(blocks.map(\.text), [
            "Willkommen im Testlabor",
            "Diese Seite ist ein Prüfstand für die Texterkennung. Sie enthält Überschriften, längere Absätze, "
                + "kurze Beschriftungen und farbige Schaltflächen, damit man sehen kann, ob die Übersetzung an der "
                + "richtigen Stelle erscheint.",
            "Benutzername", "Passwort vergessen?", "Jetzt anmelden", "Abbrechen",
        ])
        let paragraph = try XCTUnwrap(blocks.first { $0.lineCount == 6 })
        XCTAssertEqual(paragraph.rect.minY * phone.height, 460, accuracy: 0.01)
        XCTAssertEqual(paragraph.rect.maxY * phone.height, 845, accuracy: 0.01)
        XCTAssertEqual(paragraph.rect.minX * phone.width, 45, accuracy: 0.01)
    }

    /// A Japanese heading of 23 pixels right above its paragraph of 18: the boxes are about as
    /// high (66 and 59), the characters are not as wide
    func testAHeadingIsNotPartOfTheParagraphBelowIt() {
        let lines = [
            line("駅への行き方", 48, 1031, 366, 66),
            line("ホテルを出て右に曲がり、二つ目の信号を左", 52, 1141, 944, 59),
            line("に進んでください。駅は郵便局の向かいにあ", 56, 1210, 937, 56),
            line("ります。", 59, 1280, 160, 56),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: phone).map(\.text),
                       ["駅への行き方", "ホテルを出て右に曲がり、二つ目の信号を左に進んでください。駅は郵便局の向かいにあります。"])
    }

    /// Settings: every entry has a title and a smaller summary right below it, which may take
    /// two lines; an icon in front
    func testTitlesAndSummariesOfAListAreSeparate() {
        let lines = [
            line("の", 91, 631, 91, 84),
            line("Netzwerk & Internet", 213, 621, 463, 45),
            line("Mobile Daten, WLAN, Hotspot", 209, 687, 488, 39),
            line("Verbundene Geräte", 209, 823, 453, 49),
            line("Bluetooth, Kopplung", 209, 893, 331, 42),
            line("Apps", 209, 1074, 125, 52),
            line("Assistant, kürzlich geöffnete Apps,", 209, 1141, 571, 42),
            line("Standard-Apps", 209, 1186, 244, 38),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: phone).map(\.text), [
            "Netzwerk & Internet", "の", "Mobile Daten, WLAN, Hotspot", "Verbundene Geräte", "Bluetooth, Kopplung",
            "Apps", "Assistant, kürzlich geöffnete Apps, Standard-Apps",
        ])
    }

    /// A title of two lines over a summary of two lines in a smaller font
    func testATitleOfTwoLinesStaysApartFromItsSummary() {
        let lines = [
            line("Datum und Uhrzeit automatisch", 63, 593, 739, 42),
            line("einstellen", 63, 656, 227, 42),
            line("Einstellung erfolgt automatisch über Netzwerk-", 63, 719, 777, 42),
            line("und WLAN-Signale", 59, 764, 310, 38),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: phone).map(\.text), [
            "Datum und Uhrzeit automatisch einstellen", "Einstellung erfolgt automatisch über Netzwerk- und WLAN-Signale",
        ])
    }

    /// Lines side by side are separate; so are columns, and the items of a list (widths as Vision
    /// gives them for text of 18 pixels)
    func testLabelsNextToEachOtherColumnsAndListItemsAreSeparate() {
        let lines = [
            line("Helligkeit", 63, 832, 224, 50),
            line("83 %", 900, 836, 80, 40),
            line("Erste Spalte mit einem", 52, 1000, 501, 49),
            line("längeren Text darin", 52, 1066, 384, 49),
            line("Zweite Spalte, auch", 600, 1000, 444, 49),
            line("mit zwei Zeilen", 600, 1066, 354, 49),
            line("• Brot und Butter", 52, 1300, 368, 49),
            line("• Milch vom Markt", 52, 1366, 410, 49),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: phone).map(\.text), [
            "Helligkeit", "83 %", "Erste Spalte mit einem längeren Text darin", "Zweite Spalte, auch mit zwei Zeilen",
            "• Brot und Butter", "• Milch vom Markt",
        ])
    }

    /// The text size comes from the width and the letters: the same for all lines of the
    /// paragraph, larger for the heading, smaller for the labels
    func testTextSizeIsMeasuredFromTheWidth() throws {
        let sizes = page.map { TextLayout.textSize(of: $0.text, width: Double($0.rect.width * phone.width)) }
        let paragraph = try sizes[1...6].map { try XCTUnwrap($0) }
        XCTAssertLessThan(try XCTUnwrap(paragraph.max()) / XCTUnwrap(paragraph.min()), 1.05)
        XCTAssertGreaterThan(try XCTUnwrap(sizes[0]) / XCTUnwrap(paragraph.max()), 1.5)
        XCTAssertLessThan(try XCTUnwrap(sizes[7]) / XCTUnwrap(paragraph.min()), 0.9)
        XCTAssertNil(TextLayout.textSize(of: "16", width: 45))
    }

    /// Scrolled to the end of the page: the navigation bar hides the lower part of the last line.
    /// Vision read the rest of it, nearly right, in a box two thirds as high as the line above.
    /// The paragraph ends above it; the part is no line of it.
    func testAPartOfALineIsNoLineOfTheParagraph() {
        let lines = [
            line("Zum Schluss noch ein langer Absatz, damit", 49, 2037, 909, 53),
            line("die Seite weit genug nach unten reicht. Beim", 52, 2103, 923, 53),
            line("Scrollen sollen die Übersetzungen auf ihrem", 52, 2162, 917, 64),
            line("Text bleiben und nicht zittern, springen oder", 52, 2243, 916, 49),
            line("an ainer alten Stalle ctahen hlaihen menn der", 49, 2309, 948, 32),
        ]
        let blocks = TextLayout.blocks(lines, imageSize: phone)
        XCTAssertEqual(blocks.map(\.text), [
            "Zum Schluss noch ein langer Absatz, damit die Seite weit genug nach unten reicht. Beim Scrollen sollen "
                + "die Übersetzungen auf ihrem Text bleiben und nicht zittern, springen oder",
            "an ainer alten Stalle ctahen hlaihen menn der",
        ])
    }

    func testPlainTextReadsTopToBottomAndLeftToRight() {
        let lines = [
            line("third line.", 117, 881, 351, 51),
            line("Title", 468, 253, 234, 76),
            line("9:41", 117, 51, 117, 38),
            line("Label", 117, 1269, 234, 51),
            line("Value", 819, 1266, 234, 51),
        ]
        XCTAssertEqual(TextLayout.plainText(lines), "9:41\nTitle\nthird line.\nLabel Value")
    }

    func testOnlyTextWithLettersIsTranslated() {
        XCTAssertFalse(TextLayout.isTranslatable("9:41"))
        XCTAssertFalse(TextLayout.isTranslatable("€ 12.50"))
        XCTAssertTrue(TextLayout.isTranslatable("OK"))
    }
}
