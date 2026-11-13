// SPDX-License-Identifier: GPL-3.0-or-later
import CoreVideo
import XCTest
@testable import MirrorAct

/// What `ScreenTranslator` hands the tracker of Vision's lines of a phone screen (1080 × 2400)
final class ScreenTranslatorCutOffTests: XCTestCase {
    private let phone = CGSize(width: 1080, height: 2400)

    private func line(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat,
                      confidence: Double? = nil) -> RecognizedLine {
        RecognizedLine(text: text, rect: CGRect(x: x / phone.width, y: y / phone.height,
                                                width: width / phone.width, height: height / phone.height),
                       confidence: confidence)
    }

    /// The status bar (the clock, icons read as letters) is left out, as it is of what Text copies
    func testTheStatusBarIsLeftOut() throws {
        let lines = [
            line("7:22 kg", 40, 16, 150, 34, confidence: 0.5),
            line("VAD", 894, 16, 114, 34, confidence: 0.3),
            line("< Testlabor", 41, 103, 377, 66, confidence: 1),
        ]
        let frame = try TestFrames.blank(width: 1080, height: 2400, format: kCVPixelFormatType_32BGRA)
        XCTAssertEqual(ScreenTranslator.recognizedBlocks(from: lines, in: frame, areas: []).map(\.text), ["< Testlabor"])
    }
}
