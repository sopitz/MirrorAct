// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CoreVideo
import Vision
import XCTest
@testable import MirrorAct

/// An icon in front of a line that Vision read as a character of the line (`LeadingMark`):
/// the decision on measured parts, the measuring on pixels, and Vision on drawn settings rows.
final class LeadingMarkTests: XCTestCase {
    // MARK: The decision

    /// The live finding: "E Display & Touchbedienung" in a picture of 1080 x 2400, line box
    /// x 90, y 1930, w 760, h 100; the icon (a circle of 40 dp at 2.625x) fills the box's
    /// height, the title is about 50 high and begins after a gap of 16 dp
    func testTheIconOfTheFindingStandsApartAndTheBoxShrinksToTheTitle() throws {
        let line = CGRect(x: 90, y: 1930, width: 760, height: 100)
        let parts = LeadingMark.Parts(mark: CGRect(x: 90, y: 1930, width: 105, height: 100),
                                      rest: CGRect(x: 237, y: 1955, width: 613, height: 50), widestGapInRest: 16)
        let title = "Display & Touchbedienung"
        XCTAssertTrue(LeadingMark.standsApart(parts, restText: title, markOnLeft: true))
        let rect = try XCTUnwrap(LeadingMark.rect(of: parts, line: line, restText: title, markOnLeft: true))
        XCTAssertEqual(rect.minX, 237, accuracy: 1, "no margin: the icon touched the box's edge")
        XCTAssertEqual(rect.maxX, line.maxX, accuracy: 0.5)
        // the title's ink and a fifth of its size above and below, no longer the icon's height
        XCTAssertEqual(rect.height, 50 + 2 * 0.2 * 613 / TextLayout.widthUnits(of: title), accuracy: 1)
        XCTAssertLessThan(rect.height, 75)
        XCTAssertGreaterThanOrEqual(rect.minY, line.minY)
        XCTAssertLessThanOrEqual(rect.maxY, line.maxY)
    }

    /// Lines in which Vision on macOS 26 read a drawn icon as a character (rows drawn with
    /// AppKit and SF Symbols as in `SettingsRows`, read with the app's request settings): the
    /// line's box, the ink of the character and of the rest measured in the pixels, the widest
    /// gap between the rest's words, all in frame pixels
    static let icons: [Recorded] = [
        // 2x, bare 24 pt symbol, gap 12, title 16 pt
        Recorded("• System", line: [45, 463, 178, 40], mark: [45, 462, 38, 38], rest: [113, 467, 105, 30], gap: 2),
        Recorded("= Akku", line: [43, 798, 146, 37], mark: [42, 801, 43, 31], rest: [113, 803, 70, 25], gap: 2),
        // the narrowest gaps: 0.66 and 0.63 of the text's size
        Recorded("• Benachrichtigungen", line: [45, 912, 361, 38], mark: [45, 915, 47, 26], rest: [114, 914, 287, 31], gap: 3),
        Recorded(") Storage", line: [119, 529, 260, 55], mark: [119, 528, 13, 51], rest: [170, 529, 203, 55], gap: 5),
        Recorded("- Connected devices", line: [37, 1572, 357, 52], mark: [43, 1580, 41, 41], rest: [113, 1586, 278, 26], gap: 11),
        // a rounded square of 24 pt, gap 20, title 20 pt, at 2.625x
        Recorded("• Bedienungshilfen", line: [49, 1334, 520, 66], mark: [52, 1333, 64, 64], rest: [172, 1344, 391, 50], gap: 6),
        // with a summary below: the box reaches from the title's top to the icon's bottom
        Recorded("A Emergency", line: [59, 891, 385, 73], mark: [61, 891, 65, 68], rest: [182, 905, 256, 48], gap: 5),
        Recorded("• Location", line: [63, 1426, 332, 97], mark: [78, 1471, 36, 36], rest: [172, 1431, 219, 46], gap: 6),
        // written from the right: the icon on the right is the string's first character
        Recorded("• الشاشة واللمس", line: [604, 897, 419, 60], mark: [960, 909, 63, 33], rest: [619, 903, 312, 49], gap: 17),
        Recorded("ج حول الهاتف", line: [683, 742, 361, 77], mark: [969, 756, 56, 43], rest: [701, 756, 232, 49], gap: 18),
    ]

