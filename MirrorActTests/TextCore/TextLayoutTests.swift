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
        XCTAssertTrue(blocks.allSatisfy { $0.cutOffEdges == 0 })
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

    /// Android settings: every entry has a title and a smaller summary right below it, which may
    /// take two lines; an icon in front. (Android's summary is about 1.4 times smaller than the
    /// title; the closer sizes of iOS are told apart only by colour, see `TextLayoutJoinTests`.)
    func testTitlesAndSummariesOfAndroidSettingsAreSeparate() {
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

    // MARK: The brightness of the letters

    /// A line as Vision gave it, with the brightness of its letters and of the background and
    /// the share of coloured letters as the recognizer measured them in the picture
    /// (`RecognizedLine.tone`). The titles and summaries of the rows below measured 0 in every
    /// frame they appear in: black, white and grey letters.
    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                      tone: (text: Double, background: Double, colour: Double)) -> RecognizedLine {
        var line = line(text, x, y, width, height)
        line.tone = RecognizedLine.Tone(text: tone.text, background: tone.background, colour: tone.colour)
        return line
    }

    /// Network & internet, light: Android sets the title of a row black and its summary grey.
    /// "VPN" and "Kein VPN" are too short to measure their size, and their boxes (45 and 36
    /// pixels) are about as high as those of the lines of a paragraph; "Privates DNS" over "An"
    /// alike. Their letters tell them apart. A summary of two lines is one paragraph.
    func testTheTitleAndTheSummaryOfARowAreSetInDifferentColours() {
        let lines = [
            line("Hotspot und Tethering", 192, 1155, 523, 56, tone: (28, 238, 0)),
            line("Aus", 188, 1224, 63, 35, tone: (80, 238, 0)),
            line("VPN", 188, 1566, 108, 45, tone: (28, 238, 0)),
            line("Kein VPN", 188, 1635, 157, 36, tone: (80, 238, 0)),
            line("Privates DNS", 63, 1772, 314, 49, tone: (28, 238, 0)),
            line("An", 63, 1845, 45, 31, tone: (80, 238, 0)),
            line("Sicherheit des Mobilfunknetzes", 63, 2180, 739, 53, tone: (28, 238, 0)),
            line("Netzwerktyp, Verschlüsselung,", 63, 2253, 505, 42, tone: (80, 238, 0)),
            line("Benachrichtigungseinstellungen", 63, 2299, 526, 38, tone: (80, 238, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: phone).map(\.text), [
            "Hotspot und Tethering", "Aus", "VPN", "Kein VPN", "Privates DNS", "An", "Sicherheit des Mobilfunknetzes",
            "Netzwerktyp, Verschlüsselung, Benachrichtigungseinstellungen",
        ])
        XCTAssertEqual(TextLayout.plainText(lines, imageSize: phone).components(separatedBy: "\n").count, 8)
    }

    /// The main list and the display settings, light. The summary of "Ton & Vibration" measures
    /// 1.39 times smaller, but the two lines lie as close as lines of a paragraph and their boxes
    /// are as high (49 and 48 pixels), so their sizes alone do not split them; nor do those of
    /// "Dunkles Design" over a summary of two lines whose first box reaches up to it. The title
    /// of the display page takes two lines of one colour and stays one paragraph.
    func testATitleIsNotPartOfTheSummaryBelowItEvenWhenTheirBoxesAreAlike() {
        let lines = [
            line("Ton & Vibration", 209, 1528, 362, 49, tone: (28, 250, 0)),
            line("Lautstärke und Haptik", 202, 1589, 374, 48, tone: (80, 250, 0)),
            line("Display &", 59, 342, 415, 126, tone: (28, 238, 0)),
            line("Touchbedienung", 58, 479, 700, 105, tone: (28, 238, 0)),
            line("Dunkles Design", 63, 1720, 366, 56, tone: (28, 238, 0)),
            line("Wird aktiviert, wenn der Modus „Bedtime\"", 62, 1786, 684, 52, tone: (80, 238, 0)),
            line("beginnt", 63, 1835, 129, 39, tone: (80, 238, 0)),
            line("Akkunutzung von Apps", 63, 2250, 543, 56, tone: (28, 238, 0)),
            line("Akkunutzung für Apps festlegen", 63, 2309, 530, 49, tone: (80, 238, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: phone).map(\.text), [
            "Display & Touchbedienung", "Ton & Vibration", "Lautstärke und Haptik", "Dunkles Design",
            "Wird aktiviert, wenn der Modus „Bedtime\" beginnt", "Akkunutzung von Apps", "Akkunutzung für Apps festlegen",
        ])
    }

    /// The main list at font scale 1.3: Android enlarges the summary more than the title, so
    /// their sizes differ by only 1.26 to 1.33 and every title joined its summary. Dark theme:
    /// white over light grey, closer in brightness than black and grey. A paragraph of white
    /// letters on a dark page stays one.
    func testTitlesAndSummariesAtALargerFontScaleAndInTheDarkTheme() {
        let lines = [
            line("Google", 212, 376, 196, 61, tone: (28, 250, 0)),
            line("Services & preferences", 209, 457, 498, 49, tone: (80, 250, 0)),
            line("Apps", 209, 1162, 146, 59, tone: (28, 250, 0)),
            line("Assistant, kürzlich geöffnete Apps,", 209, 1238, 759, 53, tone: (80, 250, 0)),
            line("Standard-Apps", 209, 1298, 327, 45, tone: (80, 250, 0)),
            line("Benachrichtigungen", 213, 1448, 547, 63, tone: (28, 250, 0)),
            line("Benachrichtigungsverlauf,", 213, 1528, 571, 52, tone: (80, 250, 0)),
            line("Unterhaltungen", 209, 1584, 338, 52, tone: (80, 250, 0)),
            line("Android-Version", 63, 2177, 380, 49, tone: (229, 34, 0)),
            line("16", 59, 2247, 45, 35, tone: (204, 34, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: phone).map(\.text), [
            "Google", "Services & preferences", "Apps", "Assistant, kürzlich geöffnete Apps, Standard-Apps",
            "Benachrichtigungen", "Benachrichtigungsverlauf, Unterhaltungen", "Android-Version", "16",
        ])
        let dark = [
            line("Helle Schrift auf dunklem Grund ist schwerer", 45, 1538, 948, 46, tone: (234, 22, 0)),
            line("zu lesen, wenn der Kontrast nicht stimmt. Die", 49, 1608, 948, 52, tone: (234, 22, 0)),
            line("Übersetzung sollte hier ebenfalls hell auf", 52, 1674, 854, 60, tone: (234, 22, 0)),
            line("dunkel erscheinen und den Hintergrund nicht", 52, 1748, 937, 49, tone: (234, 22, 0)),
            line("aufhellen.", 52, 1817, 209, 46, tone: (234, 22, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(dark, imageSize: phone).count, 1)
    }

    /// The letters of the lines of one paragraph measure a little differently: up to 6 apart on
    /// real screens (here a wrapped summary of the main list at font scale 1.3 with that spread,
    /// and a paragraph of a web page, 28 to 32). Lines whose tone was not measured, or measured
    /// on different backgrounds, are joined by their boxes alone, as before.
    func testLinesAreComparedByBrightnessOnlyWhenBothWereMeasuredOnTheSameBackground() {
        let summary = [
            line("Dunkles Design, Schriftgröße,", 213, 2281, 641, 56, tone: (80, 250, 0)),
            line("Touchbedienung", 208, 2337, 364, 53, tone: (86, 250, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(summary, imageSize: phone).map(\.text),
                       ["Dunkles Design, Schriftgröße, Touchbedienung"])
        let paragraph = [
            line("La biblioteca abre de lunes a viernes de nueve", 52, 788, 962, 46, tone: (32, 254, 0)),
            line("de la mañana a ocho de la tarde. Los sábados", 52, 858, 962, 49, tone: (29, 254, 0)),
            line("cierra a las dos. Los domingos y festivos", 52, 924, 854, 53, tone: (29, 254, 0)),
            line("permanece cerrada.", 51, 992, 423, 59, tone: (28, 254, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(paragraph, imageSize: phone).count, 1)
        let unmeasured = [line("VPN", 188, 1566, 108, 45, tone: (28, 238, 0)), line("Kein VPN", 188, 1635, 157, 36)]
        XCTAssertEqual(TextLayout.blocks(unmeasured, imageSize: phone).map(\.text), ["VPN Kein VPN"])
        let otherBackground = [line("VPN", 188, 1566, 108, 45, tone: (28, 238, 0)),
                               line("Kein VPN", 188, 1635, 157, 36, tone: (80, 200, 0))]
        XCTAssertEqual(TextLayout.blocks(otherBackground, imageSize: phone).map(\.text), ["VPN Kein VPN"])
    }

    /// A post with black text and blue mentions, a link and a hashtag, text of 30 pixels on a
    /// light and on a dark page (boxes, tones and colours as measured). A line mostly in the
    /// colour of the links ("Danke @anna_mueller @peter", a whole address) measures as bright as
    /// the link (114 against 34), but most of its letters are coloured, so it stays in its
    /// paragraph; the line with "#urlaub" (a third of it coloured) as well.
    func testAPostWithLinksAndMentionsStaysOneParagraph() {
        let post = [
            line("Danke @anna_mueller @peter", 63, 719, 415, 28, tone: (114, 254, 0.77)),
            line("für die tollen Fotos #urlaub", 52, 760, 366, 32, tone: (34, 254, 0.30)),
            line("vom Wochenende!", 56, 806, 258, 28, tone: (34, 254, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(post, imageSize: phone).map(\.text),
                       ["Danke @anna_mueller @peter für die tollen Fotos #urlaub vom Wochenende!"])
        let address = [
            line("Mehr dazu findest du unter", 63, 555, 359, 24, tone: (34, 254, 0)),
            line("www.beispiel.de/info/2026", 52, 597, 355, 31, tone: (114, 254, 1)),
            line("oder in der App.", 56, 638, 223, 35, tone: (34, 254, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(address, imageSize: phone).map(\.text),
                       ["Mehr dazu findest du unter www.beispiel.de/info/2026 oder in der App."])
        let dark = [
            line("Danke @anna_mueller @peter", 63, 719, 415, 28, tone: (177, 22, 0.77)),
            line("für die tollen Fotos #urlaub", 56, 760, 359, 32, tone: (241, 22, 0.29)),
            line("vom Wochenende!", 56, 806, 258, 28, tone: (241, 22, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(dark, imageSize: phone).count, 1)
        // the same brightness without colour, as a grey line: kept apart
        let grey = post.map { line -> RecognizedLine in
            var line = line
            line.tone?.colour = 0
            return line
        }
        XCTAssertEqual(TextLayout.blocks(grey, imageSize: phone).map(\.text),
                       ["Danke @anna_mueller @peter", "für die tollen Fotos #urlaub vom Wochenende!"])
    }

    /// A post with a short mention in small text, drawn at text of 26 and 24 pixels and read at
    /// half size (540 × 1200, lines 12 to 14 pixels high; boxes, tones and colours as measured).
    /// "@bo" covers 3 of the 30 characters of the middle line: 0.16 of its letters are coloured,
    /// and its brightness moves by 18 in the dark theme (205 against 223) and by 19 in the light
    /// one (84 against 65). It is still a coloured line and stays in its paragraph.
    private var postWithAShortMention: [[RecognizedLine]] {
        let half = CGSize(width: 540, height: 1200)
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                  tone: (text: Double, background: Double, colour: Double)) -> RecognizedLine {
            RecognizedLine(text: text, rect: CGRect(x: x / half.width, y: y / half.height,
                                                    width: width / half.width, height: height / half.height),
                           tone: RecognizedLine.Tone(text: tone.text, background: tone.background, colour: tone.colour))
        }
        return [
            [
                line("Wir haben uns gestern lange", 30, 50, 168, 14, tone: (223, 22, 0)),
                line("unterhalten mit @bo über alles", 28, 68, 182, 12, tone: (205, 22, 0.16)),
                line("und freuen uns aufs nächste Mal.", 30, 86, 194, 14, tone: (223, 22, 0)),
            ],
            [
                line("Wir haben uns gestern lange", 30, 50, 156, 14, tone: (65, 254, 0)),
                line("unterhalten mit @bo über alles", 30, 68, 166, 12, tone: (84, 254, 0.16)),
                line("und freuen uns aufs nächste Mal.", 28, 86, 182, 10, tone: (73, 254, 0)),
            ],
        ]
    }

    func testAShortMentionInSmallTextKeepsItsPostTogether() {
        for post in postWithAShortMention {
            XCTAssertEqual(TextLayout.blocks(post, imageSize: CGSize(width: 540, height: 1200)).map(\.text),
                           ["Wir haben uns gestern lange unterhalten mit @bo über alles und freuen uns aufs nächste Mal."])
        }
    }

    /// The share at which a line counts as coloured lies between the most that black, white or
    /// grey letters measured in a real frame (0.083, the title "Accessibility Menu" in the light
    /// theme) and the least that a line with a short mention measured (0.16, above). A title
    /// with that much noise over a grey summary is still kept apart from it ("VPN" over "Kein
    /// VPN", whose boxes alone would join them), and the post above stays one paragraph.
    func testALineCountsAsColouredAboveTheNoiseOfGreyLettersAndBelowAShortMention() {
        let row = [line("VPN", 188, 1566, 108, 45, tone: (28, 238, 0.083)),
                   line("Kein VPN", 188, 1635, 157, 36, tone: (80, 238, 0))]
        XCTAssertEqual(TextLayout.blocks(row, imageSize: phone).map(\.text), ["VPN", "Kein VPN"])
        for post in postWithAShortMention {
            XCTAssertEqual(TextLayout.blocks(post, imageSize: CGSize(width: 540, height: 1200)).count, 1)
        }
    }

    /// Known limit: a summary in colour under a black title (a green "Verbunden", a blue "Tippt
    /// …", a red error) is told apart from the title no more than a link from its paragraph, so
    /// the two are joined when their boxes alone join them, as they were before brightness was
    /// compared (boxes, tones and colours as measured on drawn rows of 30 pixels; and a blue
    /// caption over a list on a test page, as measured in a frame of the stream). This test
    /// records the joining so that a change to it is noticed.
    func testASummaryInColourUnderABlackTitleIsJoinedWithIt() {
        let rows = [
            line("WLAN", 59, 98, 87, 28, tone: (34, 254, 0)),
            line("Verbunden", 59, 140, 146, 24, tone: (110, 254, 1)),
            line("Anna Schmidt", 63, 220, 202, 28, tone: (34, 254, 0)),
            line("Tippt ...", 59, 265, 108, 28, tone: (114, 254, 1)),
            line("Synchronisierung", 59, 345, 233, 31, tone: (34, 254, 0)),
            line("Fehler beim Laden", 59, 387, 251, 25, tone: (107, 254, 1)),
        ]
        XCTAssertEqual(TextLayout.blocks(rows, imageSize: phone).map(\.text),
                       ["WLAN Verbunden", "Anna Schmidt Tippt ...", "Synchronisierung Fehler beim Laden"])
        let caption = [
            line("14 px, Abstand Leerzeichen", 38, 296, 543, 48, tone: (105, 254, 0.98)),
            line("5 Kaffee", 41, 372, 177, 42, tone: (33, 254, 0)),
            line("2x Milch", 41, 448, 181, 43, tone: (33, 254, 0)),
        ]
        XCTAssertEqual(TextLayout.blocks(caption, imageSize: phone).map(\.text),
                       ["14 px, Abstand Leerzeichen 5 Kaffee", "2x Milch"])
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

    /// Scrolled: the last line on the screen is cut in half by the navigation bar, and Vision read
    /// its upper half as garbage in a low box. It is no line of the paragraph above it, and the
    /// paragraph is not complete.
    func testALineCutOffIsAloneAndTheParagraphGoesOnThere() {
        let lines = [
            line("Une recette simple", 52, 2138, 512, 63),
            line("Faites fondre le beurre dans une poêle, ajoutez", 52, 2250, 975, 52),
            line("lan dianana aalinán an finan lamallan at", 45, 2316, 829, 28),
        ]
        let blocks = TextLayout.blocks(lines, imageSize: phone)
        XCTAssertEqual(blocks.map(\.text), ["Une recette simple", "Faites fondre le beurre dans une poêle, ajoutez",
                                            "lan dianana aalinán an finan lamallan at"])
        XCTAssertEqual(blocks.map(\.cutOffEdges), [0, FrameMotion.bottom, FrameMotion.top | FrameMotion.bottom])
        XCTAssertTrue(TextLayout.looksCutOff("lan dianana aalinán an finan lamallan at", width: 829, height: 28))
        XCTAssertFalse(TextLayout.looksCutOff("Faites fondre le beurre dans une poêle, ajoutez", width: 975, height: 52))
        // x-height letters only make a low box anyway
        XCTAssertFalse(TextLayout.looksCutOff("une rose acamuse", width: 340, height: 26))
    }

    /// Right at the bottom, under the navigation bar, Vision read the upper part of the first line
    /// of a paragraph as garbage; there is no line of its paragraph next to it to compare with,
    /// but near the edge of the screen a box that low is enough
    func testALineCutOffAtTheBottomOfTheScreenNeedsNoNeighbour() {
        let lines = [
            line("Horario de la biblioteca", 52, 2201, 631, 56),
            line("Is hihlintans shrn da lnn o vinrnno da niinun", 42, 2313, 972, 31),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: phone).map(\.cutOffEdges),
                       [0, FrameMotion.top | FrameMotion.bottom])
        // the same line in the middle of the screen is taken as it is
        let moved = lines.map { line -> RecognizedLine in
            var line = line
            line.rect.origin.y -= 0.4
            return line
        }
        XCTAssertEqual(TextLayout.blocks(moved, imageSize: phone).map(\.cutOffEdges), [0, 0])
    }

    /// The tracker is given what `blocks` makes of these lines: it asks to translate the heading,
    /// but neither the garbage nor the paragraph that goes on below the navigation bar yet (the
    /// paragraph is taken once the picture rests and its place was read again, see
    /// `OverlayTrackerCutOffTests`)
    func testNeitherACutOffLineNorItsParagraphIsTranslatedYet() throws {
        let lines = [
            line("Une recette simple", 52, 2138, 512, 63),
            line("Faites fondre le beurre dans une poêle, ajoutez", 52, 2250, 975, 52),
            line("lan dianana aalinán an finan lamallan at", 45, 2316, 829, 28),
        ]
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
        _ = tracker.advance(page, scale: scale, time: 0)
        let request = try XCTUnwrap(tracker.beginRecognition(time: 1))
        let blocks = TextLayout.blocks(lines, imageSize: phone).filter { TextLayout.isTranslatable($0.text) }.map { block in
            RecognizedBlock(text: block.text, rect: CGRect(x: block.rect.minX * phone.width, y: block.rect.minY * phone.height,
                                                           width: block.rect.width * phone.width,
                                                           height: block.rect.height * phone.height),
                            lineCount: block.lineCount, cutOffEdges: block.cutOffEdges)
        }
        tracker.finishRecognition(request, blocks: blocks, time: 1.1)
        XCTAssertEqual(tracker.textsAwaitingTranslation(limit: 10, time: 1.2), ["Une recette simple"])
    }

    /// Scrolled to the end of the page: the navigation bar hides the lower part of the last line.
    /// Vision read the rest of it, nearly right, in a box two thirds as high as the line above.
    /// The paragraph ends above it; the part is no line of it and may be cut off (held back until
    /// the picture rests). From its box alone it cannot be told that it is garbage: it is pasted.
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
        XCTAssertEqual(blocks.map(\.cutOffEdges), [0, FrameMotion.top | FrameMotion.bottom])
        XCTAssertEqual(blocks.map(\.isGarbled), [false, false])
        XCTAssertEqual(TextLayout.plainText(lines, imageSize: phone), blocks.map(\.text).joined(separator: "\n"))
    }

    /// Pasted text: one paragraph per line, without the status bar and without a line cut off at
    /// the bottom edge of the screen
    func testPlainTextHasAParagraphPerLine() {
        let lines = [
            line("12:47 L", 42, 17, 139, 35),
            line("< Testlabor", 41, 103, 377, 66),
        ] + page + [
            line("Am Montag bleibt es überwiegend bewölkt,", 49, 2350, 916, 50),
        ]
        XCTAssertEqual(TextLayout.plainText(lines, imageSize: phone), [
            "< Testlabor",
            "Willkommen im Testlabor",
            "Diese Seite ist ein Prüfstand für die Texterkennung. Sie enthält Überschriften, längere Absätze, "
                + "kurze Beschriftungen und farbige Schaltflächen, damit man sehen kann, ob die Übersetzung an der "
                + "richtigen Stelle erscheint.",
            "Benutzername", "Passwort vergessen?", "Jetzt anmelden", "Abbrechen",
        ].joined(separator: "\n"))
    }

    // MARK: Icons of rows

    /// Android's settings, light theme: the icons of "Verbundene Geräte", "Apps" and "Ton &
    /// Vibration" read as "Cou", "::" and "+)", each centred between the title and the line
    /// below it. They are not translated; the rows are (Text copies them:
    /// `testIconsOfRowsOfTwoLinesAreCopied`).
    func testIconsOfRowsOfTwoLinesAreNotTranslated() {
        let lines = [
            line("Verbundene Geräte", 202, 823, 453, 49),
            RecognizedLine(text: "Cou", rect: CGRect(x: 105 / phone.width, y: 848 / phone.height,
                                                     width: 63 / phone.width, height: 49 / phone.height), confidence: 0.3),
            line("Bluetooth, Kopplung", 206, 893, 331, 42),
            line("Apps", 206, 1074, 125, 52),
            line("::", 105, 1116, 56, 49),
            line("Assistant, kürzlich geöffnete Apps,", 206, 1141, 575, 42),
            line("Ton & Vibration", 209, 1528, 362, 49),
            line("+)", 108, 1552, 59, 45),
            line("Lautstärke und Haptik", 202, 1598, 369, 38),
        ]
        let rows = ["Verbundene Geräte", "Bluetooth, Kopplung", "Apps", "Assistant, kürzlich geöffnete Apps,",
                    "Ton & Vibration", "Lautstärke und Haptik"]
        XCTAssertEqual(TextLayout.content(lines, imageSize: phone, for: .translating).map(\.text), rows)
        let blocks = TextLayout.blocks(TextLayout.content(lines, imageSize: phone, for: .translating), imageSize: phone)
        XCTAssertFalse(blocks.contains { $0.text.contains("Cou") })
        // the key of the VPN row read as "OT" (a region of the picture read alone), at font scale 1
        let vpn = [line("OT", 68, 1600, 54, 32), line("VPN", 190, 1570, 106, 42), line("Kein VPN", 192, 1636, 154, 30)]
        XCTAssertEqual(TextLayout.content(vpn, imageSize: phone, for: .translating).map(\.text), ["VPN", "Kein VPN"])
        // font scale 1.3: the icon of "Netzwerk & Internet" read as "の"
        let network = [line("Netzwerk & Internet", 212, 638, 546, 77), line("の", 98, 673, 80, 77),
                       line("Mobile Daten, WLAN, Hotspot", 213, 729, 648, 52)]
        XCTAssertEqual(TextLayout.content(network, imageSize: phone, for: .translating).map(\.text),
                       ["Netzwerk & Internet", "Mobile Daten, WLAN, Hotspot"])
    }

    /// The same row written from the right: the icon stands right of the two lines
    func testTheIconOfARowWrittenFromTheRightIsNotTranslated() {
        let lines = [
            line("الأجهزة المتصلة", 425, 823, 453, 49),
            line("Cou", 912, 848, 63, 49),
            line("البلوتوث والإقران", 543, 893, 331, 42),
        ]
        XCTAssertEqual(TextLayout.content(lines, imageSize: phone, for: .translating).map(\.text),
                       ["الأجهزة المتصلة", "البلوتوث والإقران"])
    }

    /// Text keeps what Translate leaves out as icons of rows: a short word or initials centred
    /// before a row of two lines are real text, and nothing in the lines tells them from an icon.
    /// The lines are what Vision read on rendered pages of 1080 × 2400 (a weekday before two
    /// opening times, a value in a table cell beside two lines, a city name, avatars).
    func testShortWordsCentredBeforeRowsOfTwoLinesAreCopied() {
        let hours = [line("Mo", 56, 1266, 70, 49), line("09:00 - 12:00", 212, 1234, 293, 61),
                     line("14:00 - 18:00", 216, 1289, 227, 48)]
        let cell = [line("Ja", 49, 1057, 63, 52), line("Kostenlose Lieferung", 216, 1033, 415, 52),
                    line("ab 30 € Bestellwert", 213, 1081, 314, 49)]
        let city = [line("東京", 59, 1472, 87, 45), line("晴れのち曇り", 216, 1444, 262, 57),
                    line("最高気温 15度", 219, 1500, 219, 45)]
        let avatars = [line("AB", 84, 230, 63, 45), line("Anna Berger", 219, 206, 251, 53),
                       line("Bis morgen um acht!", 219, 265, 317, 38),
                       line("JK", 77, 645, 70, 42), line("Jonas Keller", 216, 618, 245, 50),
                       line("Danke, hat geklappt", 219, 677, 307, 45)]
        for (lines, word) in [(hours, "Mo"), (cell, "Ja"), (city, "東京"), (avatars, "AB"), (avatars, "JK")] {
            XCTAssertTrue(TextLayout.plainText(lines, imageSize: phone).components(separatedBy: "\n").contains(word), word)
            XCTAssertTrue(TextLayout.content(lines, imageSize: phone).map(\.text).contains(word), word)
            // the stated limit of Translate: such a word stays untranslated
            XCTAssertFalse(TextLayout.content(lines, imageSize: phone, for: .translating).map(\.text).contains(word), word)
        }
    }

    /// The accepted limit of Text: the icon of a row of two lines read as characters is copied as a
    /// stray line, so that no real short word in the same place is lost. Android's settings: the
    /// Google row (dark theme) with its icon read as "G", and "Ton & Vibration" with "+)".
    func testIconsOfRowsOfTwoLinesAreCopied() {
        let lines = [
            line("Google", 209, 369, 171, 61), line("G", 108, 391, 56, 59), line("Services & preferences", 206, 440, 383, 42),
            line("Ton & Vibration", 209, 1528, 362, 49), line("+)", 108, 1552, 59, 45),
            line("Lautstärke und Haptik", 202, 1598, 369, 38),
        ]
        let copied = TextLayout.plainText(lines, imageSize: phone).components(separatedBy: "\n")
        XCTAssertTrue(copied.contains("G"))
        XCTAssertTrue(copied.contains("+)"))
        XCTAssertEqual(TextLayout.content(lines, imageSize: phone).count, lines.count)
        XCTAssertEqual(TextLayout.content(lines, imageSize: phone, for: .translating).map(\.text),
                       ["Google", "Services & preferences", "Ton & Vibration", "Lautstärke und Haptik"])
    }

    /// Short words set apart before their text, in a column, stay: their middle is that of their
    /// line, moved by descenders or capitals at most a quarter of the line ("go" 0.23, "x:y"
    /// 0.25 of the lower box; Vision's boxes on Android)
    func testShortWordsInAColumnAreContent() {
        let lines = [
            line("Zahnarzt um zehn Uhr", 174, 1577, 484, 49), line("Mo", 45, 1577, 80, 49),
            line("Abendessen mit Anna", 188, 1685, 463, 49), line("Fr", 52, 1688, 49, 45),
            line("Kaffee für das Büro", 188, 1797, 411, 49), line("5", 49, 1800, 31, 42),
            line("Milch und Eier", 188, 1908, 303, 45), line("2x", 49, 1908, 59, 49),
            line("Gegensatz zu gestern", 188, 2131, 456, 53), line("Im", 49, 2131, 63, 42),
        ]
        XCTAssertEqual(TextLayout.content(lines, imageSize: phone, for: .translating).count, lines.count)
        let tight = [
            line("Anna", 167, 1797, 125, 45), line("by", 35, 1797, 70, 59),
            line("Weiter", 174, 1876, 157, 54), line("go", 35, 1887, 73, 56),
            line("Name", 188, 1964, 143, 50), line("my", 38, 1974, 80, 45),
        ]
        XCTAssertEqual(TextLayout.content(tight, imageSize: phone, for: .translating).count, tight.count)
        let low = [line("Verhältnis", 139, 358, 255, 55), line("x:y", 38, 373, 73, 49),
                   line("$5k", 42, 447, 94, 52), line("Budget", 164, 450, 188, 52)]
        XCTAssertEqual(TextLayout.content(low, imageSize: phone, for: .translating).count, low.count)
    }

    /// A value right of a row of two lines (written from the left) and a short word before the
    /// first line of an item of two lines stay
    func testValuesAndWordsBesideRowsOfTwoLinesAreContent() {
        let value = [
            line("Speicher", 206, 1319, 244, 50), line("45 % belegt", 206, 1385, 300, 42),
            line("2 GB", 900, 1352, 110, 45),
        ]
        XCTAssertEqual(TextLayout.content(value, imageSize: phone, for: .translating).count, 3)
        let item = [
            line("Mo", 45, 1577, 80, 49), line("Zahnarzt um zehn Uhr, danach zur", 174, 1577, 700, 49),
            line("Apotheke am Markt", 174, 1640, 400, 49),
        ]
        XCTAssertEqual(TextLayout.content(item, imageSize: phone, for: .translating).count, 3)
    }

    /// Numbers centred before a row of two lines (a chart, a value, a shopping list) are content
    func testNumbersBeforeRowsOfTwoLinesAreContent() {
        let lines = [
            line("1", 56, 230, 28, 45), line("Blinding Lights", 216, 197, 297, 67), line("The Weeknd", 216, 254, 203, 48),
            line("2", 56, 433, 38, 52), line("Flowers", 209, 407, 168, 55), line("Miley Cyrus", 216, 466, 189, 45),
            line("12°", 52, 1206, 181, 98), line("Bewölkt", 366, 1202, 167, 56), line("H15° T8°", 365, 1256, 179, 46),
            line("83 %", 59, 1422, 202, 77), line("Akku", 362, 1411, 112, 53), line("Noch etwa 1 Tag", 366, 1463, 258, 51),
            line("2x", 52, 1645, 63, 49), line("Milch", 216, 1617, 115, 49), line("1,5 % Fett, 1 Liter", 216, 1673, 268, 46),
            line("1 EL", 48, 1847, 95, 54), line("Olivenöl", 205, 1822, 182, 58), line("extra vergine", 216, 1877, 206, 49),
        ]
        XCTAssertEqual(TextLayout.content(lines, imageSize: phone, for: .translating).count, lines.count)
    }

    /// Only short readings, before two lines of one row, count as icons
    func testLabelsAndWordsBeforeOtherLinesAreContent() {
        let label = [line("Adresse", 40, 850, 170, 45), line("Hauptstraße 10", 300, 823, 330, 49), line("8001 Zürich", 300, 880, 250, 49)]
        XCTAssertEqual(TextLayout.content(label, imageSize: phone, for: .translating).count, 3)
        let apart = [line("Ja", 40, 900, 50, 45), line("Kostenlose Lieferung", 200, 823, 400, 49), line("ab 30 € Bestellwert", 200, 960, 330, 42)]
        XCTAssertEqual(TextLayout.content(apart, imageSize: phone, for: .translating).count, 3)
        let ragged = [line("Ja", 40, 852, 50, 45), line("Kostenlose Lieferung", 130, 823, 400, 49), line("ab 30 € Bestellwert", 200, 893, 330, 42)]
        XCTAssertEqual(TextLayout.content(ragged, imageSize: phone, for: .translating).count, 3)
    }

    func testOnlyTextWithLettersIsTranslated() {
        XCTAssertFalse(TextLayout.isTranslatable("9:41"))
        XCTAssertFalse(TextLayout.isTranslatable("€ 12.50"))
        XCTAssertTrue(TextLayout.isTranslatable("OK"))
    }
}
