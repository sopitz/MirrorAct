// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A color as video frames store it (Y′CbCr, 8 bit, BT.709 numbers).
///
/// The colors of a text block are sampled from a frame as Y′CbCr, compared as RGB and written
/// back as Y′CbCr. Both directions use the same numbers, so a color that goes there and back
/// keeps its value to within one step, whatever the true color space of the video is: a box
/// drawn in the background color of a text does not stand out from that background.
struct YCbCrColor: Equatable {
    var y: UInt8
    var cb: UInt8
    var cr: UInt8

    init(y: UInt8, cb: UInt8, cr: UInt8) {
        self.y = y
        self.cb = cb
        self.cr = cr
    }

    /// `fullRange`: brightness uses 0…255 instead of the 16…235 of video
    init(_ color: RGBColor, fullRange: Bool) {
        let red = Double(color.red), green = Double(color.green), blue = Double(color.blue)
        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        let blueDifference = (blue - luma) / 1.8556
        let redDifference = (red - luma) / 1.5748
        if fullRange {
            y = Self.byte(luma)
            cb = Self.byte(128 + blueDifference)
            cr = Self.byte(128 + redDifference)
        } else {
            y = Self.byte(16 + luma * 219 / 255)
            cb = Self.byte(128 + blueDifference * 224 / 255)
            cr = Self.byte(128 + redDifference * 224 / 255)
        }
    }

    func rgb(fullRange: Bool) -> RGBColor {
        let luma: Double, blueDifference: Double, redDifference: Double
        if fullRange {
            luma = Double(y)
            blueDifference = Double(cb) - 128
            redDifference = Double(cr) - 128
        } else {
            luma = (Double(y) - 16) * 255 / 219
            blueDifference = (Double(cb) - 128) * 255 / 224
            redDifference = (Double(cr) - 128) * 255 / 224
        }
        let red = luma + 1.5748 * redDifference
        let blue = luma + 1.8556 * blueDifference
        let green = (luma - 0.2126 * red - 0.0722 * blue) / 0.7152
        return RGBColor(red: Self.byte(red), green: Self.byte(green), blue: Self.byte(blue))
    }

    private static func byte(_ value: Double) -> UInt8 {
        UInt8(min(255, max(0, value.rounded())))
    }
}