    /// Real characters before a word (Core Text, SF and Helvetica, 14 to 22 pt): the widest
    /// gaps measured, 0.38 to 0.45 of the text's size
    static let characters: [Recorded] = [
        Recorded("• Dunkles Design einschalten", line: [37, 239, 380, 30], mark: [43, 250, 7, 6], rest: [62, 239, 353, 28], gap: 10),
        Recorded("• System", line: [37, 292, 120, 28], mark: [43, 301, 7, 6], rest: [61, 292, 94, 25], gap: 3),
        Recorded("à la carte", line: [49, 1050, 161, 33], mark: [53, 1050, 17, 30], rest: [85, 1051, 122, 29], gap: 13),
        Recorded("e Mail Adresse", line: [49, 1320, 251, 35], mark: [53, 1327, 19, 21], rest: [86, 1319, 212, 29], gap: 13),
        Recorded("Ö Bank Filiale", line: [52, 1379, 230, 38], mark: [54, 1380, 25, 35], rest: [93, 1386, 187, 29], gap: 12),
    ]

    func testRecordedIconsStandApartAndTheirBoxesLeaveTheIconOut() throws {
        for icon in Self.icons {
            let split = try XCTUnwrap(LeadingMark.split(icon.text), icon.text)
            let rest = String(icon.text[split.rest])
            let left = !BlockTextMask.isRightToLeft(rest)
            XCTAssertTrue(LeadingMark.standsApart(icon.parts, restText: rest, markOnLeft: left), icon.text)
            let rect = try XCTUnwrap(LeadingMark.rect(of: icon.parts, line: icon.line, restText: rest, markOnLeft: left), icon.text)
            XCTAssertTrue(icon.line.contains(rect), icon.text)
            XCTAssertFalse(rect.intersects(icon.parts.mark), icon.text)
            XCTAssertTrue(rect.contains(icon.parts.rest), icon.text)
        }
    }

    func testBulletsAndShortWordsStay() throws {
        for character in Self.characters {
            let split = try XCTUnwrap(LeadingMark.split(character.text), character.text)
            XCTAssertFalse(LeadingMark.standsApart(character.parts, restText: String(character.text[split.rest]), markOnLeft: true),
                           character.text)
        }
    }

    /// A bullet set off far, as a web page's list may do, stays: its ink is small
    func testASmallMarkStaysHoweverFarItStands() {
        let parts = LeadingMark.Parts(mark: CGRect(x: 40, y: 20, width: 8, height: 8),
                                      rest: CGRect(x: 120, y: 10, width: 120, height: 30), widestGapInRest: nil)
        XCTAssertFalse(LeadingMark.standsApart(parts, restText: "System", markOnLeft: true))
        var big = parts
        big.mark = CGRect(x: 40, y: 10, width: 30, height: 30)
        XCTAssertTrue(LeadingMark.standsApart(big, restText: "System", markOnLeft: true))
    }

    /// Text set wide (justified) has wide gaps between all its words: the character's gap must
    /// also be wider than those
    func testAGapNoWiderThanTheGapsBetweenTheWordsStays() {
        let parts = LeadingMark.Parts(mark: CGRect(x: 0, y: 0, width: 30, height: 30),
                                      rest: CGRect(x: 60, y: 0, width: 600, height: 30), widestGapInRest: 25)
        XCTAssertFalse(LeadingMark.standsApart(parts, restText: "Dies ist ein Satz mit vielen Worten", markOnLeft: true))
    }

    /// A word set apart from its text sits on the text's baseline and stays; an icon read as a
    /// letter is centred on the row, ends below the baseline and goes; a sign keeps the rule of
    /// the gap
    func testAWordOnTheBaselineStaysAndAnIconReadAsALetterGoes() throws {
        // "Mo", a gap of about the text's size before "Zahnarzt" (3.86 units wide: size 40)
        let rest = "Zahnarzt"
        var word = LeadingMark.Parts(mark: CGRect(x: 0, y: 10, width: 50, height: 29),
                                     rest: CGRect(x: 92, y: 10, width: 154.4, height: 30), widestGapInRest: nil,
                                     restBaseline: 39, markColumnEnds: Array(repeating: 39, count: 50))
        let size = try XCTUnwrap(TextLayout.textSize(of: rest, width: 154.4))
        XCTAssertEqual(size, 40, accuracy: 0.01)
        XCTAssertTrue(LeadingMark.standsApart(word, restText: rest, markOnLeft: true), "the gap alone would cut it")
        XCTAssertTrue(LeadingMark.sitsLikeText(word, markText: "Mo", restText: rest))
        // a descender ("go"): the ink ends lower, but a third of the columns end on the baseline
        word.mark.size.height = 29 + 0.2 * size
        word.markColumnEnds = Array(repeating: 39, count: 17) + Array(repeating: 39 + 0.2 * size, count: 33)
        XCTAssertTrue(LeadingMark.sitsLikeText(word, markText: "go", restText: rest))
        // the same shape as a sign: the gap decides
        XCTAssertFalse(LeadingMark.sitsLikeText(word, markText: "€", restText: rest))
        // an icon read as "Aa": centred on the row, it ends 0.09 of the text's size below the
        // baseline, and only a few of its columns end on it
        var icon = word
        icon.mark = CGRect(x: 0, y: 6, width: 50, height: 33 + 0.09 * size)
        icon.markColumnEnds = Array(repeating: 39, count: 7) + Array(repeating: icon.mark.maxY, count: 43)
        XCTAssertFalse(LeadingMark.sitsLikeText(icon, markText: "Aa", restText: rest))
        // higher than text: an icon, wherever it ends
        icon.mark = CGRect(x: 0, y: 39 - 1.2 * size, width: 50, height: 1.2 * size)
        icon.markColumnEnds = Array(repeating: 39, count: 50)
        XCTAssertFalse(LeadingMark.sitsLikeText(icon, markText: "E", restText: rest))
        // not measured: nothing to go by
        icon.restBaseline = nil
        XCTAssertFalse(LeadingMark.sitsLikeText(icon, markText: "E", restText: rest))
    }

