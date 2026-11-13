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
