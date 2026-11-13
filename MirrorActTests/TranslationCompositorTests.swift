// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import XCTest
@testable import MirrorAct

/// Translations drawn into frames (`TranslationCompositor`, `BlockTextMask`): the copy shows
/// them at the right place, the right way up and in the colors of their block; everything
/// else, and the frame of the device itself, stays as it was.
final class TranslationCompositorTests: XCTestCase {
    private let dark = RGBColor(red: 20, green: 20, blue: 20)
    private let light = RGBColor(red: 250, green: 250, blue: 250)
    private var darkOnLight: BlockColors { BlockColors(background: light, foreground: dark) }

    /// A block of one line. In whole pixels its text lies at 201, 121 and is 500 × 60 large;
    /// the margin around it is 7 pixels (12 % of the line height).
    private let rect = CGRect(x: 201.3, y: 120.6, width: 500.2, height: 59.8)
    private let text = PixelRect(minX: 201, minY: 121, maxX: 701, maxY: 181)
    private let margin = 7

    private func block(_ text: String = "Hello world", visible: CGRect? = nil, colors: BlockColors? = nil) -> PlacedBlock {
        PlacedBlock(id: 1, text: text, rect: rect, visibleRect: visible, lineCount: 1, colors: colors ?? darkOnLight)
    }

    // MARK: 4:2:0 video

    func testVideoFrameGetsTheBoxAndKeepsEverythingElse() throws {
        // 1170 pixels do not fill whole rows of memory: the rows are padded
        let source = try videoFrame(width: 1170, height: 400)
        XCTAssertGreaterThan(CVPixelBufferGetBytesPerRowOfPlane(source, 0), 1170)
        let before = picture(of: source)
        let copy = try XCTUnwrap(TranslationCompositor().compose(source, blocks: [block()]))
        XCTAssertTrue(picture(of: source) == before, "the frame of the device must stay as it is")
        checkVideo(picture(of: copy), source: before, text: text, margin: margin, visible: nil, colors: darkOnLight)
    }

    func testVideoFrameWithRowsPaddedLikeThePoolsIsCopiedToo() throws {
        // backed by an IOSurface like the buffers of the compositor's pool
        let source = try videoFrame(width: 1170, height: 400, ioSurface: true)
        let before = picture(of: source)
        let copy = try XCTUnwrap(TranslationCompositor().compose(source, blocks: [block()]))
        XCTAssertTrue(picture(of: source) == before)
        checkVideo(picture(of: copy), source: before, text: text, margin: margin, visible: nil, colors: darkOnLight)
    }

    func testNothingIsDrawnOutsideTheVisiblePartOfABlock() throws {
        let source = try videoFrame(width: 1170, height: 400)
        let before = picture(of: source)
        // as if a bar hid the block above row 140 and below row 170
        let visible = PixelRect(minX: 201, minY: 140, maxX: 701, maxY: 170)
        let copy = try XCTUnwrap(TranslationCompositor().compose(source, blocks: [block(visible: visible.cgRect)]))
        XCTAssertTrue(picture(of: source) == before)
        checkVideo(picture(of: copy), source: before, text: text, margin: margin, visible: visible, colors: darkOnLight)

        // an odd edge: the row of color values at the edge is shared with what lies outside
        let odd = PixelRect(minX: 150, minY: 141, maxX: 655, maxY: 400)
        let oddCopy = try XCTUnwrap(TranslationCompositor().compose(source, blocks: [block(visible: odd.cgRect)]))
        checkVideo(picture(of: oddCopy), source: before, text: text, margin: margin, visible: odd, colors: darkOnLight)
    }

    func testFullRangeVideoGetsFullRangeValues() throws {
        let source = try videoFrame(width: 640, height: 360, fullRange: true)
        let before = picture(of: source)
        let copy = try XCTUnwrap(TranslationCompositor().compose(source, blocks: [block()]))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(copy), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let result = picture(of: copy)
        // brightness 250 of 255 as it is, not squeezed into 16…235
        XCTAssertEqual(result.luma(text.minX - 3, 150), 250)
        checkVideo(result, source: before, text: text, margin: margin, visible: nil, colors: darkOnLight, fullRange: true)
    }

