// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Colors of text blocks on their way from the frame and back (Foundation only: also runs on Linux)
final class YCbCrColorTests: XCTestCase {
    func testWhiteBlackAndGrayOfVideo() {
        XCTAssertEqual(YCbCrColor(.white, fullRange: false), YCbCrColor(y: 235, cb: 128, cr: 128))
        XCTAssertEqual(YCbCrColor(.black, fullRange: false), YCbCrColor(y: 16, cb: 128, cr: 128))
        XCTAssertEqual(YCbCrColor(.white, fullRange: true), YCbCrColor(y: 255, cb: 128, cr: 128))
        XCTAssertEqual(YCbCrColor(y: 235, cb: 128, cr: 128).rgb(fullRange: false), .white)
        XCTAssertEqual(YCbCrColor(y: 126, cb: 128, cr: 128).rgb(fullRange: false), RGBColor(red: 128, green: 128, blue: 128))
    }

    func testSaturatedColors() {
        // BT.709: pure blue has little brightness and the largest blue difference
        let blue = YCbCrColor(RGBColor(red: 0, green: 0, blue: 255), fullRange: false)
        XCTAssertEqual(blue, YCbCrColor(y: 32, cb: 240, cr: 118))
        let red = YCbCrColor(RGBColor(red: 255, green: 0, blue: 0), fullRange: false)
        XCTAssertEqual(red, YCbCrColor(y: 63, cb: 102, cr: 240))
    }

    func testAColorOfTheFrameComesBackUnchanged() {
        // every color a frame can show: RGB → Y′CbCr → RGB → Y′CbCr ends where it began
        for fullRange in [false, true] {
            var worst = 0
            for red in stride(from: 0, through: 255, by: 15) {
                for green in stride(from: 0, through: 255, by: 15) {
                    for blue in stride(from: 0, through: 255, by: 15) {
                        let start = YCbCrColor(RGBColor(red: UInt8(red), green: UInt8(green), blue: UInt8(blue)), fullRange: fullRange)
                        let back = YCbCrColor(start.rgb(fullRange: fullRange), fullRange: fullRange)
                        worst = max(worst, abs(Int(start.y) - Int(back.y)), abs(Int(start.cb) - Int(back.cb)),
                                    abs(Int(start.cr) - Int(back.cr)))
                    }
                }
            }
            XCTAssertLessThanOrEqual(worst, 1, "fullRange \(fullRange)")
        }
    }
}