    /// The magnifier of Android's search field, read as "Q" with the field's text (light theme,
    /// font scale 1; the parts as measured in the frame): the tip of its handle ends on the
    /// baseline, but few of its columns do, and a Q's tail would end lower. It goes. A real Q
    /// set apart before a word ("Q   Questions", measured the same way) ends below the baseline
    /// with half of its columns on it, and stays.
    func testTheMagnifierOfASearchFieldGoesAndAQStays() {
        let field = "In Einstellungen suchen"
        let magnifier = LeadingMark.Parts(
            mark: CGRect(x: 113, y: 155, width: 46, height: 46), rest: CGRect(x: 193, y: 159, width: 547, height: 51),
            widestGapInRest: 20, restBaseline: 199,
            markColumnEnds: [177, 180, 181, 183, 184, 185, 186, 187, 187, 188, 188, 188, 189, 189, 189, 189, 189, 189,
                             189, 189, 189, 189, 188, 188, 187, 187, 186, 187, 188, 189, 190, 191, 192, 193, 194, 195,
                             196, 197, 198, 199, 200, 201, 200, 199, 198, 198])
        XCTAssertTrue(LeadingMark.standsApart(magnifier, restText: field, markOnLeft: true))
        XCTAssertFalse(LeadingMark.sitsLikeText(magnifier, markText: "Q", restText: field))
        // (any other letter that ends on the baseline sits like text)
        XCTAssertTrue(LeadingMark.sitsLikeText(magnifier, markText: "O", restText: field))
        let questions = LeadingMark.Parts(
            mark: CGRect(x: 44, y: 2270, width: 21, height: 30), rest: CGRect(x: 98, y: 2270, width: 162, height: 30),
            widestGapInRest: 4, restBaseline: 2296,
            markColumnEnds: [2289, 2291, 2293, 2294, 2294, 2295, 2296, 2296, 2296, 2296, 2296, 2296, 2296, 2296, 2297,
                             2298, 2299, 2299, 2300, 2300, 2299])
        XCTAssertTrue(LeadingMark.standsApart(questions, restText: "Questions", markOnLeft: true))
        XCTAssertTrue(LeadingMark.sitsLikeText(questions, markText: "Q", restText: "Questions"))
    }

    /// A Q set apart before a word, drawn in the system font and in Helvetica at 2x and 3x, stays
    /// wherever Vision reads it with its word as one line
    func testAQSetApartBeforeAWordStays() throws {
        var together = 0
        for scale: CGFloat in [2, 3] {
            for font in [nil, "Helvetica"] as [String?] {
                for gap: CGFloat in [0.6, 1.0, 1.4] {
                    var columns = Columns(scale: scale, fontName: font, gap: gap)
                    columns.words = [("Q", "Questions"), ("Q", "Quellen"), ("Q", "Quartal 3")]
                    let (frame, rows) = try columns.frame()
                    let height = CGFloat(CVPixelBufferGetHeight(frame))
                    let read = try Self.visionLines(frame)
                    let found = try TextRecognizer.lines(in: frame)
                    for row in rows {
                        func onRow(_ rect: CGRect) -> Bool { abs(rect.midY * height - row.rest.midY) < row.rest.height / 2 }
                        guard read.contains(where: { onRow($0.rect) && $0.text.hasPrefix("Q ") }) else { continue }
                        together += 1
                        XCTAssertTrue(found.contains { onRow($0.rect) && $0.text.hasPrefix("Q ") },
                                      "\(scale)x \(font ?? "system") gap \(gap): \(found.filter { onRow($0.rect) }.map(\.text))")
                    }
                }
            }
        }
        XCTAssertGreaterThan(together, 6, "Vision read too few Qs with their word")
    }