    /// The color plane has one value for every 2 × 2 pixels, starting at even pixels of the
    /// frame: text at an odd position must get its color in the cells it really covers.
    func testColoredTextColorsTheCellsUnderItsBrightness() throws {
        let colors = BlockColors(background: RGBColor(red: 0, green: 60, blue: 200), foreground: RGBColor(red: 255, green: 235, blue: 0))
        let background = YCbCrColor(colors.background, fullRange: false), foreground = YCbCrColor(colors.foreground, fullRange: false)
        let source = try videoFrame(width: 640, height: 240)
        let before = picture(of: source)
        for (x, y) in [(200, 100), (201, 100), (200, 101), (201, 101)] {
            let placed = PlacedBlock(id: 1, text: "HELLO", rect: CGRect(x: x, y: y, width: 300, height: 60), visibleRect: nil,
                                     lineCount: 1, colors: colors)
            let result = picture(of: try XCTUnwrap(TranslationCompositor().compose(source, blocks: [placed])))
            let text = PixelRect(minX: x, minY: y, maxX: x + 300, maxY: y + 60)
            checkVideo(result, source: before, text: text, margin: 7, visible: nil, colors: colors, textHasItsOwnColor: true)
            var textCells = 0, wrongTextCells = 0, backgroundCells = 0, wrongBackgroundCells = 0
            for cellY in (text.minY + 1) / 2 ..< text.maxY / 2 {
                for cellX in (text.minX + 1) / 2 ..< text.maxX / 2 {
                    let brightness = [result.luma(2 * cellX, 2 * cellY), result.luma(2 * cellX + 1, 2 * cellY),
                                      result.luma(2 * cellX, 2 * cellY + 1), result.luma(2 * cellX + 1, 2 * cellY + 1)]
                    let cell = result.cell(cellX, cellY)
                    // (a value of the mask just below white can round to the same brightness, hence "about")
                    if brightness.allSatisfy({ $0 == foreground.y }) {
                        textCells += 1
                        if !isAbout(cell.cb, foreground.cb) || !isAbout(cell.cr, foreground.cr) { wrongTextCells += 1 }
                    } else if brightness.allSatisfy({ $0 == background.y }) {
                        backgroundCells += 1
                        if !isAbout(cell.cb, background.cb) || !isAbout(cell.cr, background.cr) { wrongBackgroundCells += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(textCells, 10, "block at \(x), \(y): no cells that are all text")
            XCTAssertEqual(wrongTextCells, 0, "block at \(x), \(y): cells under the text without its color")
            XCTAssertGreaterThan(backgroundCells, 1000, "block at \(x), \(y)")
            XCTAssertEqual(wrongBackgroundCells, 0, "block at \(x), \(y): color of the text beside the text")
        }
    }

    func testFrameOfOddSizeAndBlocksOverItsEdges() throws {
        // 1179 × 301, an iPhone 15 Pro across: the last column and row of color cells have one pixel each
        let source = try videoFrame(width: 1179, height: 301)
        let before = picture(of: source)
        let corner = PlacedBlock(id: 1, text: "Edge", rect: CGRect(x: 1000, y: 250, width: 300, height: 60), visibleRect: nil,
                                 lineCount: 1, colors: darkOnLight)
        let outside = PlacedBlock(id: 2, text: "Top left", rect: CGRect(x: -50.5, y: -20.5, width: 300, height: 60), visibleRect: nil,
                                  lineCount: 1, colors: darkOnLight)
        let gone = PlacedBlock(id: 3, text: "Nowhere", rect: CGRect(x: 2000, y: 100, width: 300, height: 60), visibleRect: nil,
                               lineCount: 1, colors: darkOnLight)
        let result = picture(of: try XCTUnwrap(TranslationCompositor().compose(source, blocks: [corner, outside, gone])))
        XCTAssertTrue(picture(of: source) == before)
        let background = YCbCrColor(light, fullRange: false)
        // the box in the corner reaches the last pixel, and with it the cell that has only that pixel
        XCTAssertEqual(result.luma(1178, 300), background.y)
        XCTAssertEqual(result.cell(589, 150).cb, background.cb)
        XCTAssertEqual(result.cell(589, 150).cr, background.cr)
        // the box at the top left begins outside the frame; its right margin is at the columns 249…255
        XCTAssertEqual(result.luma(252, 10), background.y)
        // between the two boxes nothing happened
        var changed = 0
        for y in 0..<301 {
            for x in 320..<980 where result.luma(x, y) != before.luma(x, y) { changed += 1 }
        }
        XCTAssertEqual(changed, 0)
    }

    func testBlocksThatCannotBeDrawnAreLeftOut() throws {
        let source = try videoFrame(width: 640, height: 240)
        let before = picture(of: source)
        let blocks = [
            PlacedBlock(id: 1, text: "No number", rect: CGRect(x: CGFloat.nan, y: 10, width: 100, height: 30), visibleRect: nil,
                        lineCount: 1, colors: darkOnLight),
            PlacedBlock(id: 2, text: "Endless", rect: .infinite, visibleRect: nil, lineCount: 1, colors: darkOnLight),
            PlacedBlock(id: 3, text: "Nothing", rect: .null, visibleRect: nil, lineCount: 1, colors: darkOnLight),
            PlacedBlock(id: 4, text: "  ", rect: CGRect(x: 10, y: 10, width: 100, height: 30), visibleRect: nil, lineCount: 1,
                        colors: darkOnLight),
            PlacedBlock(id: 5, text: "Hidden", rect: CGRect(x: 10, y: 10, width: 100, height: 30), visibleRect: .null, lineCount: 1,
                        colors: darkOnLight),
        ]
        let compositor = TranslationCompositor()
        let copy = try XCTUnwrap(compositor.compose(source, blocks: blocks))
        XCTAssertFalse(copy === source)
        XCTAssertTrue(picture(of: copy) == before, "a block without text or without a place draws nothing, not even its box")
        // no blocks at all: still a copy
        XCTAssertTrue(picture(of: try XCTUnwrap(compositor.compose(source, blocks: []))) == before)
    }

    /// The box takes the values of the frame, whatever matrix the video was coded with. A
    /// saturated color of BT.601 video lies outside of RGB with the BT.709 numbers, and a box
    /// converted back from the clamped RGB stood out from its surroundings.
    func testBoxOnASaturatedColorOfBT601VideoHasExactlyItsValues() throws {
        // the red (255, 59, 48) and the blue (0, 122, 255) of iOS as BT.601 codes them
        for color in [YCbCrColor(y: 116, cb: 94, cr: 215), YCbCrColor(y: 102, cb: 204, cr: 65)] {
            let source = try uniformVideoFrame(width: 640, height: 240, color: color)
            let place = CGRect(x: 101, y: 61, width: 300, height: 60)
            let colors = FramePixels.blockColors(in: place, of: source)
            let placed = PlacedBlock(id: 1, text: "Löschen", rect: place, visibleRect: nil, lineCount: 1, colors: colors)
            let result = picture(of: try XCTUnwrap(TranslationCompositor().compose(source, blocks: [placed])))
            let text = PixelRect(minX: 101, minY: 61, maxX: 401, maxY: 121), backdrop = text.grown(by: 7)
            var wrongBrightness = 0, paper = 0, wrongColor = 0
            for y in 0..<result.height {
                for x in 0..<result.width where !isCorner(of: backdrop, x, y) {
                    let value = result.luma(x, y)
                    if !contains(text, x, y) {
                        if value != color.y { wrongBrightness += 1 }
                    } else if value == color.y {
                        paper += 1
                    }
                }
            }
            // (under the text the color is mixed with that of the text)
            for y in 0..<result.chromaHeight {
                for x in 0..<result.chromaWidth
                    where PixelRect(minX: 2 * x, minY: 2 * y, maxX: 2 * x + 2, maxY: 2 * y + 2).intersection(text).isEmpty {
                    let cell = result.cell(x, y)
                    if cell.cb != color.cb || cell.cr != color.cr { wrongColor += 1 }
                }
            }
            XCTAssertEqual(wrongBrightness, 0, "\(color): the box must have the brightness of the frame")
            XCTAssertEqual(wrongColor, 0, "\(color): the box must have the color of the frame")
            XCTAssertGreaterThan(paper, text.width * text.height / 2, "\(color)")
        }
    }

    // MARK: BGRA

    func testBGRAFrameGetsTheBoxAndKeepsEverythingElse() throws {
        let source = try bgraFrame(width: 1170, height: 400)
        let before = picture(of: source)
        let colors = BlockColors(background: RGBColor(red: 250, green: 240, blue: 200), foreground: RGBColor(red: 10, green: 40, blue: 120))
        let visible = PixelRect(minX: 150, minY: 141, maxX: 655, maxY: 400)
        for part in [nil, visible] {
            let copy = try XCTUnwrap(TranslationCompositor().compose(source, blocks: [block(visible: part?.cgRect, colors: colors)]))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(copy), kCVPixelFormatType_32BGRA)
            XCTAssertTrue(picture(of: source) == before, "the frame of the device must stay as it is")
            let result = picture(of: copy)
            let backdrop = text.grown(by: margin)
            let area = part.map { backdrop.intersection($0) } ?? backdrop
            var changedOutside = 0, wrongInMargin = 0, outOfRange = 0, solid = 0, paper = 0
            for y in 0..<result.height {
                for x in 0..<result.width {
                    let color = result.color(x, y)
                    guard contains(area, x, y) else {
                        if color != before.color(x, y) || result.alpha(x, y) != before.alpha(x, y) { changedOutside += 1 }
                        continue
                    }
                    if isCorner(of: backdrop, x, y) { continue }
                    if !contains(text, x, y) {
                        if color != colors.background || result.alpha(x, y) != 255 { wrongInMargin += 1 }
                        continue
                    }
                    if color == colors.foreground { solid += 1 }
                    if color == colors.background { paper += 1 }
                    let redFits = isBetween(color.red, colors.background.red, colors.foreground.red)
                    let greenFits = isBetween(color.green, colors.background.green, colors.foreground.green)
                    let blueFits = isBetween(color.blue, colors.background.blue, colors.foreground.blue)
                    if !redFits || !greenFits || !blueFits { outOfRange += 1 }
                }
            }
            let textArea = area.intersection(text)
            XCTAssertEqual(changedOutside, 0, "pixels changed outside the box")
            XCTAssertEqual(wrongInMargin, 0, "the margin of the box must have exactly the background color")
            XCTAssertEqual(outOfRange, 0, "inside the box there are only the two colors and their mixtures")
            XCTAssertGreaterThan(solid, 50, "the translation must be there, in exactly its color")
            XCTAssertGreaterThan(paper, textArea.width * textArea.height / 2)
        }
    }

    // MARK: Which way up

    func testTextMaskStandsUpright() throws {
        try checkOrientation { text, width, height, lineCount in
            let mask = try XCTUnwrap(BlockTextMask(text: text, width: width, height: height, lineCount: lineCount))
            XCTAssertEqual(mask.pixels.count, width * height)
            return Ink(width: width, height: height, cells: mask.pixels.map { $0 > 127 })
        }
    }

    func testTextStandsUprightInAVideoFrame() throws {
        try checkOrientation { text, width, height, lineCount in
            // at an odd position, off the middle of the frame: a flip moves it elsewhere
            let source = try self.videoFrame(width: 640, height: 300)
            let placed = PlacedBlock(id: 1, text: text, rect: CGRect(x: 51, y: 33, width: width, height: height),
                                     visibleRect: nil, lineCount: lineCount, colors: self.darkOnLight)
            let result = self.picture(of: try XCTUnwrap(TranslationCompositor().compose(source, blocks: [placed])))
            let background = Int(YCbCrColor(self.light, fullRange: false).y), foreground = Int(YCbCrColor(self.dark, fullRange: false).y)
            var cells: [Bool] = []
            for y in 33..<(33 + height) {
                for x in 51..<(51 + width) {
                    let value = Int(result.luma(x, y))
                    cells.append(abs(value - foreground) < abs(value - background))
                }
            }
            return Ink(width: width, height: height, cells: cells)
        }
    }

    func testTextStandsUprightInABGRAFrame() throws {
        try checkOrientation { text, width, height, lineCount in
            let source = try self.bgraFrame(width: 640, height: 300)
            let placed = PlacedBlock(id: 1, text: text, rect: CGRect(x: 51, y: 33, width: width, height: height),
                                     visibleRect: nil, lineCount: lineCount, colors: self.darkOnLight)
            let result = self.picture(of: try XCTUnwrap(TranslationCompositor().compose(source, blocks: [placed])))
            var cells: [Bool] = []
            for y in 33..<(33 + height) {
                for x in 51..<(51 + width) { cells.append(result.color(x, y).green < 128) }
            }
            return Ink(width: width, height: height, cells: cells)
        }
    }

    /// `ink`: where the text of a block of the given size is (text, width, height, lines of the original)
    private func checkOrientation(_ ink: (String, Int, Int, Int) throws -> Ink) throws {
        // a line 60 pixels high: the baseline lies in its lower third
        let low = try XCTUnwrap(try ink("_", 400, 60, 1).bounds, "nothing was drawn")
        XCTAssertGreaterThan(low.minY, 30, "an underscore lies in the lower half of its line")
        let high = try XCTUnwrap(try ink("'", 400, 60, 1).bounds, "nothing was drawn")
        XCTAssertLessThan(high.maxY, 30, "an apostrophe lies in the upper half of its line")

        let letter = try ink("L", 400, 60, 1)
        let bounds = try XCTUnwrap(letter.bounds, "nothing was drawn")
        XCTAssertLessThan(bounds.maxX, 200, "text starts at the left edge of its block")
        let middleX = (bounds.minX + bounds.maxX) / 2, middleY = (bounds.minY + bounds.maxY) / 2
        XCTAssertGreaterThan(letter.count(PixelRect(minX: bounds.minX, minY: bounds.minY, maxX: middleX, maxY: bounds.maxY)),
                             letter.count(PixelRect(minX: middleX, minY: bounds.minY, maxX: bounds.maxX, maxY: bounds.maxY)),
                             "the stem of an L is on its left")
        XCTAssertGreaterThan(letter.count(PixelRect(minX: bounds.minX, minY: middleY, maxX: bounds.maxX, maxY: bounds.maxY)),
                             letter.count(PixelRect(minX: bounds.minX, minY: bounds.minY, maxX: bounds.maxX, maxY: middleY)),
                             "the foot of an L is at its bottom")

        // one line as the translation of three: it stands in the middle of the block
        let centered = try XCTUnwrap(try ink("OK", 400, 180, 3).bounds, "nothing was drawn")
        XCTAssertGreaterThanOrEqual(centered.minY, 60, "a single line stands in the middle third of a block of three lines")
        XCTAssertLessThanOrEqual(centered.maxY, 120, "a single line stands in the middle third of a block of three lines")

        // two lines of 60 pixels, wide enough for the long word but not for both
        let lines = try ink("HHHHHHHH HH", 330, 120, 2)
        let first = try XCTUnwrap(lines.bounds(rows: 0..<60), "no first line")
        let second = try XCTUnwrap(lines.bounds(rows: 60..<120), "no second line")
        XCTAssertGreaterThan(first.width, 2 * second.width, "the first word stands above the second")
    }

    // MARK: Fitting

    func testShortTextKeepsTheSizeOfTheOriginalOnOneLine() throws {
        let mask = try XCTUnwrap(BlockTextMask(text: "Two words", width: 600, height: 60, lineCount: 1))
        XCTAssertEqual(mask.lineCount, 1, "text that fits is not broken")
        XCTAssertTrue(mask.fits)
        // 82 % of the line height unless the font is unusually tall
        XCTAssertGreaterThan(mask.fontSize, 42)
        XCTAssertLessThanOrEqual(mask.fontSize, 0.82 * 60 + 0.001)
        XCTAssertEqual(mask.width, 600)
        XCTAssertEqual(mask.height, 60)
    }

    func testLongTextIsSetSmallerUntilItFits() throws {
        // one line of the original, 60 pixels high: at 49 pixels this is far too long, in two
        // lines of about 22 pixels it fits
        let long = "Benachrichtigungen anpassen und speichern"
        let mask = try XCTUnwrap(BlockTextMask(text: long, width: 300, height: 60, lineCount: 1))
        XCTAssertTrue(mask.fits, "at some size between 17 and 49 pixels this fits")
        XCTAssertLessThan(mask.fontSize, 40)
        XCTAssertGreaterThanOrEqual(mask.fontSize, BlockTextMask.smallestFontShare * 60)
        XCTAssertGreaterThan(mask.lineCount, 1)
        XCTAssertGreaterThan(mask.pixels.filter { $0 > 127 }.count, 100)

        // drawn into a frame it stays inside its box
        let source = try videoFrame(width: 640, height: 240)
        let before = picture(of: source)
        let placed = PlacedBlock(id: 1, text: long, rect: CGRect(x: 100, y: 80, width: 300, height: 60), visibleRect: nil,
                                 lineCount: 1, colors: darkOnLight)
        let result = picture(of: try XCTUnwrap(TranslationCompositor().compose(source, blocks: [placed])))
        checkVideo(result, source: before, text: PixelRect(minX: 100, minY: 80, maxX: 400, maxY: 140), margin: 7, visible: nil,
                   colors: darkOnLight, smallPrint: true)
    }

    /// German compounds are often wider than their block at the size of the original. Core Text
    /// then breaks them between two letters, without a hyphen; a smaller font that keeps the
    /// word whole reads better.
    func testLongWordsAreNotBrokenBetweenTwoLetters() throws {
        func lines(_ text: String, _ width: Int, _ height: Int, _ lineCount: Int) throws -> [String] {
            let mask = try XCTUnwrap(BlockTextMask(text: text, width: width, height: height, lineCount: lineCount))
            XCTAssertTrue(mask.fits, text)
            XCTAssertEqual(mask.lineCount, mask.lines.count)
            return mask.lines.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        XCTAssertEqual(try lines("Benachrichtigungseinstellungen", 222, 40, 1), ["Benachrichtigungseinstellungen"])
        XCTAssertEqual(try lines("Mobilfunkdatennutzung", 180, 44, 1), ["Mobilfunkdatennutzung"])
        XCTAssertEqual(try lines("Datenschutzeinstellungen verwalten", 260, 80, 2), ["Datenschutzeinstellungen", "verwalten"])
        // a hyphen is a place to break
        XCTAssertEqual(try lines("E-Mail-Adressen", 120, 60, 2).first?.last, "-")

        // Chinese is broken between any two characters, as everywhere: that is no reason to set it smaller
        let chinese = try XCTUnwrap(BlockTextMask(text: "设置与隐私：翻译后的文字", width: 300, height: 120, lineCount: 2))
        XCTAssertEqual(chinese.lineCount, 2)
        XCTAssertEqual(chinese.fontSize, 0.82 * 60, accuracy: 0.001)

        // a word too long even for the smallest font is still drawn, broken where it has to be
        let endless = try XCTUnwrap(BlockTextMask(text: "Donaudampfschifffahrtsgesellschaftskapitänsmütze",
                                                  width: 120, height: 40, lineCount: 1))
        XCTAssertTrue(endless.fits)
        XCTAssertGreaterThanOrEqual(endless.fontSize, BlockTextMask.smallestFontShare * 40 - 0.001)
        XCTAssertGreaterThan(endless.lineCount, 1)
        XCTAssertGreaterThan(endless.pixels.filter { $0 > 127 }.count, 100)
        // Such a word is broken at any size, so it gets the largest size at which its lines fit
        // the block, not the smallest one.
        for (text, width, height, lineCount) in [("Benachrichtigungseinstellungen", 120, 40, 1),
                                                 ("Kraftfahrzeughaftpflichtversicherung", 150, 88, 2)] {
            let mask = try XCTUnwrap(BlockTextMask(text: text, width: width, height: height, lineCount: lineCount))
            XCTAssertTrue(mask.fits, text)
            XCTAssertGreaterThan(mask.lineCount, 1, text)
            XCTAssertEqual(mask.lines.joined(), text)
            let smallest = BlockTextMask.smallestFontShare * CGFloat(height) / CGFloat(lineCount)
            XCTAssertGreaterThan(mask.fontSize, smallest + 2, text)
        }
    }

    /// Japanese, Chinese and Korean may be broken between any two characters, also before ー
    /// and the small kana, where Core Text breaks them once it knows the language. That is no
    /// broken word and no reason to set the text in the smallest font.
    func testScriptsWithoutSpacesAreNotSetSmallerForTheirLineBreaks() throws {
        let cases: [(text: String, width: Int, height: Int, lineCount: Int, language: String)] = [
            ("プライバシーとセキュリティ", 140, 44, 1, "ja"),
            ("メールアカウントのセキュリティ設定", 150, 80, 2, "ja-Jpan-JP"),
            ("一般情報とプライバシーとセキュリティの設定", 200, 60, 2, "ja"),
            ("ユーザーアカウントとパスワードのリセット", 160, 70, 2, "ja"),
            ("设置与隐私：翻译后的文字", 160, 60, 2, "zh-Hans-CN"),
            ("通知設定與隱私權保護的選項", 150, 60, 2, "zh-Hant-TW"),
            ("개인정보보호및보안설정관리", 150, 60, 2, "ko"),
            ("개인 정보 보호 및 보안 설정을 관리합니다", 160, 60, 2, "ko-KR"),
        ]
        // where a line may end, by the characters on both sides alone
        func breaksWord(_ before: String, _ after: String) -> Bool {
            !BlockTextMask.wordKeepingLineEnds(in: before + after).contains(before.utf16.count)
        }
        XCTAssertFalse(breaksWord("プライバシ", "ーと"))
        XCTAssertFalse(breaksWord("セキ", "ュリティ"))
        XCTAssertFalse(breaksWord("セキュリテ", "ィ"))
        XCTAssertFalse(breaksWord("設", "定"))
        XCTAssertFalse(breaksWord("隐私", "翻译"))
        XCTAssertFalse(breaksWord("개인", "정보"))
        XCTAssertFalse(breaksWord("ภาษา", "ไทย"))
        XCTAssertFalse(breaksWord("iOS 2024", "年"))
        XCTAssertFalse(breaksWord("𠮷", "野家"))
        XCTAssertFalse(breaksWord("Datenschutz ", "verwalten"))
        XCTAssertFalse(breaksWord("E-", "Mail"))
        XCTAssertTrue(breaksWord("Benachrichtigun", "gseinstellungen"))
        XCTAssertTrue(breaksWord("Привет", "ствие"))
        XCTAssertTrue(breaksWord("12", "345"))
        XCTAssertTrue(breaksWord("cafe\u{301}", "s"))
        for item in cases {
            for language in [item.language, nil] {
                let label = "\(item.text) \(language ?? "no language")"
                let mask = try XCTUnwrap(BlockTextMask(text: item.text, width: item.width, height: item.height,
                                                       lineCount: item.lineCount, language: language), label)
                XCTAssertTrue(mask.fits, label)
                XCTAssertGreaterThan(mask.lineCount, 1, label)
                XCTAssertEqual(mask.lines.joined(), item.text, label)
                let lineHeight = CGFloat(item.height) / CGFloat(item.lineCount)
                XCTAssertGreaterThan(mask.fontSize, BlockTextMask.smallestFontShare * lineHeight + 1, label)
            }
        }
    }

    /// Where a line may end, in every script the translations come in. `|` marks a line end
    /// that must keep words whole (`breaks`) or that breaks one (`keeps`); `whole` must stay on
    /// one line when the text is set in the box. Each text is set with its language and
    /// without one, and a wider box never gets a smaller font than a slightly narrower one.
    func testLineEndsKeepWordsAndPunctuationWhole() throws {
        struct Case {
            let text: String
            let width: Int, height: Int, lineCount: Int
            let language: String
            /// line ends that keep words whole: Core Text may break there
            var breaks: [String] = []
            /// line ends that break a word or part a word from its punctuation
            var keeps: [String] = []
            /// must not be broken over two lines
            var whole: [String] = []
            /// also set without a language; Core Text then breaks it the way the languages of the
            /// Mac say, which for a German closing quote differ between an English and a German Mac
            var withoutLanguage = true
        }
        let cases: [Case] = [
            // German and English compounds and words
            Case(text: "Benachrichtigungseinstellungen", width: 222, height: 40, lineCount: 1, language: "de",
                 keeps: ["Benachrichtigun|gseinstellungen"], whole: ["Benachrichtigungseinstellungen"]),
            Case(text: "Datenschutzeinstellungen verwalten", width: 260, height: 80, lineCount: 2, language: "de",
                 breaks: ["Datenschutzeinstellungen |verwalten"], whole: ["Datenschutzeinstellungen", "verwalten"]),
            Case(text: "Notifications and accessibility settings", width: 150, height: 60, lineCount: 2,
                 language: "en", breaks: ["and |accessibility"], keeps: ["accessi|bility"],
                 whole: ["Notifications", "accessibility", "settings"]),
            // punctuation stays with the word before it, never alone at the start of a line
            Case(text: "Mitteilungen, Töne und Haptik", width: 90, height: 60, lineCount: 2, language: "de",
                 breaks: ["Mitteilungen, |Töne"], keeps: ["Mitteilungen|, Töne"], whole: ["Mitteilungen,"]),
            Case(text: "Mobilfunkdatennutzung.", width: 150, height: 60, lineCount: 2, language: "de",
                 keeps: ["Mobilfunkdatennutzung|."], whole: ["Mobilfunkdatennutzung."]),
            Case(text: "Ist das erlaubt? Ja!", width: 70, height: 40, lineCount: 2, language: "de",
                 breaks: ["erlaubt? |Ja"], keeps: ["erlaubt|?", "Ja|!"], whole: ["erlaubt?", "Ja!"]),
            Case(text: "Bildschirmzeit (Einstellungen)", width: 110, height: 60, lineCount: 2, language: "de",
                 breaks: ["Bildschirmzeit |(Einstellungen"], keeps: ["Einstellungen|)"], whole: ["Einstellungen)"]),
            Case(text: "Привет, мир", width: 60, height: 40, lineCount: 1, language: "ru",
                 keeps: ["Привет|, мир", "При|вет"], whole: ["Привет,"]),
            // an opening bracket or quote stays with the word after it, never alone at a line end
            Case(text: "Tippe auf „Allgemein“ und dann auf (Info)", width: 120, height: 80, lineCount: 2,
                 language: "de", breaks: ["auf |„Allgemein", "auf |(Info"],
                 keeps: ["„|Allgemein", "Allgemein|“", "(|Info", "Info|)"], whole: ["„Allgemein“", "(Info)"],
                 withoutLanguage: false),
            Case(text: "Tap “Allow” to continue", width: 90, height: 60, lineCount: 2, language: "en",
                 breaks: ["Tap |“Allow", "Allow” |to"], keeps: ["“|Allow", "Allow|”"], whole: ["“Allow”"]),
            Case(text: "Tap \"Allow\" to continue", width: 90, height: 60, lineCount: 2, language: "en",
                 keeps: ["\"|Allow", "Allow|\""], whole: ["\"Allow\""]),
            // hyphens and soft hyphens are places to break
            Case(text: "E-Mail-Adressen", width: 120, height: 60, lineCount: 2, language: "de",
                 breaks: ["E-|Mail", "Mail-|Adressen"], keeps: ["E-Ma|il"]),
            Case(text: "Daten\u{AD}schutz\u{AD}einstellungen", width: 140, height: 60, lineCount: 2, language: "de",
                 breaks: ["Daten\u{AD}|schutz", "schutz\u{AD}|einstellungen"], keeps: ["Daten\u{AD}schu|tz"]),
            // an address breaks after its slashes and dots, a long number nowhere
            Case(text: "Besuche https://www.example.com/settings/privacy", width: 160, height: 60, lineCount: 2,
                 language: "de", breaks: ["https://|www", "settings/|privacy"], keeps: ["htt|ps", "priv|acy"],
                 whole: ["Besuche"]),
            Case(text: "Kundennummer 12345678901234", width: 140, height: 60, lineCount: 2, language: "de",
                 breaks: ["Kundennummer |1234"], keeps: ["1234567|8901234"], whole: ["Kundennummer", "12345678901234"]),
            // Japanese: kana before ー and small kana, fullwidth digits and letters, Latin words
            Case(text: "プライバシーとセキュリティ", width: 140, height: 44, lineCount: 1, language: "ja",
                 breaks: ["プライバシ|ーと", "セキ|ュリティ", "シー|と"]),
            Case(text: "パスワードは数字１２３４５６を含めてください", width: 140, height: 60, lineCount: 2,
                 language: "ja", breaks: ["数字１２|３４", "ワー|ド", "６|を"]),
            Case(text: "ＩＤ：１２３４５６７８", width: 180, height: 60, lineCount: 2, language: "ja",
                 breaks: ["Ｉ|Ｄ", "ＩＤ|：", "：|１２", "１２３|４"]),
            Case(text: "iPhoneの設定でPasswordを変更してください", width: 150, height: 60, lineCount: 2,
                 language: "ja", breaks: ["iPhone|の", "で|Password", "Password|を"],
                 keeps: ["iPho|ne", "Pass|word"], whole: ["iPhone", "Password"]),
            // Chinese and Korean
            Case(text: "设置与隐私：翻译后的文字", width: 160, height: 60, lineCount: 2, language: "zh-Hans-CN",
                 breaks: ["设置|与", "隐私|：", "隐私：|翻译"]),
            Case(text: "개인 정보 보호 및 보안 설정을 관리합니다", width: 160, height: 60, lineCount: 2, language: "ko-KR",
                 breaks: ["개인 |정보", "정|보", "관리|합니다"]),
            // Thai, written without spaces between words
            Case(text: "การตั้งค่าความเป็นส่วนตัวและความปลอดภัย", width: 150, height: 60, lineCount: 2, language: "th",
                 breaks: ["การตั้งค่า|ความ", "ความเป็น|ส่วนตัว"]),
            // Arabic and Hebrew, written from the right, with spaces between words
            Case(text: "إعدادات الخصوصية والأمان", width: 110, height: 60, lineCount: 2, language: "ar",
                 breaks: ["الخصوصية |والأمان"], keeps: ["الخصو|صية"], whole: ["إعدادات", "الخصوصية", "والأمان"]),
            Case(text: "הגדרות פרטיות ואבטחה, עכשיו", width: 110, height: 60, lineCount: 2, language: "he",
                 breaks: ["פרטיות |ואבטחה"], keeps: ["פרטי|ות", "ואבטחה|,"], whole: ["ואבטחה,"]),
            // emoji: between them and words where there are spaces, never inside one
            Case(text: "Gut gemacht 👍🏽 weiter so 🎉", width: 100, height: 60, lineCount: 2, language: "de",
                 breaks: ["👍🏽 |weiter", "gemacht |👍🏽"], keeps: ["👍|🏽", "wei|ter"], whole: ["gemacht", "weiter"]),
        ]
        /// the text with `|` taken out, and the offset in UTF-16 units where it was (counted in
        /// units, since `|` and an emoji modifier after it make one character)
        func lineEnd(_ marked: String) -> (text: String, offset: Int) {
            var units = Array(marked.utf16)
            let bar = units.firstIndex(of: 0x7C)!
            units.remove(at: bar)
            precondition(!units.contains(0x7C), marked)
            return (String(decoding: units, as: UTF16.self), bar)
        }
        for item in cases {
            let allowed = BlockTextMask.wordKeepingLineEnds(in: item.text, language: item.language)
            for (marked, keepsWords) in item.breaks.map({ ($0, true) }) + item.keeps.map({ ($0, false) }) {
                let (part, offset) = lineEnd(marked)
                let start = (item.text as NSString).range(of: part, options: .literal).location
                XCTAssertNotEqual(start, NSNotFound, "\(marked) is not in \(item.text)")
                XCTAssertEqual(allowed.contains(start + offset), keepsWords, "line end \(marked)")
            }
            for language in item.withoutLanguage ? [item.language, nil] : [item.language] {
                let label = "\(item.text) \(language ?? "no language")"
                func mask(_ width: Int) throws -> BlockTextMask {
                    try XCTUnwrap(BlockTextMask(text: item.text, width: width, height: item.height,
                                                lineCount: item.lineCount, language: language), "\(label) \(width)")
                }
                let set = try mask(item.width)
                XCTAssertTrue(set.fits, label)
                XCTAssertEqual(set.lines.joined(), item.text, label)
                for word in item.whole {
                    XCTAssertTrue(set.lines.contains { $0.contains(word) }, "\(label): \(word) broken in \(set.lines)")
                }
                // nothing the search does may make a wider box come out smaller
                for narrower in [item.width - 3, item.width - 8, item.width - 20] {
                    XCTAssertGreaterThanOrEqual(set.fontSize, try mask(narrower).fontSize - 0.001,
                                                "\(label): \(item.width) against \(narrower)")
                }
                // no size anywhere near the smallest only because of how the script breaks
                let lineHeight = CGFloat(item.height) / CGFloat(item.lineCount)
                XCTAssertGreaterThan(set.fontSize, BlockTextMask.smallestFontShare * lineHeight + 1, label)
            }
        }
    }

    /// The mask says where the text covers the block. An emoji is drawn in its own colors; what
    /// counts for the mask is its shape, not how bright its colors are.
    func testEmojiCoverTheirShapeInTheMask() throws {
        let mask = try XCTUnwrap(BlockTextMask(text: "😀", width: 120, height: 60, lineCount: 1))
        let covered = mask.pixels.filter { $0 > 0 }
        XCTAssertGreaterThan(covered.count, 500)
        // inside the shape it covers fully; only its edge is partly covered
        let full = covered.filter { $0 >= 250 }.count
        XCTAssertGreaterThan(full * 10, covered.count * 7, "an emoji must not come out as a half transparent blot")
        // and letters still cover as before
        let letters = try XCTUnwrap(BlockTextMask(text: "Hello", width: 200, height: 60, lineCount: 1))
        XCTAssertGreaterThan(letters.pixels.filter { $0 == 255 }.count, 300)
    }

    /// Japanese, Chinese and Korean share characters that each draws in its own forms: the
    /// language of the translation chooses them, not the languages of the Mac.
    func testTheLanguageOfTheTranslationChoosesTheGlyphForms() throws {
        func mask(_ language: String?) throws -> [UInt8] {
            try XCTUnwrap(BlockTextMask(text: "直骨", width: 200, height: 60, lineCount: 1, language: language)).pixels
        }
        XCTAssertNotEqual(try mask("ja-Jpan-JP"), try mask("zh-Hans-CN"))
        XCTAssertNotEqual(try mask("zh-Hant-TW"), try mask("zh-Hans-CN"))
        XCTAssertEqual(try mask("ja-Jpan-JP"), try mask("ja"))

        // the compositor draws in the language it was given, and anew when that changes
        let source = try videoFrame(width: 640, height: 240)
        let placed = PlacedBlock(id: 1, text: "直骨", rect: CGRect(x: 40, y: 40, width: 200, height: 60), visibleRect: nil,
                                 lineCount: 1, colors: darkOnLight)
        let compositor = TranslationCompositor()
        compositor.language = "zh-Hans-CN"
        let chinese = picture(of: try XCTUnwrap(compositor.compose(source, blocks: [placed])))
        compositor.language = "ja-Jpan-JP"
        let japanese = picture(of: try XCTUnwrap(compositor.compose(source, blocks: [placed])))
        XCTAssertEqual(compositor.texts.drawCount, 2)
        XCTAssertFalse(japanese == chinese)
        let other = TranslationCompositor()
        other.language = "ja-Jpan-JP"
        XCTAssertTrue(picture(of: try XCTUnwrap(other.compose(source, blocks: [placed]))) == japanese)
    }

    func testTextThatCannotFitIsCutOffNotLeftOut() throws {
        let endless = String(repeating: "word ", count: 80)
        let mask = try XCTUnwrap(BlockTextMask(text: endless, width: 120, height: 24, lineCount: 1))
        XCTAssertFalse(mask.fits)
        // not smaller than 9 pixels, however much text there is
        XCTAssertEqual(mask.fontSize, 9, accuracy: 0.001)
        XCTAssertGreaterThan(mask.lineCount, 0)
        XCTAssertGreaterThan(mask.pixels.filter { $0 > 64 }.count, 20)
        // a line break in a translation does not start a new paragraph
        let broken = try XCTUnwrap(BlockTextMask(text: "Two\nwords", width: 600, height: 60, lineCount: 1))
        XCTAssertEqual(broken.lineCount, 1)
        XCTAssertNil(BlockTextMask(text: " \n ", width: 600, height: 60, lineCount: 1))
        XCTAssertNil(BlockTextMask(text: "Text", width: 0, height: 60, lineCount: 1))
    }

    // MARK: The copy

    func testCopyHasFormatSizeAndAttachmentsOfTheFrame() throws {
        let compositor = TranslationCompositor()
        let frames = [try videoFrame(width: 640, height: 360), try videoFrame(width: 322, height: 200, fullRange: true),
                      try bgraFrame(width: 640, height: 360)]
        for source in frames {
            CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            let copy = try XCTUnwrap(compositor.compose(source, blocks: [block()]))
            XCTAssertFalse(copy === source)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(copy), CVPixelBufferGetPixelFormatType(source))
            XCTAssertEqual(CVPixelBufferGetWidth(copy), CVPixelBufferGetWidth(source))
            XCTAssertEqual(CVPixelBufferGetHeight(copy), CVPixelBufferGetHeight(source))
            for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
                let value = try XCTUnwrap(CVBufferCopyAttachment(copy, key, nil) as? String, "\(key) is missing on the copy")
                XCTAssertEqual(value, CVBufferCopyAttachment(source, key, nil) as? String)
            }
        }
    }

    func testUnsupportedPixelFormatGivesNoCopy() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB, nil, &buffer)
        XCTAssertNil(TranslationCompositor().compose(try XCTUnwrap(buffer), blocks: [block()]))
    }

