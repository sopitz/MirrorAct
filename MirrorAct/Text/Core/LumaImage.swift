// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Small grayscale copy of a frame (row by row, top row first). Following the text on the
/// screen from frame to frame works on these instead of the full frames.
struct LumaImage: Equatable {
    /// Layout of the pixels a thumbnail is made from
    enum PixelFormat {
        /// one byte per pixel, e.g. the Y plane of a 4:2:0 frame
        case luma8
        /// four bytes per pixel, blue first (BGRA)
        case bgra8
    }

    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height,
                     "LumaImage: size and pixel count differ")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height,
                  pixels: [UInt8](repeating: fill, count: max(0, width) * max(0, height)))
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Factor by which a frame is reduced: the short side of the thumbnail ends up between
    /// 200 and 400 pixels (frames that small are not reduced).
    static func scale(forFrameWidth width: Int, height: Int) -> Int {
        max(1, (min(width, height) + 399) / 400)
    }

    /// Reduces a plane of pixels by `scale` in both directions: every pixel of the result is the
    /// mean of a `scale` × `scale` cell, rounded to the nearest value (for BGRA the mean of
    /// (B + 2 G + R) / 4). Columns and rows that do not fill a whole cell are left out.
    static func downsampled(from base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                            format: PixelFormat, scale: Int) -> LumaImage {
        precondition(scale >= 1, "LumaImage: scale must be at least 1")
        let outWidth = max(0, width) / scale, outHeight = max(0, height) / scale
        var result = LumaImage(width: outWidth, height: outHeight)
        guard outWidth > 0, outHeight > 0 else { return result }
        let divisor = (format == .luma8 ? 1 : 4) * scale * scale
        var sums = [Int](repeating: 0, count: outWidth)
        result.pixels.withUnsafeMutableBufferPointer { out in
            sums.withUnsafeMutableBufferPointer { sums in
                for outY in 0..<outHeight {
                    for outX in 0..<outWidth { sums[outX] = 0 }
                    for cellY in 0..<scale {
                        let row = (base + (outY * scale + cellY) * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                        var index = 0
                        switch format {
                        case .luma8:
                            for outX in 0..<outWidth {
                                var sum = 0
                                for _ in 0..<scale {
                                    sum += Int(row[index])
                                    index += 1
                                }
                                sums[outX] += sum
                            }
                        case .bgra8:
                            for outX in 0..<outWidth {
                                var sum = 0
                                for _ in 0..<scale {
                                    sum += Int(row[index]) + 2 * Int(row[index + 1]) + Int(row[index + 2])
                                    index += 4
                                }
                                sums[outX] += sum
                            }
                        }
                    }
                    let offset = outY * outWidth
                    for outX in 0..<outWidth {
                        out[offset + outX] = UInt8((sums[outX] + divisor / 2) / divisor)
                    }
                }
            }
        }
        return result
    }

    /// The same for an image that is already grayscale
    func downsampled(by scale: Int) -> LumaImage {
        pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return LumaImage(width: 0, height: 0) }
            return LumaImage.downsampled(from: base, width: width, height: height, bytesPerRow: width,
                                         format: .luma8, scale: scale)
        }
    }
}