    func testWhatCountsAsALoneCharacter() {
        func mark(_ text: String) -> String? { LeadingMark.split(text).map { String(text[$0.mark]) } }
        XCTAssertEqual(mark("E Display & Touchbedienung"), "E")
        XCTAssertEqual(mark("© Storage"), "©")
        XCTAssertEqual(mark("إمكانية الوصول E"), "E")
        XCTAssertEqual(mark("Aa Über das Telefon"), "Aa")
        XCTAssertNil(mark("1. Open the settings"), "a list number")
        XCTAssertNil(mark("a) Erste Möglichkeit"), "a list number")
        XCTAssertEqual(mark("10 Geräte verbunden"), "10", "a number: the pixels decide")
        XCTAssertNil(mark("Settings"))
        XCTAssertNil(mark("• 5"), "the rest has no two letters")
        XCTAssertNil(mark("WLAN ist eingeschaltet"))
    }

    // MARK: Measuring in the pixels

    /// Icon, gap and title as blocks of ink; the line's box reaches into the summary below
    func testPartsAreMeasuredInThePixelsAndTheTitlesBandIsTaken() throws {
        let width = 400, height = 100
        var values = [UInt8](repeating: 245, count: width * height)
        func fill(_ rect: CGRect, _ value: UInt8 = 20) {
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) { values[y * width + x] = value }
            }
        }
        fill(CGRect(x: 5, y: 10, width: 80, height: 80)) // the icon
        // the title: two words, the letters 3 apart, the words 14
        for x in stride(from: 120, to: 220, by: 13) { fill(CGRect(x: x, y: 20, width: 10, height: 40)) }
        for x in stride(from: 235, to: 380, by: 13) { fill(CGRect(x: x, y: 20, width: 10, height: 40)) }
        fill(CGRect(x: 120, y: 80, width: 250, height: 15)) // the top of the summary
        let raster = LumaRaster(x: 1000, y: 500, width: width, height: height, values: values)
        let parts = try XCTUnwrap(LeadingMark.parts(of: raster, markOnLeft: true, hint: 1000 + 110))
        XCTAssertEqual(parts.mark, CGRect(x: 1005, y: 510, width: 80, height: 80))
        XCTAssertEqual(parts.rest, CGRect(x: 1120, y: 520, width: 268, height: 40))
        XCTAssertEqual(parts.widestGapInRest, 14)
        // from the right, as for a line written from the right
        let mirrored = LumaRaster(x: 0, y: 0, width: width, height: height,
                                  values: (0..<height).flatMap { y in (0..<width).reversed().map { values[y * width + $0] } })
        let fromRight = try XCTUnwrap(LeadingMark.parts(of: mirrored, markOnLeft: false, hint: 290))
        XCTAssertEqual(fromRight.mark, CGRect(x: 400 - 85, y: 10, width: 80, height: 80))
        XCTAssertEqual(fromRight.rest.maxX, 400 - 120)
    }

    /// The whole step on a line as Vision gives it: an icon on the left is left out; the same
    /// character on the right of a line written from the left (a value: "Pixel 8") stays
    func testRemovedLeavesOutTheIconAndKeepsACharacterAtTheEnd() throws {
        let frame = CGSize(width: 1000, height: 1000)
        let width = 500, height = 60
        var values = [UInt8](repeating: 245, count: width * height)
        func fill(_ x: Range<Int>, _ y: Range<Int>) {
            for row in y { for column in x { values[row * width + column] = 20 } }
        }
        fill(0..<50, 5..<55)
        for x in stride(from: 90, to: 480, by: 26) { fill(x..<(x + 22), 15..<50) }
        let raster = LumaRaster(x: 100, y: 300, width: width, height: height, values: values)
        let line = RecognizedLine(text: "E Display und Touch", rect: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.06), confidence: 0.5)
        let removed = LeadingMark.removed(from: line, frameSize: frame, boxOf: { range in
            // as Vision does: the rest begins right after an ordinary space
            range.lowerBound == line.text.startIndex ? CGRect(x: 0.1, y: 0.3, width: 0.02, height: 0.06)
                : CGRect(x: 0.125, y: 0.3, width: 0.475, height: 0.06)
        }, luma: { _ in raster })
        XCTAssertEqual(removed.text, "Display und Touch")
        XCTAssertEqual(removed.confidence, 0.5)
        XCTAssertEqual(removed.rect.minX, 0.19, accuracy: 0.001)
        XCTAssertEqual(removed.rect.maxX, line.rect.maxX, accuracy: 0.0001)

        let value = RecognizedLine(text: "Display und Touch 8", rect: line.rect)
        let kept = LeadingMark.removed(from: value, frameSize: frame, boxOf: { range in
            range.upperBound == value.text.endIndex && range.lowerBound > value.text.startIndex
                ? CGRect(x: 0.58, y: 0.3, width: 0.02, height: 0.06) : CGRect(x: 0.1, y: 0.3, width: 0.47, height: 0.06)
        }, luma: { _ in raster })
        XCTAssertEqual(kept, value)
    }

    // MARK: Vision on drawn rows

    /// Settings rows (`SettingsRows`: SF Symbols without a backdrop,
    /// 24 pt, a gap of 12 pt, titles of 16 pt, at 2.625x; and with a summary, 32 pt icons and
    /// 20 pt titles, where the line's box grows tall). On macOS 26 Vision reads about every
    /// third icon as a character of its title. No line may reach into an icon.
    func testNoLineReachesIntoTheIconOfItsRow() throws {
        for (format, name) in [(kCVPixelFormatType_32BGRA, "BGRA"), (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "4:2:0")] {
            for rows in [SettingsRows(seed: 420), SettingsRows(seed: 434, iconSize: 32, gap: 16, titleSize: 20, summary: true)] {
                let (frame, drawn) = try rows.frame(format: format)
                let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
                let found = try TextRecognizer.lines(in: frame)
                XCTAssertGreaterThan(found.count, drawn.count / 2, "\(name): \(found.map(\.text))")
                for line in found {
                    let rect = CGRect(x: line.rect.minX * size.width, y: line.rect.minY * size.height,
                                      width: line.rect.width * size.width, height: line.rect.height * size.height)
                    for row in drawn where rect.intersects(row.title) {
                        XCTAssertGreaterThan(rect.minX, row.icon.maxX - 2, "\(name): '\(line.text)' \(rect) icon \(row.icon)")
                        XCTAssertLessThan(rect.height, 1.6 * row.title.height, "\(name): '\(line.text)' \(rect)")
                    }
                }
            }
        }
    }

    /// The same rows with every icon a pixel higher, as the icons come out where a display at
    /// scale 1 lays the symbols out or where the stream puts them a pixel off. The "textformat"
    /// icon is the letters "Aa", centred on its row; raised by a pixel its ink ends 0.07 of the
    /// title's size below the title's baseline and a third of its columns end there, so it sits
    /// like text, and LeadingMark keeps it as a word in front of "Über das Telefon": a limit of
    /// the rule, which cannot tell such an icon from a short word set apart. Every other row
    /// keeps its icon out of the line.
    func testNoLineReachesIntoAnIconAPixelHigher() throws {
        for (format, name) in [(kCVPixelFormatType_32BGRA, "BGRA"), (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "4:2:0")] {
            for rows in [SettingsRows(seed: 420, iconOffset: -1),
                         SettingsRows(seed: 434, iconSize: 32, gap: 16, titleSize: 20, summary: true, iconOffset: -1)] {
                let (frame, drawn) = try rows.frame(format: format)
                let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
                let found = try TextRecognizer.lines(in: frame)
                XCTAssertGreaterThan(found.count, drawn.count / 2, "\(name): \(found.map(\.text))")
                for line in found {
                    let rect = CGRect(x: line.rect.minX * size.width, y: line.rect.minY * size.height,
                                      width: line.rect.width * size.width, height: line.rect.height * size.height)
                    for row in drawn where rect.intersects(row.title) {
                        XCTAssertLessThan(rect.height, 1.6 * row.title.height, "\(name): '\(line.text)' \(rect)")
                        let outside = { XCTAssertGreaterThan(rect.minX, row.icon.maxX - 2, "\(name): '\(line.text)' \(rect) icon \(row.icon)") }
                        if line.text.hasPrefix("Aa ") {
                            XCTExpectFailure("the textformat icon sits like text", options: .nonStrict(), failingBlock: outside)
                        } else {
                            outside()
                        }
                    }
                }
            }
        }
    }

    /// Running text keeps its first character: bullets, signs, one-letter words and initials
    func testRunningTextKeepsItsFirstCharacter() throws {
        let texts = ["• Dunkles Design einschalten", "$ 12.99 per month", "E Display & Touchbedienung",
                     "A new version is available", "3 new messages", "Ö Bank Filiale", "€ 4,99 im Monat"]
        for fontSize: CGFloat in [36, 48, 60] {
            let lines = texts.enumerated().map { TestFrames.Line(text: $1, x: 60, top: 60 + CGFloat($0) * fontSize * 2, fontSize: fontSize) }
            let (frame, inked) = try TestFrames.text(lines, width: 1080, height: 1200, format: kCVPixelFormatType_32BGRA)
            let found = try TextRecognizer.lines(in: frame)
            for (index, text) in texts.enumerated() {
                let ink = inked[index]
                let line = found.first { abs($0.rect.midY * 1200 - ink.midY) < ink.height / 2 }
                guard let line else { XCTFail("\(fontSize): '\(text)' not read: \(found.map(\.text))"); continue }
                // a removed character would move the left edge by its width and the gap
                XCTAssertEqual(line.rect.minX * 1080, ink.minX, accuracy: 0.3 * fontSize, "\(fontSize): '\(line.text)'")
                XCTAssertNotEqual(line.text, String(text.drop { $0 != " " }.dropFirst()), "\(fontSize): '\(line.text)'")
            }
        }
        // a quantity, a weekday or a day number set apart from its text, as in a list, an agenda
        // or a receipt, and a short word before a gap widened by justified text: where Vision
        // reads the word and its text as one line, the word stays (at wide gaps Vision itself
        // often reads the word as a line of its own, or not at all)
        var together = 0
        for scale: CGFloat in [2, 3] {
            for font in [nil, "Helvetica"] as [String?] {
                for gap: CGFloat in [0.6, 1.0] {
                    let (frame, rows) = try Columns(scale: scale, fontName: font, gap: gap).frame()
                    let height = CGFloat(CVPixelBufferGetHeight(frame)), width = CGFloat(CVPixelBufferGetWidth(frame))
                    let read = try Self.visionLines(frame)
                    let found = try TextRecognizer.lines(in: frame)
                    let name = "\(scale)x \(font ?? "system") gap \(gap)"
                    for row in rows {
                        func onRow(_ rect: CGRect) -> Bool { abs(rect.midY * height - row.rest.midY) < row.rest.height / 2 }
                        func hasWord(_ text: String) -> Bool {
                            text.split(separator: " ").count >= 2
                                && text.split(separator: " ")[0].caseInsensitiveCompare(row.first) == .orderedSame
                        }
                        guard read.contains(where: { onRow($0.rect) && hasWord($0.text) }) else { continue }
                        together += 1
                        let line = found.first { onRow($0.rect) && hasWord($0.text) }
                        XCTAssertNotNil(line, "\(name): '\(row.first)' left out: \(found.filter { onRow($0.rect) }.map(\.text))")
                        if let line {
                            XCTAssertLessThanOrEqual(line.rect.minX * width, row.word.midX, "\(name): '\(line.text)'")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(together, Columns.rows.count * 8 / 4, "Vision read too few words with their text")
    }

    /// The lines as Vision reads them with the settings of `TextRecognizer`, without its steps
    static func visionLines(_ frame: CVPixelBuffer) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.004
        try VNImageRequestHandler(cvPixelBuffer: frame, options: [:]).perform([request])
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map {
                RecognizedLine(text: $0.string, rect: TextRecognizer.frameRect(of: observation.boundingBox, in: whole))
            }
        }
    }

    // MARK: Helpers

    struct Recorded {
        var text: String
        var line: CGRect
        var parts: LeadingMark.Parts

        init(_ text: String, line: [CGFloat], mark: [CGFloat], rest: [CGFloat], gap: CGFloat?) {
            self.text = text
            self.line = CGRect(x: line[0], y: line[1], width: line[2], height: line[3])
            parts = LeadingMark.Parts(mark: CGRect(x: mark[0], y: mark[1], width: mark[2], height: mark[3]),
                                      rest: CGRect(x: rest[0], y: rest[1], width: rest[2], height: rest[3]),
                                      widestGapInRest: gap)
        }
    }

    /// Rows of a short word, a gap of `gap` times the font's size and a text, drawn with AppKit
    /// in 17 pt (the system font or `fontName`), dark on light, on a screen 390 pt wide
    struct Columns {
        static let rows = [("5", "Kaffee"), ("2x", "Milch"), ("Mo", "Zahnarzt"), ("Fr", "Abendessen mit Anna"),
                           ("24", "Geburtstag Oma"), ("Im", "Gegensatz"), ("go", "Weiter"), ("Qi", "Gong")]
        var scale: CGFloat
        var fontName: String?
        var gap: CGFloat
        var size: CGFloat = 17
        /// the word and the text of each row
        var words = Columns.rows

        /// The frame and, in frame pixels, every row's word and text
        func frame() throws -> (CVPixelBuffer, [(first: String, word: CGRect, rest: CGRect)]) {
            let widthPt: CGFloat = 390, rowPt = size * 2.4
            let heightPt = CGFloat(words.count) * rowPt + 60
            let width = Int((widthPt * scale).rounded()), height = Int((heightPt * scale).rounded())
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = NSSize(width: widthPt, height: heightPt)
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            context.cgContext.translateBy(x: 0, y: heightPt)
            context.cgContext.scaleBy(x: 1, y: -1)
            NSColor(white: 0.97, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: widthPt, height: heightPt).fill()
            let font = try XCTUnwrap(fontName.map { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.1, alpha: 1)]
            var drawn: [(first: String, word: CGRect, rest: CGRect)] = []
            for (index, (first, rest)) in words.enumerated() {
                let top = 30 + CGFloat(index) * rowPt
                let wordSize = (first as NSString).size(withAttributes: attributes)
                (first as NSString).draw(at: NSPoint(x: 24, y: top), withAttributes: attributes)
                let restX = 24 + wordSize.width + gap * size
                (rest as NSString).draw(at: NSPoint(x: restX, y: top), withAttributes: attributes)
                let restSize = (rest as NSString).size(withAttributes: attributes)
                let pixels = CGAffineTransform(scaleX: scale, y: scale)
                drawn.append((first, CGRect(origin: CGPoint(x: 24, y: top), size: wordSize).applying(pixels),
                              CGRect(origin: CGPoint(x: restX, y: top), size: restSize).applying(pixels)))
            }
            NSGraphicsContext.restoreGraphicsState()
            let data = try XCTUnwrap(rep.bitmapData)
            var gray = [UInt8](repeating: 0, count: width * height)
            for row in 0..<height {
                for column in 0..<width {
                    let pixel = data + row * rep.bytesPerRow + column * 4
                    let red: Int = Int(pixel[0]) * 299, green: Int = Int(pixel[1]) * 587, blue: Int = Int(pixel[2]) * 114
                    gray[row * width + column] = UInt8((red + green + blue) / 1000)
                }
            }
            return (try TestFrames.frame(from: gray, width: width, height: height, format: kCVPixelFormatType_32BGRA), drawn)
        }
    }

    /// Rows of a settings screen of 412 x 915 pt drawn with AppKit at 2.625x: an SF Symbol
    /// without a backdrop, a gap, a title in the system font, optionally a summary below. The
    /// picture is the same whatever displays the Mac has (see `symbol`) and whatever its settings:
    /// light appearance, text without font smoothing, as a phone draws it.
    struct SettingsRows {
        var seed: Int
        var iconSize: CGFloat = 24, gap: CGFloat = 12, titleSize: CGFloat = 16
        var summary = false
        var scale: CGFloat = 2.625
        /// Moves every icon down by this many frame pixels (up when negative)
        var iconOffset: CGFloat = 0

        /// A symbol of `pointSize` and the size to draw it in. NSImage lays a symbol out on the
        /// pixels of the displays attached: with one display at scale 1 its size and the inset of
        /// its glyph are whole points ("textformat" at 19.2 pt: 26 x 16, the glyph 22 x 14 at 2, 1;
        /// in fact 26.27 x 16.48 and 21.49 x 13.86 at 2.39, 1.31), and drawn at 2.625x the icon
        /// came out up to two pixels smaller and higher than with displays at scale 2. Made a
        /// hundred times as large, where that rounding no longer shows, and drawn at its exact
        /// size, the symbol (a vector image) is the same on any Mac.
        static func symbol(_ name: String, pointSize: CGFloat, color: NSColor) -> (image: NSImage, size: CGSize)? {
            let enlarged: CGFloat = 100
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize * enlarged, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))) else { return nil }
            return (image, CGSize(width: image.size.width / enlarged, height: image.size.height / enlarged))
        }

        static let symbols = ["display", "internaldrive", "info.circle", "gearshape", "lock.fill", "wifi", "battery.100",
                              "bell.fill", "person.crop.circle", "key.fill", "line.3.horizontal", "textformat", "sun.max",
                              "paintbrush", "shield", "square.grid.2x2", "location", "accessibility", "hand.raised", "iphone",
                              "e.circle", "list.bullet", "a.circle", "c.circle", "network", "speaker.wave.2"]
        static let titles = ["Display & Touchbedienung", "Speicher", "System", "App-Sicherheit", "Netzwerk & Internet", "Akku",
                             "Benachrichtigungen", "Passwörter & Konten", "Datenschutz", "Standort", "Bedienungshilfen",
                             "Über das Telefon", "Connected devices", "Apps", "Sound & vibration", "Wallpaper & style",
                             "Digital Wellbeing", "Google", "Notifications", "Battery", "Storage", "Security & privacy",
                             "Emergency", "Location", "Display", "Accessibility"]
        static let summaries = ["Dunkles Design, Schriftgröße, Helligkeit", "52 % belegt – 61,4 GB frei",
                                "Sprachen, Gesten, Zeit, Sicherung", "Displaysperre, Gerät finden", "WLAN, mobile Daten", "100 %",
                                "Verlauf, Unterhaltungen", "Gespeicherte Passwörter, automatisch ausfüllen",
                                "Berechtigungen, Kontoaktivität", "Aus", "Bildschirmleser, Anzeige, Interaktion", "Pixel 8",
                                "Bluetooth, Kopplung", "Assistant, zuletzt verwendete Apps", "Lautstärke, Vibration",
                                "Farben, Designs"]

        /// The frame and, in frame pixels, the icon and the title of every row
        func frame(format: OSType) throws -> (CVPixelBuffer, [(icon: CGRect, title: CGRect)]) {
            let widthPt: CGFloat = 412, heightPt: CGFloat = 915
            let width = Int((widthPt * scale).rounded()), height = Int((heightPt * scale).rounded())
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = NSSize(width: widthPt, height: heightPt)
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            context.cgContext.translateBy(x: 0, y: heightPt)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.setShouldSmoothFonts(false)
            var drawn: [(icon: CGRect, title: CGRect)] = []
            appearance.performAsCurrentDrawingAppearance {
                NSColor(white: 0.97, alpha: 1).setFill()
                NSRect(x: 0, y: 0, width: widthPt, height: heightPt).fill()
                let foreground = NSColor(white: 0.1, alpha: 1), secondary = NSColor(white: 0.4, alpha: 1)
                let tints: [NSColor] = [.systemBlue, .systemGreen, .systemOrange, .systemRed, .systemPurple, .systemTeal,
                                        .systemGray, .systemPink]
                let rowHeight = summary ? max(iconSize + 24, 72) : max(iconSize + 20, 56)
                var y: CGFloat = 100, index = seed
                while y + rowHeight < heightPt - 20 {
                    let icon = NSRect(x: 20, y: y + (rowHeight - iconSize) / 2, width: iconSize, height: iconSize)
                    if let symbol = Self.symbol(Self.symbols[index % Self.symbols.count], pointSize: iconSize * 0.8,
                                                color: index % 2 == 0 ? foreground : tints[index % tints.count]) {
                        let size = symbol.size
                        symbol.image.draw(in: NSRect(x: icon.midX - size.width / 2, y: icon.midY - size.height / 2 + iconOffset / scale,
                                                     width: size.width, height: size.height),
                                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    }
                    let title = Self.titles[index % Self.titles.count] as NSString
                    let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: titleSize),
                                                                          .foregroundColor: foreground]
                    let summaryAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: titleSize * 0.82),
                                                                            .foregroundColor: secondary]
                    let summaryText = Self.summaries[index % Self.summaries.count] as NSString
                    let titleExtent = title.size(withAttributes: titleAttributes)
                    let block = summary ? titleExtent.height + 2 + summaryText.size(withAttributes: summaryAttributes).height
                        : titleExtent.height
                    let origin = NSPoint(x: icon.maxX + gap, y: y + (rowHeight - block) / 2)
                    title.draw(at: origin, withAttributes: titleAttributes)
                    if summary {
                        summaryText.draw(at: NSPoint(x: origin.x, y: origin.y + titleExtent.height + 2), withAttributes: summaryAttributes)
                    }
                    let titleRect = CGRect(origin: origin, size: titleExtent)
                    drawn.append((icon.applying(CGAffineTransform(scaleX: scale, y: scale)),
                                  titleRect.applying(CGAffineTransform(scaleX: scale, y: scale))))
                    y += rowHeight
                    index += 1
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            // as gray values, which both pixel formats can show
            let data = try XCTUnwrap(rep.bitmapData)
            var gray = [UInt8](repeating: 0, count: width * height)
            for row in 0..<height {
                for column in 0..<width {
                    let pixel = data + row * rep.bytesPerRow + column * 4
                    let red: Int = Int(pixel[0]) * 299, green: Int = Int(pixel[1]) * 587, blue: Int = Int(pixel[2]) * 114
                    gray[row * width + column] = UInt8((red + green + blue) / 1000)
                }
            }
            return (try TestFrames.frame(from: gray, width: width, height: height, format: format), drawn)
        }
    }
}
