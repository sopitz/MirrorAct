// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import XCTest
@testable import MirrorAct

/// Colors of text blocks on their way from the frame and back (Foundation only, like the core)
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

    /// A saturated color of BT.601 video lies outside of RGB with the BT.709 numbers: converted
    /// back from the clamped RGB it is another color. The colors of a block therefore keep the
    /// values of the frame and are written back as they are.
    func testBlockColorsKeepTheValuesOfTheFrame() {
        // the red of iOS (255, 59, 48) as BT.601 video codes it
        let red = YCbCrColor(y: 116, cb: 94, cr: 215)
        XCTAssertNotEqual(YCbCrColor(red.rgb(fullRange: false), fullRange: false), red)
        let white = YCbCrColor(y: 235, cb: 128, cr: 128)
        let samples = [YCbCrColor](repeating: red, count: 70) + [YCbCrColor](repeating: white, count: 30)
        let colors = BlockColors.estimate(samples: samples, fullRange: false)
        XCTAssertEqual(colors.backgroundInVideo, VideoColor(color: red, fullRange: false))
        XCTAssertEqual(colors.foregroundInVideo, VideoColor(color: white, fullRange: false))
        // chosen exactly as from the same pixels in RGB
        var chosen = colors
        chosen.backgroundInVideo = nil
        chosen.foregroundInVideo = nil
        XCTAssertEqual(chosen, BlockColors.estimate(pixels: samples.map { $0.rgb(fullRange: false) }))

        // the mean of the samples of the background, and no text color where the block shows none
        let blue = YCbCrColor(y: 102, cb: 204, cr: 65), bluer = YCbCrColor(y: 102, cb: 206, cr: 65)
        let plain = BlockColors.estimate(samples: [blue, bluer, bluer], fullRange: true)
        XCTAssertEqual(plain.backgroundInVideo, VideoColor(color: YCbCrColor(y: 102, cb: 205, cr: 65), fullRange: true))
        XCTAssertNil(plain.foregroundInVideo)

        // a color changed afterwards is no longer the frame's
        var link = colors
        link.foreground = RGBColor(red: 0, green: 102, blue: 204)
        XCTAssertNil(link.foregroundInVideo)
        XCTAssertEqual(link.backgroundInVideo, colors.backgroundInVideo)
        link.background = .white
        XCTAssertNil(link.backgroundInVideo)
        XCTAssertEqual(BlockColors.estimate(samples: [], fullRange: false), .blackOnWhite)
    }
}
