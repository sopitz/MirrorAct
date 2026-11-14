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

    // MARK: Lists

    private static let iPhoneIsland = CGSize(width: 1290, height: 2796)

    /// Bullets in a German article on an iPhone (SF, 17 points): the lines after the first one of
    /// an item begin where its text does, behind the bullet, half a line further right than the
    /// bullet. An item of one line is followed by the next item.
    func testAWrappedListItemGoesOnWhereItsTextBegins() {
        let lines = [
            line("• Das Wetter bleibt die ganze Woche über trocken, bei", 44, 654, 1116, 66, on: Self.iPhoneIsland),
            line("schwachem Wind aus Westen. Für Gruppen", 77, 723, 901, 49, on: Self.iPhoneIsland),
            line("• Änderungen am Tarif sind jederzeit über die Kontoseite", 44, 1222, 1161, 65, on: Self.iPhoneIsland),
            line("möglich.", 77, 1300, 178, 49, on: Self.iPhoneIsland),
            line("• Die Lieferung dauert innerhalb Deutschlands", 45, 1370, 949, 49, on: Self.iPhoneIsland),
            line("• Über Nacht kühlt es deutlich ab, Ältere sollten warme", 40, 1420, 1129, 85, on: Self.iPhoneIsland),
            line("Kleidung mitnehmen. Das", 77, 1504, 527, 49, on: Self.iPhoneIsland),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: Self.iPhoneIsland).map(\.text), [
            "• Das Wetter bleibt die ganze Woche über trocken, bei schwachem Wind aus Westen. Für Gruppen",
            "• Änderungen am Tarif sind jederzeit über die Kontoseite möglich.",
            "• Die Lieferung dauert innerhalb Deutschlands",
            "• Über Nacht kühlt es deutlich ab, Ältere sollten warme Kleidung mitnehmen. Das",
        ])
    }

    /// A numbered list in English on an iPhone (SF): the text of an item goes on behind its
    /// number, a whole line further right; every number starts an item of its own
    func testEveryNumberStartsAnItemThatGoesOnBehindIt() {
        let lines = [
            line("1. Bring a warm jacket if you plan to stay", 44, 1733, 916, 56),
            line("outside after sunset.", 96, 1807, 471, 44),
            line("2. You can change your plan at any time from", 48, 1881, 1023, 55),
            line("the account page.", 98, 1951, 421, 55),
            line("3. Turn left at the second traffic light and", 48, 2028, 927, 52),
            line("follow the", 99, 2100, 225, 47),
            line("• The library offers quiet rooms", 48, 2223, 710, 52),
        ]
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: Self.iPhone).map(\.text), [
            "1. Bring a warm jacket if you plan to stay outside after sunset.",
            "2. You can change your plan at any time from the account page.",
            "3. Turn left at the second traffic light and follow the",
            "• The library offers quiet rooms",
        ])
    }

    /// Running text that wraps in front of a number with a full stop (a date, an ordinal, a number
    /// that ends a sentence): the line above runs to the right edge of the paragraph and had no
    /// room for the number, so the number starts no item (Helvetica Neue, 17 points, in columns
    /// 240 and 260 points wide)
    func testANumberThatAWrappedSentenceGoesOnWithStartsNoItem() {
        let date = [
            line("Die Ausstellung im", 48, 130, 422, 53),
            line("Stadtmuseum wird nach langer", 48, 192, 714, 58),
            line("Pause wieder eröffnet. Die", 48, 249, 599, 53),
            line("Leitung lädt alle Bürger ab dem", 48, 312, 714, 58),
            line("3. Oktober 2026 zu einem", 43, 374, 590, 58),
            line("Rundgang durch die neuen", 48, 436, 619, 53),
            line("Räume ein.", 48, 498, 264, 49),
        ]
        XCTAssertEqual(TextLayout.blocks(date, imageSize: Self.iPhone).map(\.text), [
            "Die Ausstellung im Stadtmuseum wird nach langer Pause wieder eröffnet. Die Leitung lädt alle "
                + "Bürger ab dem 3. Oktober 2026 zu einem Rundgang durch die neuen Räume ein.",
        ])
        let ordinal = [
            line("Das Gebäude wurde nach dem", 48, 619, 710, 58),
            line("2. Weltkrieg neu aufgebaut und", 43, 676, 719, 72),
            line("beherbergt heute Büros, eine", 48, 734, 671, 72),
            line("Bibliothek und im 5. Stock links", 48, 791, 724, 68),
            line("eine kleine Arztpraxis für Kinder.", 43, 859, 739, 67),
        ]
        XCTAssertEqual(TextLayout.blocks(ordinal, imageSize: Self.iPhone).count, 1)
        let english = [
            line("The museum reopens next week.", 43, 130, 763, 58),
            line("Tickets for adults cost 12 euros,", 48, 192, 734, 58),
            line("and entry is free for children under", 48, 245, 786, 62),
            line("3. Then there is the café on the", 43, 312, 715, 53),
            line("roof, open daily from ten.", 43, 374, 580, 58),
        ]
        XCTAssertEqual(TextLayout.blocks(english, imageSize: Self.iPhone).map(\.text), [
            "The museum reopens next week. Tickets for adults cost 12 euros, and entry is free for children "
                + "under 3. Then there is the café on the roof, open daily from ten.",
        ])
    }

    /// A numbered list below a line that ends in a colon, or below a line that ends well short of
    /// the paragraph and had room for the number: the number starts the first item
    func testANumberBelowALineThatEndsStartsAnItem() {
        let items = [
            line("1. Bring a warm jacket if you plan to stay", 44, 1733, 916, 56),
            line("outside after sunset.", 96, 1807, 471, 44),
            line("2. You can change your plan at any time from", 48, 1881, 1023, 55),
            line("the account page.", 98, 1951, 421, 55),
        ]
        let expected = ["1. Bring a warm jacket if you plan to stay outside after sunset.",
                        "2. You can change your plan at any time from the account page."]
        let colon = [
            line("Delivery usually takes two to three business", 44, 1585, 1010, 56),
            line("days. Before you come, please note:", 44, 1659, 1010, 56),
        ]
        XCTAssertEqual(TextLayout.blocks(colon + items, imageSize: Self.iPhone).map(\.text),
                       ["Delivery usually takes two to three business days. Before you come, please note:"] + expected)
        let short = [line("Good to know", 44, 1659, 290, 56)]
        XCTAssertEqual(TextLayout.blocks(short + items, imageSize: Self.iPhone).map(\.text), ["Good to know"] + expected)
    }

    /// Chinese and Japanese lists: Vision reads a bullet without the space behind it, and
    /// numbers end in a full-width full stop (PingFang SC on an iPhone, SF on an iPad)
    func testItemsOfChineseAndJapaneseListsAreSeparate() {
        let chinese = [
            line("• 更新期间请保持设备电量在百分", 37, 1373, 890, 63),
            line("•博物馆上午九点开放，下午六点关闭，", 37, 1472, 1038, 81),
            line("节假日除外。", 88, 1566, 336, 81),
            line("•你可以随时在账户页面更改套餐。如果", 37, 1671, 1071, 74),
            line("打算日落后待在户外", 85, 1763, 545, 66),
        ]
        XCTAssertEqual(TextLayout.blocks(chinese, imageSize: Self.iPhone).map(\.text), [
            "• 更新期间请保持设备电量在百分", "•博物馆上午九点开放，下午六点关闭，节假日除外。", "•你可以随时在账户页面更改套餐。如果打算日落后待在户外",
        ])
        let japanese = [
            line("1．チケットは入口で購入するか、事前にオ", 137, 549, 552, 41, on: Self.iPad),
            line("2．日没後も外にいる予定なら、暖かい上着を持ってい", 137, 597, 707, 38, on: Self.iPad),
            line("3．今週はほとんど晴れの日が続き、西からの風は弱いでしょう。チ", 137, 645, 875, 38, on: Self.iPad),
        ]
        XCTAssertEqual(TextLayout.blocks(japanese, imageSize: Self.iPad).map(\.text), japanese.map(\.text))
    }

    /// In Arabic the marker is on the right, and so is where the text of an item goes on (Geeza
    /// Pro on an iPhone, SF Arabic on an iPad)
    func testARightToLeftListItemGoesOnWhereItsTextBegins() {
        let numbered = [
            line("1. خذ معك سترة دافئة إذا كنت تنوي البقاء في الخارج", 89, 1813, 1148, 73, on: Self.iPhoneIsland),
            line("بعد الغروب.", 921, 1914, 247, 61, on: Self.iPhoneIsland),
            line("2. يمكن شراء التذاكر عند المدخل أو مسبقا عبر الإنترنت.", 49, 2012, 1193, 69, on: Self.iPhoneIsland),
            line("يفتح المتحف أبوابه في التاسعة صباحا", 373, 2109, 795, 73, on: Self.iPhoneIsland),
            line("3. سيبقى الطقس جافا معظم أيام الأسبوع مع رياح", 150, 2203, 1091, 81, on: Self.iPhoneIsland),
            line("غربية خفيفة. يفتح", 795, 2302, 382, 77, on: Self.iPhoneIsland),
        ]
        XCTAssertEqual(TextLayout.blocks(numbered, imageSize: Self.iPhoneIsland).map(\.text), [
            "1. خذ معك سترة دافئة إذا كنت تنوي البقاء في الخارج بعد الغروب.",
            "2. يمكن شراء التذاكر عند المدخل أو مسبقا عبر الإنترنت. يفتح المتحف أبوابه في التاسعة صباحا",
            "3. سيبقى الطقس جافا معظم أيام الأسبوع مع رياح غربية خفيفة. يفتح",
        ])
        let bullets = [
            line("• يمكنك تغيير خطتك في أي وقت من صفحة الحساب. يستغرق التوصيل داخل البلاد عادة من يومين إلى",
                 161, 1221, 1342, 45, on: Self.iPad),
            line("ثلاثة أيام عمل.", 1283, 1266, 192, 45, on: Self.iPad),
            line("• انعطف يسارا عند الإشارة الثانية واتبع اللافتات إلى المحطة. يمكن شراء التذاكر عند المدخل أو مسبقا عبر",
                 137, 1317, 1366, 48, on: Self.iPad),
            line("الإنترنت. انعطف يسارا عند الإشارة الثانية واتبع اللافتات إلى", 724, 1365, 755, 38, on: Self.iPad),
            line("• يمكنك تغيير خطتك في أي وقت من صفحة الحساب. سيبقى الطقس جافا معظم", 436, 1413, 1067, 45, on: Self.iPad),
        ]
        XCTAssertEqual(TextLayout.blocks(bullets, imageSize: Self.iPad).map(\.text), [
            "• يمكنك تغيير خطتك في أي وقت من صفحة الحساب. يستغرق التوصيل داخل البلاد عادة من يومين إلى ثلاثة أيام عمل.",
            "• انعطف يسارا عند الإشارة الثانية واتبع اللافتات إلى المحطة. يمكن شراء التذاكر عند المدخل أو مسبقا عبر "
                + "الإنترنت. انعطف يسارا عند الإشارة الثانية واتبع اللافتات إلى",
            "• يمكنك تغيير خطتك في أي وقت من صفحة الحساب. سيبقى الطقس جافا معظم",
        ])
    }

    // MARK: Titles and summaries

    /// The title of a row in iOS settings (17 points) and the summary below it (15 points) are as
    /// close as the lines of a paragraph, their sizes measure within `sameSize` of each other and
    /// their boxes are about as high: by their boxes alone they are joined. The colour of their
    /// letters tells them apart (black and grey: `RecognizedLine.tone`, as the recognizer
    /// measured it in the picture).
    func testTitleAndSummaryOfAnIOSSettingsRowAreToldApartByTheirColour() {
        let boxes = [
            line("Photos", 207, 691, 178, 41, on: Self.iPhoneIsland),
            line("Passwords", 223, 817, 247, 41, on: Self.iPhoneIsland),
            line("Updated just now", 223, 882, 361, 45, on: Self.iPhoneIsland),
            line("Privacy & Security", 93, 977, 553, 95, on: Self.iPhoneIsland),
            line("Mobile Data", 211, 2166, 284, 45, on: Self.iPhoneIsland),
            line("Banners, Sounds, Badges", 223, 2235, 527, 49, on: Self.iPhoneIsland),
            line("Notifications", 223, 2353, 288, 45, on: Self.iPhoneIsland),
        ]
        XCTAssertEqual(TextLayout.blocks(boxes, imageSize: Self.iPhoneIsland).map(\.text), [
            "Photos", "Passwords Updated just now", "Privacy & Security", "Mobile Data Banners, Sounds, Badges",
            "Notifications",
        ])
        let tones: [Double] = [0, 0, 149, 1, 0, 149, 0]
        let lines = zip(boxes, tones).map { line, text in
            var line = line
            line.tone = RecognizedLine.Tone(text: text, background: 254)
            return line
        }
        XCTAssertEqual(TextLayout.blocks(lines, imageSize: Self.iPhoneIsland).map(\.text), [
            "Photos", "Passwords", "Updated just now", "Privacy & Security", "Mobile Data", "Banners, Sounds, Badges",
            "Notifications",
        ])
    }

    func testListMarkers() throws {
        XCTAssertEqual(try XCTUnwrap(TextLayout.listMarkerUnits("• Brot")), 0.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TextLayout.listMarkerUnits("•博物馆")), 0.52, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TextLayout.listMarkerUnits("12. Juli")), 1.68, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TextLayout.listMarkerUnits("3) Ende")), 1.13, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TextLayout.listMarkerUnits("1．チケット")), 1.55, accuracy: 1e-9)
        XCTAssertNotNil(TextLayout.listMarkerUnits("- المتحف"))
        XCTAssertNotNil(TextLayout.listMarkerUnits("4."))
        for text in ["1.5 kg", "10:30", "2024. Das", "•", "•Brot", "-5 °C", "Seite 1. Weiter", "1,5", ""] {
            XCTAssertNil(TextLayout.listMarkerUnits(text), text)
            XCTAssertNil(TextLayout.numberLeadUnits(text), text)
        }
        // the number, its end, the space and at most `numberLeadWord` of the word behind it
        XCTAssertEqual(try XCTUnwrap(TextLayout.numberLeadUnits("3. Oktober 2026")), 1.13 + 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TextLayout.numberLeadUnits("2) A list")), 1.13 + 0.66, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TextLayout.numberLeadUnits("1．チケット")), 1.55 + 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(TextLayout.numberLeadUnits("4.")), 0.85, accuracy: 1e-9)
        XCTAssertNil(TextLayout.numberLeadUnits("• Brot"))
    }
}