    // MARK: Drawn once

    func testPreparedTextIsNotDrawnAgain() throws {
        let source = try videoFrame(width: 640, height: 240)
        let place = CGRect(x: 40, y: 50, width: 300, height: 48)
        let placed = PlacedBlock(id: 7, text: "Prepared text", rect: place, visibleRect: nil, lineCount: 1, colors: darkOnLight)
        let translated = TrackedBlock(id: 7, text: "Vorbereiteter Text", rect: place, lineCount: 1, colors: darkOnLight,
                                      translation: "Prepared text", isStale: false)
        let untranslated = TrackedBlock(id: 8, text: "Noch nicht", rect: place.offsetBy(dx: 0, dy: 80), lineCount: 1,
                                        colors: darkOnLight, translation: nil, isStale: false)

        let direct = TranslationCompositor()
        let expected = picture(of: try XCTUnwrap(direct.compose(source, blocks: [placed])))
        XCTAssertEqual(direct.texts.drawCount, 1)

        let prepared = TranslationCompositor()
        prepared.prepare([translated, untranslated])
        XCTAssertEqual(prepared.texts.drawCount, 1, "only blocks with a translation are drawn")
        let result = picture(of: try XCTUnwrap(prepared.compose(source, blocks: [placed])))
        XCTAssertEqual(prepared.texts.drawCount, 1, "compose must use what prepare has drawn")
        XCTAssertTrue(result == expected, "prepared or not, the frame looks the same")

        // scrolled by a fraction of a pixel and by many pixels: still the same drawn text
        var moved = placed
        for step in 1...8 {
            moved.rect = place.offsetBy(dx: 0.3 * CGFloat(step), dy: 13.7 * CGFloat(step))
            XCTAssertNotNil(prepared.compose(source, blocks: [moved]))
        }
        XCTAssertEqual(prepared.texts.drawCount, 1)
        // another translation or another size is another text
        moved.text = "Another text"
        XCTAssertNotNil(prepared.compose(source, blocks: [moved]))
        moved.rect.size.width = 280
        XCTAssertNotNil(prepared.compose(source, blocks: [moved]))
        XCTAssertEqual(prepared.texts.drawCount, 3)
        XCTAssertEqual(prepared.texts.count, 3)

        prepared.reset()
        XCTAssertEqual(prepared.texts.count, 0)
        let again = picture(of: try XCTUnwrap(prepared.compose(source, blocks: [placed])))
        XCTAssertTrue(again == expected, "after a reset everything is drawn anew")
        XCTAssertEqual(prepared.texts.drawCount, 4)
    }

