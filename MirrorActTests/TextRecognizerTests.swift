// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import XCTest
@testable import MirrorAct

/// Vision on frames like those of a phone: what `TextRecognizer` reads, and where it says it
/// lies. Other versions of macOS read a little differently, so words are compared loosely and
/// positions within 2 % of the frame.
final class TextRecognizerTests: XCTestCase {
    private let width = 1170, height = 800
    private let lines = [
        TestFrames.Line(text: "Settings", x: 60, top: 80),
        TestFrames.Line(text: "General information about this device", x: 60, top: 320),
        TestFrames.Line(text: "Privacy and Security", x: 60, top: 560),
    ]
    private let formats: [(name: String, format: OSType)] = [
        ("BGRA", kCVPixelFormatType_32BGRA),
        ("4:2:0", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    ]

    func testLinesOfTheWholeFrameInReadingOrderAndInPlace() throws {
        let size = CGSize(width: width, height: height)
        for (name, format) in formats {
            let (frame, inked) = try TestFrames.text(lines, width: width, height: height, format: format)
            let found = try TextRecognizer.lines(in: frame)
            XCTAssertEqual(found.count, lines.count, "\(name): \(found.map(\.text))")
            let ordered = TextLayout.readingOrder(found).flatMap { $0 }
            for (index, line) in ordered.prefix(lines.count).enumerated() {
                XCTAssertTrue(Self.reads(line.text, as: lines[index].text), "\(name): \(line.text)")
                checkPlace(of: line, drawnAt: inked[index], name)
            }
            XCTAssertTrue(Self.reads(TextLayout.plainText(found, imageSize: size), as: lines.map(\.text).joined(separator: "\n")),
                          "\(name): \(TextLayout.plainText(found, imageSize: size))")
        }
    }

    /// A region (the tracker reads parts of the screen again) yields its lines in coordinates
    /// of the whole frame, not of the region
    func testRegionGivesItsLinesInCoordinatesOfTheWholeFrame() throws {
        for (name, format) in formats {
            let (frame, inked) = try TestFrames.text(lines, width: width, height: height, format: format)
            let region = inked[1].insetBy(dx: -40, dy: -40)
            let found = try TextRecognizer.lines(in: frame, region: region)
            XCTAssertEqual(found.count, 1, "\(name): \(found.map(\.text))")
            let line = try XCTUnwrap(found.first)
            XCTAssertTrue(Self.reads(line.text, as: lines[1].text), "\(name): \(line.text)")
            checkPlace(of: line, drawnAt: inked[1], name)
        }
    }

    /// Small text, as on a phone screen, in a narrow region of a tall frame. The recognizer's
    /// minimum text height is a fraction of the picture; whether Vision measures it against the
    /// region or the whole frame, text this small must still be read.
    func testSmallTextInANarrowRegionOfATallFrameIsRead() throws {
        let line = TestFrames.Line(text: "Privacy and Security", x: 100, top: 1250, fontSize: 24)
        for (name, format) in formats {
            let (frame, inked) = try TestFrames.text([line], width: 1170, height: 2532, format: format)
            // under 1 % of the frame's height
            XCTAssertLessThan(inked[0].height / 2532, 0.01)
            let found = try TextRecognizer.lines(in: frame, region: inked[0].insetBy(dx: -30, dy: -40))
            XCTAssertEqual(found.count, 1, "\(name): \(found.map(\.text))")
            XCTAssertTrue(Self.reads(found.first?.text ?? "", as: line.text), "\(name): \(found.map(\.text))")
        }
    }

    func testRegionOutsideTheFrameFindsNothing() throws {
        let (frame, _) = try TestFrames.text(lines, width: width, height: height, format: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(try TextRecognizer.lines(in: frame, region: CGRect(x: 2000, y: 0, width: 100, height: 100)), [])
    }

    func testRecognizingInTheBackgroundGivesTheSameLines() async throws {
        let (frame, _) = try TestFrames.text(lines, width: width, height: height,
                                             format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let recognized = await TextRecognizer.recognize(frame)
        let found = try XCTUnwrap(recognized)
        XCTAssertEqual(found.count, lines.count)
    }

    /// The colors a translation is drawn in come from the frame: dark text on a light background
    func testColorsOfALineAreThoseOfItsTextAndBackground() throws {
        for (name, format) in formats {
            let (frame, inked) = try TestFrames.text(lines, width: width, height: height, format: format)
            let colors = BlockColors.estimate(pixels: FramePixels.colors(in: inked[1].insetBy(dx: -8, dy: -8), of: frame))
            XCTAssertGreaterThan(colors.background.luma, 230, "\(name): \(colors)")
            XCTAssertLessThan(colors.foreground.luma, 60, "\(name): \(colors)")
        }
    }

    /// A row as Android and iOS draw it: a dark title over a smaller grey summary, then a
    /// paragraph of two dark lines. The recognizer measures how bright each line's letters and
    /// background are; the title and the summary differ, the lines of the paragraph do not, and
    /// the copied text has the title and the summary on lines of their own. (In video range the
    /// frame holds 16 to 235 for 0 to 255.)
    func testTheBrightnessOfTheLettersOfEachLineIsMeasured() throws {
        let rows = [
            TestFrames.Line(text: "Network and Internet", x: 60, top: 60, fontSize: 44),
            TestFrames.Line(text: "Mobile data and hotspot", x: 60, top: 118, fontSize: 32, gray: 110),
            TestFrames.Line(text: "The weather stays dry for most of the", x: 60, top: 300, fontSize: 36),
            TestFrames.Line(text: "week, with light winds from the west.", x: 60, top: 346, fontSize: 36),
        ]
        let size = CGSize(width: width, height: height)
        for (name, format) in formats {
            let (frame, _) = try TestFrames.text(rows, width: width, height: height, format: format)
            let found = TextLayout.readingOrder(try TextRecognizer.lines(in: frame)).flatMap { $0 }
            XCTAssertEqual(found.count, 4, "\(name): \(found.map(\.text))")
            let tones = try found.map { try XCTUnwrap($0.tone, "\(name): \($0.text)") }
            let backgrounds = tones.map(\.background)
            XCTAssertLessThanOrEqual(try XCTUnwrap(backgrounds.max()) - XCTUnwrap(backgrounds.min()), 4, "\(name)")
            XCTAssertGreaterThan(tones[0].background - tones[0].text, 160, "\(name): \(tones)")
            XCTAssertGreaterThan(tones[1].text - tones[0].text, 60, "\(name): \(tones)")
            XCTAssertLessThanOrEqual(abs(tones[2].text - tones[3].text), TextLayout.sameTone / 2, "\(name): \(tones)")
            XCTAssertEqual(TextLayout.plainText(found, imageSize: size).components(separatedBy: "\n").count, 3,
                           "\(name): \(TextLayout.plainText(found, imageSize: size))")
        }
    }

    /// No brightness is given for a line on a picture: its box has no background of one brightness
    func testTheBrightnessOfLettersOnAPictureIsNotMeasured() {
        var values = [UInt8](repeating: 0, count: 400 * 40)
        for index in values.indices { values[index] = UInt8((index * 37 + index / 400 * 11) % 256) }
        XCTAssertNil(LineTone.measure(LumaRaster(x: 0, y: 0, width: 400, height: 40, values: values)))
        // the same box on a plain background, with strokes of 60 in it
        var plain = [UInt8](repeating: 240, count: 400 * 40)
        for y in 10..<30 {
            for x in stride(from: 20, to: 380, by: 6) {
                plain[y * 400 + x] = 60
                plain[y * 400 + x + 1] = 60
            }
        }
        let tone = LineTone.measure(LumaRaster(x: 0, y: 0, width: 400, height: 40, values: plain))
        XCTAssertEqual(tone, RecognizedLine.Tone(text: 60, background: 242))
    }

    /// How much of the letters of each line is coloured (`RecognizedLine.Tone.colour`): none of
    /// a dark title or a dark paragraph, also on a tinted card; nearly all of a green status
    /// line and of a link; about the share of the mentions in a line that is half mentions. A
    /// post of dark lines and lines in the blue of links stays one paragraph, as does the text on
    /// the card.
    func testHowMuchOfTheLettersOfEachLineIsColouredIsMeasured() throws {
        let dark: (UInt8, UInt8, UInt8) = (20, 20, 20), blue: (UInt8, UInt8, UInt8) = (0, 122, 255)
        let green: (UInt8, UInt8, UInt8) = (30, 142, 62)
        let lines: [(runs: [TestFrames.Run], x: CGFloat, top: CGFloat, fontSize: CGFloat)] = [
            ([TestFrames.Run(text: "Network and Internet", color: dark)], 60, 30, 44),
            ([TestFrames.Run(text: "Connected", color: green)], 60, 86, 32),
            ([TestFrames.Run(text: "Thanks ", color: dark), TestFrames.Run(text: "@anna_mueller @peter", color: blue)], 60, 200, 36),
            ([TestFrames.Run(text: "for the great photos from", color: dark)], 60, 246, 36),
            ([TestFrames.Run(text: "www.example.com/photos", color: blue)], 60, 292, 36),
            ([TestFrames.Run(text: "of the weekend at the lake.", color: dark)], 60, 338, 36),
            ([TestFrames.Run(text: "Your parcel arrives today", color: dark)], 80, 520, 36),
            ([TestFrames.Run(text: "between two and four.", color: dark)], 80, 566, 36),
        ]
        let card = (rect: CGRect(x: 40, y: 490, width: 900, height: 140), color: (UInt8(255), UInt8(244), UInt8(204)))
        let size = CGSize(width: width, height: height)
        for (name, format) in formats {
            let frame = try TestFrames.colored(lines, background: (245, 245, 245), cards: [card],
                                               width: width, height: height, format: format)
            let found = TextLayout.readingOrder(try TextRecognizer.lines(in: frame)).flatMap { $0 }
            func colour(_ word: String) throws -> Double {
                let line = try XCTUnwrap(found.first { $0.text.contains(word) }, "\(name): \(word) in \(found.map(\.text))")
                return try XCTUnwrap(line.tone, "\(name): \(line.text)").colour
            }
            for word in ["Network", "great", "weekend", "parcel", "between"] {
                XCTAssertLessThan(try colour(word), 0.05, "\(name): \(word)")
            }
            XCTAssertGreaterThan(try colour("Connected"), 0.8, "\(name)")
            XCTAssertGreaterThan(try colour("example"), 0.8, "\(name)")
            let mentions = try colour("Thanks")
            XCTAssertTrue((0.4...0.9).contains(mentions), "\(name): \(mentions)")
            let blocks = TextLayout.blocks(found, imageSize: size).map(\.text)
            XCTAssertTrue(blocks.contains { $0.contains("Thanks") && $0.contains("example") && $0.contains("lake") },
                          "\(name): \(blocks)")
            XCTAssertTrue(blocks.contains { $0.contains("parcel") && $0.contains("between") }, "\(name): \(blocks)")
        }
    }

    /// The colour of letters is measured against grey and the colour of the background: dark
    /// strokes whose smoothed edges take the colour of a tinted card are not coloured, blue
    /// strokes on it are
    func testTheColourOfLettersIsMeasuredAgainstGreyAndTheBackground() throws {
        let width = 400, height = 40
        var luma = [UInt8](repeating: 240, count: width * height)
        // a yellowish card: Cb -20, Cr 8
        var blue = [Int8](repeating: -20, count: width * height), red = [Int8](repeating: 8, count: width * height)
        for y in 10..<30 {
            for x in stride(from: 20, to: 380, by: 6) {
                // the core of a stroke is grey, its edge half grey and half the card
                luma[y * width + x] = 40
                (blue[y * width + x], red[y * width + x]) = (0, 0)
                luma[y * width + x + 1] = 140
                (blue[y * width + x + 1], red[y * width + x + 1]) = (-10, 4)
            }
        }
        let raster = LumaRaster(x: 0, y: 0, width: width, height: height, values: luma)
        func colours(_ indices: [Int]) -> ChromaSamples {
            ChromaSamples(blue: indices.map { blue[$0] }, red: indices.map { red[$0] })
        }
        let grey = try XCTUnwrap(LineTone.measure(raster, colours: colours))
        XCTAssertEqual(grey.colour, 0)
        // the same strokes in blue
        for index in luma.indices where luma[index] < 200 { (blue[index], red[index]) = (60, -50) }
        let coloured = try XCTUnwrap(LineTone.measure(raster, colours: colours))
        XCTAssertEqual(coloured.colour, 1)
        XCTAssertEqual(coloured.text, grey.text)
    }

    // MARK: Helpers

    private func checkPlace(of line: RecognizedLine, drawnAt ink: CGRect, _ name: String,
                            file: StaticString = #filePath, lineNumber: UInt = #line) {
        let drawn = CGRect(x: ink.minX / CGFloat(width), y: ink.minY / CGFloat(height),
                           width: ink.width / CGFloat(width), height: ink.height / CGFloat(height))
        let tolerance: CGFloat = 0.02
        XCTAssertEqual(line.rect.minX, drawn.minX, accuracy: tolerance, "\(name): \(line.text) left", file: file, line: lineNumber)
        XCTAssertEqual(line.rect.midY, drawn.midY, accuracy: tolerance, "\(name): \(line.text) height", file: file, line: lineNumber)
        XCTAssertEqual(line.rect.maxX, drawn.maxX, accuracy: tolerance * 2, "\(name): \(line.text) right", file: file, line: lineNumber)
        XCTAssertEqual(line.rect.height, drawn.height, accuracy: tolerance * 2, "\(name): \(line.text) size", file: file, line: lineNumber)
    }

    /// Whether Vision read `text` as `expected`, give or take a letter in eight and differences
    /// in case, spacing and punctuation. Line breaks must match.
    static func reads(_ text: String, as expected: String) -> Bool {
        let readLines = text.split(separator: "\n"), expectedLines = expected.split(separator: "\n")
        guard readLines.count == expectedLines.count else { return false }
        return zip(readLines, expectedLines).allSatisfy { read, wanted in
            let a = Array(read.lowercased().filter(\.isLetter)), b = Array(wanted.lowercased().filter(\.isLetter))
            return distance(a, b) <= max(1, b.count / 8)
        }
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
