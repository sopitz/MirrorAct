// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// An on-screen keyboard is no text to translate (`TextLayout.keyboard`), and the lines of the page
/// above it are. The lines of the first tests are what the recognizer read on an Android phone of
/// 1080 × 2400 pixels with Gboard up (light, portrait), with the brightness it measured; their
/// boxes are Vision's, to the pixel.
final class TextLayoutKeyboardTests: XCTestCase {
    private let phone = TextLayoutKeyboardTests.phone
    static let phone = CGSize(width: 1080, height: 2400)

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                      tone: (text: Double, background: Double, colour: Double)? = nil) -> RecognizedLine {
        Self.line(text, x, y, width, height, tone: tone)
    }

    /// A line as Vision gave it: left, top, width and height in pixels of the phone's screen, and
    /// the brightness of its letters and background and the share of coloured letters
    private static func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                             tone: (text: Double, background: Double, colour: Double)? = nil) -> RecognizedLine {
        var line = RecognizedLine(text: text, rect: CGRect(x: x / phone.width, y: y / phone.height,
                                                           width: width / phone.width, height: height / phone.height))
        line.tone = tone.map { RecognizedLine.Tone(text: $0.text, background: $0.background, colour: $0.colour) }
        return line
    }

    /// The settings' search with "an" typed into the field: the strip of suggestions ("an", "in",
    /// the grid of the toolbar read as "::"), the top row with a digit in the corner of each key
    /// read in three pieces, the two other rows of letters, and "?123" and the search key of the
    /// bottom row
    private var settingsSearch: [RecognizedLine] { Self.settingsSearch }
    static var settingsSearch: [RecognizedLine] {
        [
            line("2:59 5口", 42, 14, 178, 38, tone: (106, 222, 0)),
            line("an", 188, 147, 45, 31, tone: (41, 222, 0)),
            line("X", 982, 136, 45, 45, tone: (85, 222, 0)),
            line("Android-Version", 63, 317, 387, 42, tone: (41, 222, 0)),
            line("Über emuliertes Gerät", 63, 384, 373, 42, tone: (85, 222, 0)),
            line("Anstehend", 188, 537, 265, 45, tone: (41, 222, 0)),
            line("C", 63, 562, 59, 59, tone: (85, 222, 0)),
            line("Settings Services", 185, 617, 293, 39, tone: (85, 222, 0)),
            line("Anruflautstärke", 188, 757, 369, 49, tone: (41, 222, 0)),
            line("Ton & Vibration", 185, 949, 258, 38, tone: (85, 222, 0)),
            line("Anrede anpassen", 62, 1098, 420, 57, tone: (41, 222, 0)),
            line("System > Sprache & Region", 63, 1176, 456, 42, tone: (85, 222, 0)),
            line("Android Auto", 63, 1319, 317, 49, tone: (41, 222, 0)),
            line("Verbundene Geräte > Verbindungseinstellungen", 63, 1395, 798, 42, tone: (85, 222, 0)),
            line("::", 24, 1538, 73, 70, tone: (41, 222, 0)),
            line("an", 206, 1559, 178, 38, tone: (41, 222, 0)),
            line("in", 791, 1549, 77, 49, tone: (41, 222, 0)),
            line("a'w' e rt°", 34, 1652, 510, 97, tone: (41, 234, 0)),
            line("y' u i°", 530, 1653, 331, 98, tone: (41, 234, 0)),
            line("Ö'", 878, 1657, 87, 80, tone: (41, 234, 0)),
            line("asdfg hilkl", 93, 1819, 894, 102, tone: (41, 234, 0)),
            line("ZxCvbnmx", 150, 1988, 874, 66, tone: (41, 234, 0.09)),
            line("?123", 35, 2156, 111, 42, tone: (84, 214, 0)),
            line("Q", 962, 2149, 59, 66, tone: (85, 214, 0)),
        ]
    }

    /// A web page with a search field holding "Wasserkocher" and a caret, the keyboard up: three
    /// suggestions read as one line, the top row in two pieces
    private var webPage: [RecognizedLine] { Self.webPage }
    static var webPage: [RecognizedLine] {
        [
            line("1:55 9 L", 42, 17, 178, 35, tone: (107, 226, 0)),
            line("Eingabe", 183, 108, 197, 66, tone: (41, 226, 0)),
            line("Suche im Katalog", 56, 307, 575, 73, tone: (39, 234, 0)),
            line("Wasserkocher", 77, 516, 369, 49, tone: (16, 234, 0)),
            line("Geben Sie oben ein Wort ein, nach dem", 52, 687, 812, 53, tone: (39, 234, 0)),
            line("gesucht werden soll.", 49, 757, 439, 49, tone: (39, 234, 0)),
            line("Ein ruhiger Absatz", 52, 893, 481, 59, tone: (39, 234, 0)),
            line("Dieser Absatz ändert sich nie. Er steht als", 52, 1001, 871, 46, tone: (39, 234, 0)),
            line("Vergleich neben den Texten, die sich bewegen", 52, 1071, 958, 49, tone: (39, 234, 0)),
            line("oder ändern, und muss nach kurzer Zeit", 52, 1141, 829, 52, tone: (39, 234, 0)),
            line("übersetzt sein und übersetzt bleiben.", 52, 1207, 773, 45, tone: (39, 234, 0)),
            line("Hinweise zur Lieferung", 51, 1333, 601, 75, tone: (39, 234, 0)),
            line("Pakete werden werktags zwischen acht und", 52, 1455, 916, 49, tone: (39, 234, 0)),
            line("Wasserkocher Washer ocher Washer other", 87, 1549, 951, 52, tone: (41, 222, 0)),
            line("a'w' e r t°", 34, 1656, 503, 94, tone: (41, 234, 0)),
            line("u is", 631, 1653, 233, 84, tone: (41, 234, 0)),
            line("asdfghikl", 94, 1824, 892, 84, tone: (41, 234, 0)),
            line("ZxCvbnmx", 167, 1988, 857, 66, tone: (41, 234, 0.03)),
            line("?123", 35, 2156, 111, 42, tone: (84, 214, 0)),
            line("く", 98, 2327, 28, 24, tone: (112, 222, 0)),
        ]
    }

    /// The same page with "WasserkocherTee" typed, read in a band of y 1600 to 1950 that holds the
    /// two upper rows of letters: Vision read the top row in pieces with the digits in the corners
    /// apart, and the second row in pieces. (Boxes in pixels of the whole picture.)
    static var upperRowsOfWebPage: [RecognizedLine] {
        [
            line("2", 190, 1666, 18, 26), line("3", 296, 1666, 18, 24), line("6", 618, 1664, 20, 26),
            line("7", 724, 1664, 22, 26), line("8", 830, 1664, 24, 28), line("9", 938, 1668, 18, 22),
            line("a' w", 40, 1658, 150, 92), line("…e", 214, 1696, 76, 42), line("t", 460, 1684, 54, 52),
            line("U", 684, 1696, 34, 42), line("O", 896, 1696, 38, 42),
            line("s d", 190, 1838, 194, 56), line("f", 398, 1836, 48, 54), line("K", 816, 1838, 66, 52),
        ]
    }
    static let upperRowsRegion = CGRect(x: 0, y: 1600, width: 1080, height: 350)

    /// The settings' search with "andro" typed, read in a band of y 1560 to 2100 that holds the
    /// strip of suggestions and the rows of keys but not the bottom row: Vision missed the top row
    /// (only its corner digits and a "W") and read the two lower rows in pieces
    static var lowerRowsOfSearch: [RecognizedLine] {
        [
            line("andro", 184, 1559, 127, 38), line("Andro", 441, 1560, 212, 41), line("Android", 732, 1560, 222, 37),
            line("1", 86, 1664, 16, 26), line("2", 190, 1660, 22, 32), line("6", 608, 1664, 30, 28),
            line("9", 928, 1664, 36, 40), line("W", 112, 1688, 80, 50),
            line("a", 94, 1852, 36, 42), line("d", 290, 1836, 74, 58), line("f", 402, 1838, 44, 52),
            line("ghik", 502, 1836, 398, 72),
            line("个", 56, 2002, 62, 48), line("Z", 200, 2006, 40, 42), line("vbnm", 476, 1992, 450, 58),
        ]
    }

    /// The same page read in a band of y 1100 to 1960, over most of the keys: Vision read the rows
    /// of keys in pieces that are no rows of keys
    static var webPageAndKeysInPieces: [RecognizedLine] {
        [
            line("oder ändern, und muss nach kurzer Zeit", 52, 1140, 830, 52),
            line("übersetzt sein und übersetzt bleiben.", 54, 1208, 774, 42),
            line("Hinweise zur Lieferung", 54, 1348, 594, 63),
            line("Pakete werden werktags zwischen acht und", 48, 1454, 922, 50),
            line("•• Wasse..herTee Was Serio better Was Erik better 4", 32, 1550, 1008, 54),
            line("1", 84, 1666, 22, 26), line("4", 402, 1664, 22, 26), line("7", 722, 1660, 36, 38),
            line("• we", 42, 1698, 254, 52), line("t° y u", 462, 1662, 258, 88),
            line("a", 94, 1854, 50, 40), line("sa f", 166, 1836, 282, 60), line("ghi k", 510, 1836, 382, 72),
        ]
    }
    static let piecesRegion = CGRect(x: 0, y: 1100, width: 1080, height: 860)

    /// The same search in the dark theme: Vision read every key alone, the digits in the corners
    /// of the top row as a row of their own
    private var darkSearch: [RecognizedLine] {
        [
            line("4:400［", 38, 14, 179, 41, tone: (234, 46, 0)),
            line("X", 979, 133, 49, 52, tone: (192, 46, 0)),
            line("an", 185, 147, 49, 31, tone: (213, 46, 0)),
            line("Android-Version", 63, 310, 390, 52, tone: (214, 46, 0)),
            line("Über emuliertes Gerät", 59, 387, 376, 42, tone: (192, 46, 0)),
            line("Anstehend", 188, 537, 265, 45, tone: (213, 46, 0)),
            line("C", 63, 562, 59, 59, tone: (192, 46, 0)),
            line("Settings Services", 185, 614, 293, 42, tone: (192, 46, 0)),
            line("Anruflautstärke", 181, 757, 376, 49, tone: (213, 46, 0)),
            line("Ton & Vibration", 185, 949, 258, 38, tone: (192, 46, 0)),
            line("Anrede anpassen", 61, 1090, 428, 70, tone: (213, 46, 0)),
            line("System > Sprache & Region", 59, 1172, 460, 45, tone: (192, 46, 0)),
            line("Android Auto", 63, 1315, 321, 52, tone: (213, 46, 0)),
            line("Verbundene Geräte > Verbindungseinstellungen", 59, 1395, 805, 46, tone: (192, 46, 0)),
            line("in", 798, 1549, 49, 49, tone: (213, 46, 0)),
            line("an", 219, 1559, 59, 38, tone: (214, 46, 0)),
            line("n", 519, 1559, 35, 42, tone: (214, 46, 0)),
            line("7", 718, 1660, 24, 31, tone: (192, 66, 0)),
            line("4", 404, 1664, 17, 24, tone: (192, 66, 0)),
            line("5", 512, 1664, 17, 24, tone: (192, 66, 0)),
            line("2", 192, 1664, 17, 24, tone: (192, 66, 0)),
            line("t", 470, 1688, 31, 49, tone: (214, 66, 0)),
            line("O", 892, 1692, 42, 45, tone: (214, 66, 0)),
            line("W", 139, 1692, 52, 45, tone: (214, 66, 0)),
            line("e", 254, 1695, 38, 45, tone: (214, 66, 0)),
            line("h", 624, 1831, 45, 63, tone: (214, 66, 0)),
            line("f", 415, 1835, 31, 59, tone: (214, 66, 0)),
            line("d", 307, 1835, 42, 56, tone: (214, 66, 0)),
            line("a", 94, 1849, 38, 45, tone: (214, 66, 0)),
            line("S", 199, 1849, 38, 45, tone: (214, 66, 0)),
            line("b", 627, 1988, 42, 59, tone: (214, 66, 0)),
            line("m", 829, 2002, 56, 49, tone: (214, 66, 0)),
            line("V", 519, 2002, 42, 45, tone: (214, 66, 0)),
            line("n", 732, 2002, 42, 45, tone: (214, 66, 0)),
            line("X", 303, 2002, 42, 45, tone: (214, 66, 0)),
            line("Z", 199, 2002, 42, 45, tone: (214, 66, 0)),
            line("?123", 35, 2156, 101, 46, tone: (214, 86, 0)),
            line("く", 98, 2327, 28, 24, tone: (234, 46, 0)),
        ]
    }

    /// The same search in landscape (2400 × 1080): every key read alone, the digits apart
    private let landscape = CGSize(width: 2400, height: 1080)
    private func wide(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                      tone: (text: Double, background: Double, colour: Double)) -> RecognizedLine {
        RecognizedLine(text: text, rect: CGRect(x: x / landscape.width, y: y / landscape.height,
                                                width: width / landscape.width, height: height / landscape.height),
                       tone: RecognizedLine.Tone(text: tone.text, background: tone.background, colour: tone.colour))
    }
    private var landscapeSearch: [RecognizedLine] {
        [
            wide("4:41S口", 42, 17, 178, 35, tone: (106, 222, 0)),
            wide("X", 2302, 136, 45, 45, tone: (85, 222, 0)),
            wide("an", 181, 146, 56, 31, tone: (41, 222, 0)),
            wide("Android-Version", 63, 314, 391, 49, tone: (41, 222, 0)),
            wide("88", 38, 422, 63, 52, tone: (41, 222, 0)),
            wide("and", 1155, 425, 87, 49, tone: (41, 222, 0)),
            wide("any", 1873, 432, 84, 45, tone: (41, 222, 0)),
            wide("an", 450, 439, 52, 31, tone: (41, 222, 0)),
            wide("1", 199, 512, 17, 35, tone: (85, 234, 0)),
            wide("2", 429, 512, 28, 38, tone: (85, 234, 0)),
            wide("8", 1863, 512, 35, 42, tone: (85, 234, 0)),
            wide("4", 914, 516, 21, 28, tone: (85, 234, 0)),
            wide("7", 1633, 516, 21, 28, tone: (85, 234, 0)),
            wide("9", 2107, 516, 28, 28, tone: (85, 234, 0)),
            wide("5", 1151, 516, 24, 31, tone: (85, 234, 0)),
            wide("3", 673, 516, 21, 28, tone: (85, 234, 0)),
            wide("i", 1786, 519, 24, 56, tone: (41, 234, 0)),
            wide("e", 583, 537, 38, 45, tone: (41, 234, 0)),
            wide("W", 335, 537, 49, 45, tone: (41, 234, 0)),
            wide("t", 1064, 537, 31, 45, tone: (41, 234, 0)),
            wide("U", 1542, 540, 38, 42, tone: (41, 234, 0)),
            wide("r", 823, 540, 31, 42, tone: (41, 234, 0)),
            wide("j", 1660, 627, 38, 77, tone: (42, 234, 0)),
            wide("d", 701, 638, 38, 56, tone: (41, 234, 0)),
            wide("k", 1901, 638, 38, 52, tone: (41, 234, 0)),
            wide("h", 1420, 638, 38, 56, tone: (41, 234, 0)),
            wide("f", 945, 641, 31, 49, tone: (41, 234, 0)),
            wide("g", 1183, 651, 38, 52, tone: (41, 234, 0)),
            wide("a", 223, 651, 35, 42, tone: (41, 234, 0)),
            wide("S", 464, 655, 31, 38, tone: (41, 234, 0)),
            wide("b", 1420, 753, 42, 56, tone: (41, 234, 0)),
            wide("<", 2187, 759, 56, 52, tone: (85, 214, 0)),
            wide("仑", 150, 759, 59, 52, tone: (85, 214, 0)),
            wide("X", 701, 763, 38, 45, tone: (41, 234, 0)),
            wide("m", 1894, 763, 49, 42, tone: (41, 234, 0)),
            wide("n", 1660, 763, 38, 42, tone: (41, 234, 0)),
            wide("Z", 464, 766, 35, 42, tone: (41, 234, 0)),
            wide("C", 942, 766, 38, 42, tone: (41, 234, 0)),
            wide("V", 1179, 766, 42, 42, tone: (41, 234, 0)),
            wide("Q", 2187, 867, 56, 56, tone: (84, 214, 0)),
            wide("?123", 125, 870, 109, 54, tone: (85, 214, 0)),
            wide("く", 94, 1007, 31, 24, tone: (112, 222, 0)),
        ]
    }

    private func translated(_ lines: [RecognizedLine], keyboard: OnScreenKeyboard?) -> [String] {
        TextLayout.blocks(TextLayout.content(lines, imageSize: phone, statusBar: .longerSide, for: .translating,
                                             keyboard: keyboard), imageSize: phone)
            .map(\.text).filter(TextLayout.isTranslatable)
    }

    /// The keys, the suggestions and the bottom row are left out; the typed word and every line of
    /// the page above the keyboard are translated as before
    func testNothingOfTheKeyboardIsTranslatedAndThePageAboveItIs() throws {
        for (lines, typed, lastOfPage) in [(settingsSearch, "an", "Verbundene Geräte > Verbindungseinstellungen"),
                                           (webPage, "Wasserkocher", "Pakete werden werktags zwischen acht und")] {
            let keyboard = try XCTUnwrap(TextLayout.keyboard(in: lines, imageSize: phone))
            // it begins between the page's last line and the suggestions
            let page = try XCTUnwrap(lines.first { $0.text == lastOfPage })
            XCTAssertGreaterThan(keyboard.top, Double(page.rect.maxY * phone.height))
            XCTAssertLessThan(keyboard.top, 1538)
            let texts = translated(lines, keyboard: keyboard)
            XCTAssertEqual(texts, translated(lines.filter { $0.rect.minY * phone.height < 1500 }, keyboard: nil))
            XCTAssertTrue(texts.contains(typed))
            XCTAssertTrue(texts.contains(lastOfPage))
            XCTAssertFalse(texts.contains { $0.contains("asdf") || $0.contains("ZxC") || $0.contains("rt°")
                || $0.contains("Washer") || $0 == "in" || $0.contains("u i") })
            // without it, the keys and the suggestions were sent
            XCTAssertTrue(translated(lines, keyboard: nil).contains { $0.contains("asdf") })
        }
    }

    /// A reading in which Vision did not read the top row (the one with the digits in the corners
    /// of the keys): the two rows found are taken for the lower rows of three, and the keyboard
    /// begins a pitch higher, so the suggestions stay out and the page's last line stays in
    func testAKeyboardWhoseTopRowWasNotReadBeginsAboveIt() throws {
        for (lines, lastOfPage) in [(settingsSearch, "Verbundene Geräte > Verbindungseinstellungen"),
                                    (webPage, "Pakete werden werktags zwischen acht und")] {
            let withoutTopRow = lines.filter { !(1640...1760).contains($0.rect.midY * phone.height) }
            let keyboard = try XCTUnwrap(TextLayout.keyboard(in: withoutTopRow, imageSize: phone))
            let texts = translated(withoutTopRow, keyboard: keyboard)
            XCTAssertEqual(texts, translated(lines.filter { $0.rect.minY * phone.height < 1500 }, keyboard: nil))
            XCTAssertTrue(texts.contains(lastOfPage))
            // (above the middles of the suggestions, 1573 to 1578)
            XCTAssertLessThan(keyboard.top, 1570)
        }
    }

    /// Dark, and in landscape, where every key was read alone: the keys, the digits in their
    /// corners and the suggestions are left out, the page above is translated
    func testAKeyboardReadKeyByKeyIsFoundDarkAndInLandscape() throws {
        let dark = try XCTUnwrap(TextLayout.keyboard(in: darkSearch, imageSize: phone))
        let darkTexts = translated(darkSearch, keyboard: dark)
        XCTAssertEqual(darkTexts, translated(darkSearch.filter { $0.rect.minY * phone.height < 1500 }, keyboard: nil))
        XCTAssertTrue(darkTexts.contains("Verbundene Geräte > Verbindungseinstellungen"))
        XCTAssertFalse(darkTexts.contains("in"))
        let wideBoard = try XCTUnwrap(TextLayout.keyboard(in: landscapeSearch, imageSize: landscape))
        let wideTexts = TextLayout.blocks(TextLayout.content(landscapeSearch, imageSize: landscape, statusBar: .longerSide,
                                                             for: .translating, keyboard: wideBoard), imageSize: landscape)
            .map(\.text).filter(TextLayout.isTranslatable)
        XCTAssertEqual(wideTexts, ["an", "Android-Version"])
    }

    /// The keyboard holds while the picture is read in parts: a reading of the strip of
    /// suggestions alone, which changes with every key typed, finds no keyboard and leaves its
    /// lines out all the same. A reading of a part that finds none ends it only when the picture
    /// where the keys were has changed; a reading of the whole picture that finds none ends it,
    /// and so does one of another size of picture.
    func testAKeyboardStaysWhileThePictureIsReadInPartsAndEndsWhenItsKeysAreGone() throws {
        let known = try XCTUnwrap(TextLayout.keyboard(in: settingsSearch, imageSize: phone))
        // the strip alone
        let strip = settingsSearch.filter { (1530...1620).contains($0.rect.midY * phone.height) }
        let stripRegion = CGRect(x: 0, y: 1500, width: 1080, height: 140)
        XCTAssertNil(TextLayout.keyboard(in: strip, imageSize: phone))
        let kept = try XCTUnwrap(TextLayout.keyboard(in: strip, imageSize: phone, region: stripRegion, known: known))
        XCTAssertEqual(kept, known)
        XCTAssertTrue(translated(strip, keyboard: kept).isEmpty)
        // the two lower rows read alone find a keyboard that begins lower; it is joined with the one known
        let lower = settingsSearch.filter { $0.rect.minY * phone.height > 1800 }
        let joined = try XCTUnwrap(TextLayout.keyboard(in: lower, imageSize: phone,
                                                       region: CGRect(x: 0, y: 1800, width: 1080, height: 600), known: known))
        XCTAssertEqual(joined.top, known.top)
        // the place of the keys read again with the page in it: the keyboard has gone
        let page = settingsSearch.filter { $0.rect.maxY * phone.height < 1450 }
            .map { line -> RecognizedLine in
                var moved = line
                moved.rect.origin.y += 900 / phone.height
                return moved
            }
            .filter { $0.rect.maxY < 1 }
        let place = CGRect(x: 0, y: 1450, width: 1080, height: 950)
        XCTAssertNil(TextLayout.keyboard(in: page, imageSize: phone, region: place, known: known, keysChanged: true))
        // (while the picture of the keys is unchanged, it stays)
        XCTAssertEqual(TextLayout.keyboard(in: page, imageSize: phone, region: place, known: known), known)
        // (a part that holds little of the keys keeps it)
        XCTAssertNotNil(TextLayout.keyboard(in: [], imageSize: phone, region: CGRect(x: 0, y: 1800, width: 1080, height: 150),
                                            known: known))
        // the whole picture read without a keyboard ends it
        XCTAssertNil(TextLayout.keyboard(in: page, imageSize: phone, region: nil, known: known))
        // another size of picture (turned to landscape) ends it
        XCTAssertNil(TextLayout.keyboard(in: [], imageSize: CGSize(width: 2400, height: 1080),
                                         region: CGRect(x: 0, y: 0, width: 10, height: 10), known: known))
    }

    /// A reading of a band that holds the two upper rows of letters alone (y 1600 to 1950, as the
    /// tracker reads parts of the picture while keys pop up and the strip changes) finds a
    /// keyboard of two rows with nothing read below them: the row not read may lie below, so the
    /// keyboard does not begin a pitch higher. It begins between the page's last line and the
    /// suggestions, and the memory keeps that through the next reading of the whole picture, in
    /// which the page's last two lines are translated.
    func testAReadingOfTheUpperRowsAloneDoesNotMoveTheKeyboardUp() throws {
        let known = try XCTUnwrap(TextLayout.keyboard(in: webPage, imageSize: phone))
        let pageBottom = 1504.0  // "Pakete werden werktags zwischen acht und"
        let band = Self.upperRowsOfWebPage
        let alone = try XCTUnwrap(TextLayout.keyboard(in: band, imageSize: phone))
        XCTAssertGreaterThan(alone.top, pageBottom)
        let afterBand = try XCTUnwrap(TextLayout.keyboard(in: band, imageSize: phone, region: Self.upperRowsRegion,
                                                          known: known))
        XCTAssertGreaterThan(afterBand.top, pageBottom)
        let afterWhole = try XCTUnwrap(TextLayout.keyboard(in: webPage, imageSize: phone, region: nil, known: afterBand))
        XCTAssertGreaterThan(afterWhole.top, pageBottom)
        let texts = translated(webPage, keyboard: afterWhole)
        XCTAssertTrue(texts.contains("Hinweise zur Lieferung"))
        XCTAssertTrue(texts.contains("Pakete werden werktags zwischen acht und"))
    }

    /// A reading of a band that holds the strip and the two lower rows of letters but neither the
    /// top row (Vision missed it) nor the bottom row (y 1560 to 2100): nothing was read below the
    /// rows found, and they end where the lowest row of letters ends (2.1 pitches above the
    /// bottom edge), so the row missing lies above them and the keyboard begins a pitch higher:
    /// the suggestions are left out even when no keyboard is known yet
    func testAReadingOfTheLowerRowsAloneBeginsTheKeyboardAboveTheSuggestions() throws {
        let band = Self.lowerRowsOfSearch
        let keyboard = try XCTUnwrap(TextLayout.keyboard(in: band, imageSize: phone))
        XCTAssertLessThan(keyboard.top, 1559)
        XCTAssertTrue(translated(band, keyboard: keyboard).isEmpty)
        // (the two upper rows read alone end higher up: no row is added above them)
        let upper = try XCTUnwrap(TextLayout.keyboard(in: Self.upperRowsOfWebPage, imageSize: phone))
        XCTAssertGreaterThan(upper.top, 1504)
    }

    /// A reading of a band over most of the keys (y 1100 to 1960) in which Vision read the rows of
    /// keys in pieces finds no keyboard: the keyboard known stays, so neither the strip nor the
    /// pieces of keys are translated, and the page's lines in the band are
    func testAPartReadOverMostOfTheKeysInPiecesKeepsTheKeyboard() throws {
        let known = try XCTUnwrap(TextLayout.keyboard(in: webPage, imageSize: phone))
        let lines = Self.webPageAndKeysInPieces
        XCTAssertNil(TextLayout.keyboard(in: lines, imageSize: phone))
        let kept = try XCTUnwrap(TextLayout.keyboard(in: lines, imageSize: phone, region: Self.piecesRegion, known: known))
        XCTAssertEqual(kept, known)
        XCTAssertEqual(translated(lines, keyboard: kept), [
            "oder ändern, und muss nach kurzer Zeit übersetzt sein und übersetzt bleiben.",
            "Hinweise zur Lieferung", "Pakete werden werktags zwischen acht und",
        ])
    }

    /// When the keyboard slid away, what came out from under it may be read in parts that hold
    /// little of its place (a line of the page under the strip): the keyboard ends because the
    /// picture where its keys were has changed, and the line is translated
    func testAKeyboardEndsWhenItsKeysHaveLeftThePicture() throws {
        let known = try XCTUnwrap(TextLayout.keyboard(in: webPage, imageSize: phone))
        let revealed = [line("achtzehn Uhr zugestellt. Wenn niemand zu", 52, 1524, 900, 52, tone: (39, 234, 0))]
        let region = CGRect(x: 0, y: 1500, width: 1080, height: 100)
        let kept = TextLayout.keyboard(in: revealed, imageSize: phone, region: region, known: known)
        XCTAssertEqual(kept, known)
        XCTAssertTrue(translated(revealed, keyboard: kept).isEmpty)
        let ended = TextLayout.keyboard(in: revealed, imageSize: phone, region: region, known: known, keysChanged: true)
        XCTAssertNil(ended)
        XCTAssertEqual(translated(revealed, keyboard: ended), ["achtzehn Uhr zugestellt. Wenn niemand zu"])
        // (a reading that finds the keys keeps the keyboard, whatever the picture did)
        XCTAssertNotNil(TextLayout.keyboard(in: webPage, imageSize: phone, region: nil, known: known, keysChanged: true))
    }

    /// The keys have gone when the cells over them differ by more than `keysGone` on average,
    /// means and spreads together: a pop-up over one key of the 72 cells is not enough; a blank
    /// page of the keyboard's colour, a little darker than the keys and without their letters, is
    func testKeysHaveGoneWhenTheCellsOverThemChangeOnAverage() {
        // mean and spread of each cell: white keys with dark letters on a light grey ground
        let keys = (0..<TextLayout.keyCells).flatMap { cell -> [Double] in
            [228 + Double(cell % 3), 30 + Double(cell % 4)]
        }
        var popUp = keys
        popUp[40] = 150
        popUp[41] = 80
        let blank = (0..<TextLayout.keyCells).flatMap { _ -> [Double] in [223, 0.5] }
        XCTAssertFalse(TextLayout.keysChanged(from: keys, to: keys))
        XCTAssertFalse(TextLayout.keysChanged(from: keys, to: popUp))
        XCTAssertTrue(TextLayout.keysChanged(from: keys, to: blank))
        XCTAssertTrue(TextLayout.keysChanged(from: keys, to: []))
    }

    /// Text copies what the keyboard shows; only Translate leaves it out
    func testTextStillCopiesTheLinesOfTheKeyboard() throws {
        let keyboard = try XCTUnwrap(TextLayout.keyboard(in: settingsSearch, imageSize: phone))
        XCTAssertEqual(TextLayout.content(settingsSearch, imageSize: phone, statusBar: .longerSide, keyboard: keyboard).count,
                       TextLayout.content(settingsSearch, imageSize: phone, statusBar: .longerSide).count)
    }

    // MARK: What is no keyboard

    // The lines below are laid out by hand, with boxes sized as Vision gives them for text of
    // that size on the same phone (a box about 1.1 times the size of the text).

    /// A list of settings with a value on the right of each row, at the bottom of the screen: each
    /// row reaches across the screen with few letters, but its title is set like text
    func testRowsWithATitleOnTheLeftAndAValueOnTheRightAreNoKeyboard() {
        let lines = [
            line("WLAN", 63, 1900, 127, 45), line("An", 960, 1900, 55, 45),
            line("Bluetooth", 63, 2030, 230, 49), line("Aus", 940, 2030, 80, 45),
            line("NFC", 63, 2160, 100, 45), line("An", 960, 2160, 55, 45),
        ]
        XCTAssertNil(TextLayout.keyboard(in: lines, imageSize: phone))
    }

    /// A month at the bottom of the screen: the weekdays over rows of days. Only the weekdays are
    /// spread like keys and hold letters; a single row is no keyboard.
    func testAMonthUnderItsWeekdaysIsNoKeyboard() {
        var lines = [line("November 2026", 63, 1500, 360, 55)]
        lines.append(line("M D M D F S S", 70, 1620, 940, 42))
        for (index, week) in ["2 3 4 5 6 7 8", "9 10 11 12 13 14 15", "16 17 18 19 20 21 22", "23 24 25 26 27 28 29"].enumerated() {
            lines.append(line(week, 70, 1740 + CGFloat(index) * 140, 950, 42))
        }
        lines.append(line("Termine an diesem Tag", 63, 2320, 520, 49))
        XCTAssertNil(TextLayout.keyboard(in: lines, imageSize: phone))
        XCTAssertTrue(TextLayout.content(lines, imageSize: phone, for: .translating,
                                         keyboard: TextLayout.keyboard(in: lines, imageSize: phone))
            .contains { $0.text == "Termine an diesem Tag" })
    }

    /// A heading set with wide letter spacing over a row of tabs and a row of weekdays: the
    /// heading measures like a row of keys, but the words of the tabs and the weekdays are set
    /// like words, and a single row of keys is no keyboard
    func testALetterSpacedHeadingOverRowsOfWordsIsNoKeyboard() {
        let lines = [
            line("S A L E", 200, 1900, 680, 70),
            line("Neu", 60, 2040, 85, 49), line("Beliebt", 430, 2040, 170, 49), line("Angebote", 800, 2040, 210, 49),
            line("Mo", 60, 2160, 62, 42), line("Di", 210, 2160, 45, 42), line("Mi", 360, 2160, 45, 42),
            line("Do", 510, 2160, 60, 42), line("Fr", 660, 2160, 42, 42), line("Sa", 810, 2160, 52, 42),
            line("So", 960, 2160, 55, 42),
        ]
        XCTAssertNil(TextLayout.keyboard(in: lines, imageSize: phone))
    }

    /// An index of letters down the right side of a list of contacts: each letter a line of its
    /// own, not wide
    func testAnIndexOfLettersBesideAListIsNoKeyboard() {
        let lines = (0..<12).map { index in
            line(String("ABCDEFGHIJKL"[String.Index(utf16Offset: index, in: "ABCDEFGHIJKL")]), 1030,
                 1300 + CGFloat(index) * 85, 26, 40)
        }
        XCTAssertNil(TextLayout.keyboard(in: lines, imageSize: phone))
    }

    /// Rows of words in capitals at the bottom of the screen (two buttons, stacked) measure like
    /// text, not like keys
    func testRowsOfWordsInCapitalsAreNoKeyboard() {
        let lines = [
            line("ALLE EINSTELLUNGEN ZURÜCKSETZEN", 80, 2000, 920, 55),
            line("ABBRECHEN UND ZURÜCK ZUR LISTE", 90, 2130, 900, 52),
        ]
        XCTAssertNil(TextLayout.keyboard(in: lines, imageSize: phone))
    }

    /// The same keys in the upper half of a screen (a keyboard shown as a picture in an article)
    /// stand too far from the bottom edge to be the keyboard
    func testRowsOfKeysHighUpOnTheScreenAreNoKeyboard() {
        let lines = settingsSearch.filter { (1640...2060).contains($0.rect.midY * phone.height) }.map { line -> RecognizedLine in
            var moved = line
            moved.rect.origin.y -= 1200 / phone.height
            return moved
        }
        XCTAssertEqual(lines.count, 5)
        XCTAssertNil(TextLayout.keyboard(in: lines, imageSize: phone))
    }
}