    func testPreparedColoredTextLooksLikeUnpreparedText() throws {
        // text in a color of its own: prepare also makes the masks of the color plane
        let colors = BlockColors(background: RGBColor(red: 0, green: 60, blue: 200), foreground: RGBColor(red: 255, green: 235, blue: 0))
        let source = try videoFrame(width: 640, height: 240)
        let place = CGRect(x: 41, y: 51, width: 300, height: 48)
        let placed = PlacedBlock(id: 7, text: "Yellow on blue", rect: place, visibleRect: nil, lineCount: 1, colors: colors)
        let expected = picture(of: try XCTUnwrap(TranslationCompositor().compose(source, blocks: [placed])))
        let prepared = TranslationCompositor()
        prepared.prepare([TrackedBlock(id: 7, text: "Gelb auf Blau", rect: place, lineCount: 1, colors: colors,
                                       translation: "Yellow on blue", isStale: false)])
        XCTAssertTrue(picture(of: try XCTUnwrap(prepared.compose(source, blocks: [placed]))) == expected)
        XCTAssertEqual(prepared.texts.drawCount, 1)
    }

    func testOldTextsMakeRoomForNewOnes() throws {
        let cache = BlockTextCache(limit: 8, byteLimit: 1 << 20)
        for id in 0..<8 {
            XCTAssertNotNil(cache.entry(id: id, text: "Text \(id)", width: 80, height: 20, lineCount: 1))
        }
        XCTAssertEqual(cache.count, 8)
        // the first one is used again, then a ninth text arrives
        XCTAssertNotNil(cache.entry(id: 0, text: "Text 0", width: 80, height: 20, lineCount: 1))
        XCTAssertNotNil(cache.entry(id: 8, text: "Text 8", width: 80, height: 20, lineCount: 1))
        XCTAssertEqual(cache.drawCount, 9)
        XCTAssertLessThanOrEqual(cache.count, 8)
        XCTAssertGreaterThanOrEqual(cache.count, 2)
        // the one used last and the new one are still there, the one used longest ago is not
        XCTAssertNotNil(cache.entry(id: 0, text: "Text 0", width: 80, height: 20, lineCount: 1))
        XCTAssertNotNil(cache.entry(id: 8, text: "Text 8", width: 80, height: 20, lineCount: 1))
        XCTAssertEqual(cache.drawCount, 9)
        XCTAssertNotNil(cache.entry(id: 1, text: "Text 1", width: 80, height: 20, lineCount: 1))
        XCTAssertEqual(cache.drawCount, 10)

        // too many bytes: 64 KB for texts of 2 × 200 × 100 bytes
        let small = BlockTextCache(limit: 100, byteLimit: 64 << 10)
        for id in 0..<6 {
            XCTAssertNotNil(small.entry(id: id, text: "Text \(id)", width: 200, height: 100, lineCount: 2))
        }
        XCTAssertLessThan(small.count, 2)
        XCTAssertGreaterThan(small.count, 0, "the text that was just drawn stays")
    }

    // MARK: Frames for the tests

    /// Brightness and color of the test frames. Every pixel differs from its neighbours, so a
    /// row copied with the wrong length or a picture standing on its head does not go
    /// unnoticed. The values keep away from those of the block colors used here.
    private static func testLuma(_ x: Int, _ y: Int) -> UInt8 { UInt8(60 + (x * 7 + y * 13) % 120) }
    private static func testCb(_ x: Int, _ y: Int) -> UInt8 { UInt8(70 + (x * 5 + y * 3) % 40) }
    private static func testCr(_ x: Int, _ y: Int) -> UInt8 { UInt8(150 + (x * 3 + y * 11) % 50) }

    private func videoFrame(width: Int, height: Int, fullRange: Bool = false, ioSurface: Bool = false) throws -> CVPixelBuffer {
        let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let frame = try emptyFrame(width: width, height: height, format: format, ioSurface: ioSurface)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 0)).assumingMemoryBound(to: UInt8.self)
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        for y in 0..<height {
            for x in 0..<width { luma[y * lumaRowBytes + x] = Self.testLuma(x, y) }
        }
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 1)).assumingMemoryBound(to: UInt8.self)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
        XCTAssertEqual(CVPixelBufferGetWidthOfPlane(frame, 1), (width + 1) / 2)
        XCTAssertEqual(CVPixelBufferGetHeightOfPlane(frame, 1), (height + 1) / 2)
        for y in 0..<(height + 1) / 2 {
            for x in 0..<(width + 1) / 2 {
                chroma[y * chromaRowBytes + 2 * x] = Self.testCb(x, y)
                chroma[y * chromaRowBytes + 2 * x + 1] = Self.testCr(x, y)
            }
        }
        return frame
    }

    /// A 4:2:0 frame (video range) of one color
    private func uniformVideoFrame(width: Int, height: Int, color: YCbCrColor) throws -> CVPixelBuffer {
        let frame = try emptyFrame(width: width, height: height, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                   ioSurface: false)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 0)).assumingMemoryBound(to: UInt8.self)
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame, 0)
        for y in 0..<height {
            for x in 0..<width { luma[y * lumaRowBytes + x] = color.y }
        }
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(frame, 1)).assumingMemoryBound(to: UInt8.self)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame, 1)
        for y in 0..<(height + 1) / 2 {
            for x in 0..<(width + 1) / 2 {
                chroma[y * chromaRowBytes + 2 * x] = color.cb
                chroma[y * chromaRowBytes + 2 * x + 1] = color.cr
            }
        }
        return frame
    }

    private func bgraFrame(width: Int, height: Int) throws -> CVPixelBuffer {
        let frame = try emptyFrame(width: width, height: height, format: kCVPixelFormatType_32BGRA, ioSurface: false)
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let pixels = try XCTUnwrap(CVPixelBufferGetBaseAddress(frame)).assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = pixels + y * rowBytes + 4 * x
                pixel[0] = Self.testCb(x, y)
                pixel[1] = Self.testLuma(x, y)
                pixel[2] = Self.testCr(x, y)
                pixel[3] = 255
            }
        }
        return frame
    }

    private func emptyFrame(width: Int, height: Int, format: OSType, ioSurface: Bool) throws -> CVPixelBuffer {
        var attributes: [CFString: Any] = [:]
        if ioSurface { attributes[kCVPixelBufferIOSurfacePropertiesKey] = [:] as CFDictionary }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &buffer)
        return try XCTUnwrap(buffer, "no pixel buffer")
    }

    // MARK: Reading frames

    /// The pixels of a frame without the padding of its rows
    private struct Picture: Equatable {
        var width = 0
        var height = 0
        /// 4:2:0: the brightness of every pixel; BGRA: its four bytes
        var main: [UInt8] = []
        /// 4:2:0: Cb and Cr of every 2 × 2 pixels
        var chroma: [UInt8] = []
        var chromaWidth = 0
        var chromaHeight = 0

        func luma(_ x: Int, _ y: Int) -> UInt8 { main[y * width + x] }

        func cell(_ x: Int, _ y: Int) -> (cb: UInt8, cr: UInt8) {
            (chroma[(y * chromaWidth + x) * 2], chroma[(y * chromaWidth + x) * 2 + 1])
        }

        func color(_ x: Int, _ y: Int) -> RGBColor {
            let index = (y * width + x) * 4
            return RGBColor(red: main[index + 2], green: main[index + 1], blue: main[index])
        }

        func alpha(_ x: Int, _ y: Int) -> UInt8 { main[(y * width + x) * 4 + 3] }
    }

    private func picture(of buffer: CVPixelBuffer) -> Picture {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var picture = Picture()
        picture.width = width
        picture.height = height
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return picture }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            var pixels: [UInt8] = []
            for y in 0..<height {
                pixels.append(contentsOf: UnsafeRawBufferPointer(start: base + y * rowBytes, count: width * 4))
            }
            picture.main = pixels
        } else {
            guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return picture }
            let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1), chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
            var brightness: [UInt8] = [], color: [UInt8] = []
            for y in 0..<height {
                brightness.append(contentsOf: UnsafeRawBufferPointer(start: luma + y * lumaRowBytes, count: width))
            }
            for y in 0..<chromaHeight {
                color.append(contentsOf: UnsafeRawBufferPointer(start: chroma + y * chromaRowBytes, count: chromaWidth * 2))
            }
            picture.main = brightness
            picture.chroma = color
            picture.chromaWidth = chromaWidth
            picture.chromaHeight = chromaHeight
        }
        return picture
    }

    /// A block on a 4:2:0 frame, pixel by pixel: nothing changed outside of what the block may
    /// change (`visible`: the part of the frame it is limited to); its margin has exactly the
    /// brightness and color of its background; inside there are the background, the text and
    /// their mixtures; the text is there.
    private func checkVideo(_ result: Picture, source: Picture, text: PixelRect, margin: Int, visible: PixelRect?,
                            colors: BlockColors, fullRange: Bool = false, textHasItsOwnColor: Bool = false,
                            smallPrint: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        let backdrop = text.grown(by: margin)
        let frame = PixelRect(minX: 0, minY: 0, maxX: result.width, maxY: result.height)
        let area = (visible.map { backdrop.intersection(shown($0, text: text, margin: margin)) } ?? backdrop).intersection(frame)
        let background = YCbCrColor(colors.background, fullRange: fullRange), foreground = YCbCrColor(colors.foreground, fullRange: fullRange)
        XCTAssertEqual(result.width, source.width, file: file, line: line)
        XCTAssertEqual(result.height, source.height, file: file, line: line)

        var changedOutside = 0, wrongInMargin = 0, outOfRange = 0, ink = 0, solid = 0, paper = 0
        for y in 0..<result.height {
            for x in 0..<result.width {
                let value = result.luma(x, y)
                guard contains(area, x, y) else {
                    if value != source.luma(x, y) { changedOutside += 1 }
                    continue
                }
                // the round corners are blended with the frame
                if isCorner(of: backdrop, x, y) { continue }
                if !contains(text, x, y) {
                    if value != background.y { wrongInMargin += 1 }
                    continue
                }
                if value == foreground.y { solid += 1 }
                if value == background.y { paper += 1 }
                if !isBetween(value, background.y, foreground.y) { outOfRange += 1 }
                let toText = abs(Int(value) - Int(foreground.y)), toBackground = abs(Int(value) - Int(background.y))
                if toText < toBackground { ink += 1 }
            }
        }
        XCTAssertEqual(changedOutside, 0, "brightness changed outside the box", file: file, line: line)
        XCTAssertEqual(wrongInMargin, 0, "the margin of the box must have exactly the brightness of the background", file: file, line: line)
        XCTAssertEqual(outOfRange, 0, "inside the box there are only background, text and their mixtures", file: file, line: line)
        let textArea = area.intersection(text)
        XCTAssertGreaterThan(ink, 50, "the translation must be there", file: file, line: line)
        // strokes of large print have pixels that are all text: exactly its brightness
        if !smallPrint { XCTAssertGreaterThan(solid, 50, "the text must have exactly its brightness", file: file, line: line) }
        XCTAssertGreaterThan(paper, textArea.width * textArea.height / 2, file: file, line: line)

        // the color: one value for the pixels 2 x, 2 x + 1 of the rows 2 y, 2 y + 1
        var colorChangedOutside = 0, wrongColorInside = 0, cellsInside = 0
        for y in 0..<result.chromaHeight {
            for x in 0..<result.chromaWidth {
                let cell = result.cell(x, y), pixels = PixelRect(minX: 2 * x, minY: 2 * y, maxX: 2 * x + 2, maxY: 2 * y + 2)
                let part = pixels.intersection(area)
                if part.isEmpty {
                    let old = source.cell(x, y)
                    if cell.cb != old.cb || cell.cr != old.cr { colorChangedOutside += 1 }
                } else if part == pixels.intersection(frame) {
                    // all of its pixels are in the box; under text of another color it is a mixture
                    cellsInside += 1
                    if textHasItsOwnColor, !pixels.intersection(text).isEmpty {
                        let cbFits = isBetween(cell.cb, background.cb, foreground.cb)
                        let crFits = isBetween(cell.cr, background.cr, foreground.cr)
                        if !cbFits || !crFits { wrongColorInside += 1 }
                    } else if cell.cb != background.cb || cell.cr != background.cr {
                        wrongColorInside += 1
                    }
                }
                // (a cell with pixels inside and outside is shared: half way between the two)
            }
        }
        XCTAssertEqual(colorChangedOutside, 0, "color changed outside the box", file: file, line: line)
        XCTAssertEqual(wrongColorInside, 0, "the box must have exactly the color of the background", file: file, line: line)
        XCTAssertGreaterThan(cellsInside, area.width * area.height / 8, file: file, line: line)
    }

    /// What a block may change when only `visible` of it can be seen: a side of `visible` that
    /// reaches the edge of the text is not hidden, and the margin of the box stays there
    private func shown(_ visible: PixelRect, text: PixelRect, margin: Int) -> PixelRect {
        PixelRect(minX: visible.minX <= text.minX ? min(visible.minX, text.minX - margin) : visible.minX,
                  minY: visible.minY <= text.minY ? min(visible.minY, text.minY - margin) : visible.minY,
                  maxX: visible.maxX >= text.maxX ? max(visible.maxX, text.maxX + margin) : visible.maxX,
                  maxY: visible.maxY >= text.maxY ? max(visible.maxY, text.maxY + margin) : visible.maxY)
    }

    private func contains(_ rect: PixelRect, _ x: Int, _ y: Int) -> Bool {
        x >= rect.minX && x < rect.maxX && y >= rect.minY && y < rect.maxY
    }

    /// in one of the corner squares of a box, where its rounding (a radius of at most 8 pixels) shows
    private func isCorner(of box: PixelRect, _ x: Int, _ y: Int) -> Bool {
        (x < box.minX + 9 || x >= box.maxX - 9) && (y < box.minY + 9 || y >= box.maxY - 9)
    }

    private func isBetween(_ value: UInt8, _ a: UInt8, _ b: UInt8) -> Bool {
        value >= min(a, b) && value <= max(a, b)
    }

    /// the same, give or take one step
    private func isAbout(_ value: UInt8, _ expected: UInt8) -> Bool {
        let difference = Int(value) - Int(expected)
        return difference >= -1 && difference <= 1
    }

    /// Where the text of a block is: one flag for every pixel of the block, row by row from the top
    private struct Ink {
        let width: Int
        let height: Int
        let cells: [Bool]

        func count(_ area: PixelRect) -> Int {
            var count = 0
            for y in max(0, area.minY)..<min(height, area.maxY) {
                for x in max(0, area.minX)..<min(width, area.maxX) where cells[y * width + x] { count += 1 }
            }
            return count
        }

        /// the smallest rectangle around the text in these rows; nil if there is none
        func bounds(rows: Range<Int>) -> PixelRect? {
            var bounds: PixelRect?
            for y in rows {
                for x in 0..<width where cells[y * width + x] {
                    if let current = bounds {
                        bounds = PixelRect(minX: min(current.minX, x), minY: min(current.minY, y),
                                           maxX: max(current.maxX, x + 1), maxY: max(current.maxY, y + 1))
                    } else {
                        bounds = PixelRect(minX: x, minY: y, maxX: x + 1, maxY: y + 1)
                    }
                }
            }
            return bounds
        }

        var bounds: PixelRect? { bounds(rows: 0..<height) }
    }
}
