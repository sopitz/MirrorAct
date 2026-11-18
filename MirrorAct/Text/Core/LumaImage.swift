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
    ///
    /// This runs for every frame on the thread that delivers it, also in builds without
    /// optimization, where every range, buffer subscript and call in the loop over the pixels
    /// costs (a phone frame took half a second there). So the loops are plain `while` loops over
    /// pointers, and a band of `scale` rows is first added up per column, eight pixels at a time
    /// (four for BGRA) in the 16-bit lanes of a `UInt64`.
    static func downsampled(from base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
                            format: PixelFormat, scale: Int) -> LumaImage {
        precondition(scale >= 1, "LumaImage: scale must be at least 1")
        let outWidth = max(0, width) / scale, outHeight = max(0, height) / scale
        guard outWidth > 0, outHeight > 0 else { return LumaImage(width: outWidth, height: outHeight) }
        let bgra = format == .bgra8
        // a column of a band adds up to at most 255 per row (B + 2 G + R: 1020), which must fit
        // into a lane; the lanes are read back in column order on little-endian machines only
        let fitsLanes = scale <= (bgra ? 64 : 257) && UInt16(1).littleEndian == 1
        var pixels = [UInt8](repeating: 0, count: outWidth * outHeight)
        pixels.withUnsafeMutableBufferPointer { out in
            if fitsLanes {
                reduceByBands(base, bytesPerRow: bytesPerRow, bgra: bgra, scale: scale, outWidth: outWidth,
                              outHeight: outHeight, into: out.baseAddress!)
            } else {
                reduceByCells(base, bytesPerRow: bytesPerRow, bgra: bgra, scale: scale, outWidth: outWidth,
                              outHeight: outHeight, into: out.baseAddress!)
            }
        }
        return LumaImage(width: outWidth, height: outHeight, pixels: pixels)
    }

    /// `downsampled` with the sums of the columns of a band of rows in 16-bit lanes
    private static func reduceByBands(_ base: UnsafeRawPointer, bytesPerRow: Int, bgra: Bool, scale: Int,
                                      outWidth: Int, outHeight: Int, into out: UnsafeMutablePointer<UInt8>) {
        let used = outWidth * scale
        let divisor = (bgra ? 4 : 1) * scale * scale, half = divisor / 2
        // four columns per word, lane 0 (the lowest bits) the first of them
        let words = (used + 3) / 4
        var bandSums = [UInt64](repeating: 0, count: words)
        var target = out
        bandSums.withUnsafeMutableBufferPointer { buffer in
            let sums = buffer.baseAddress!
            var outY = 0
            while outY < outHeight {
                var word = 0
                while word < words {
                    sums[word] = 0
                    word &+= 1
                }
                var cellY = 0
                while cellY < scale {
                    let row = base + (outY &* scale &+ cellY) &* bytesPerRow
                    let bytes = row.assumingMemoryBound(to: UInt8.self)
                    var sum = sums
                    if bgra {
                        // four pixels from two loads; per half of a load the lanes are B + 2 G, R,
                        // then B + 2 G + R in the low 32 bits of each half, then both in 16 bits
                        let whole = used & ~3
                        var pixel = 0
                        while pixel < whole {
                            let first = row.loadUnaligned(fromByteOffset: pixel &<< 2, as: UInt64.self)
                            let second = row.loadUnaligned(fromByteOffset: pixel &<< 2 &+ 8, as: UInt64.self)
                            var low = (first & 0x00FF_00FF_00FF_00FF) &+ (first &>> 7 & 0x0000_01FE_0000_01FE)
                            var high = (second & 0x00FF_00FF_00FF_00FF) &+ (second &>> 7 & 0x0000_01FE_0000_01FE)
                            low = (low &+ low &>> 16) & 0x0000_FFFF_0000_FFFF
                            high = (high &+ high &>> 16) & 0x0000_FFFF_0000_FFFF
                            low = (low | low &>> 16) & 0xFFFF_FFFF
                            high = (high | high &>> 16) & 0xFFFF_FFFF
                            sum.pointee &+= low | high &<< 32
                            sum += 1
                            pixel &+= 4
                        }
                        while pixel < used {
                            let value = bytes + pixel &<< 2
                            let luma = UInt64(value[0]) &+ 2 &* UInt64(value[1]) &+ UInt64(value[2])
                            sums[pixel &>> 2] &+= luma &<< UInt64((pixel & 3) &* 16)
                            pixel &+= 1
                        }
                    } else {
                        // eight pixels per load: the first four spread into the lanes of one word,
                        // the other four into the next
                        let whole = used & ~7
                        var pixel = 0
                        while pixel < whole {
                            let eight = row.loadUnaligned(fromByteOffset: pixel, as: UInt64.self)
                            var low = eight & 0xFFFF_FFFF, high = eight &>> 32
                            low = (low | low &<< 16) & 0x0000_FFFF_0000_FFFF
                            high = (high | high &<< 16) & 0x0000_FFFF_0000_FFFF
                            sum[0] &+= (low | low &<< 8) & 0x00FF_00FF_00FF_00FF
                            sum[1] &+= (high | high &<< 8) & 0x00FF_00FF_00FF_00FF
                            sum += 2
                            pixel &+= 8
                        }
                        while pixel < used {
                            sums[pixel &>> 2] &+= UInt64(bytes[pixel]) &<< UInt64((pixel & 3) &* 16)
                            pixel &+= 1
                        }
                    }
                    cellY &+= 1
                }
                // the cells of the band from the sums of their columns (the usual scales without
                // an inner loop)
                sums.withMemoryRebound(to: UInt16.self, capacity: words &* 4) { columns in
                    var column = columns, outX = 0
                    switch scale {
                    case 1:
                        while outX < outWidth {
                            target.pointee = UInt8(truncatingIfNeeded: (Int(column[0]) &+ half) / divisor)
                            target += 1
                            column += 1
                            outX &+= 1
                        }
                    case 2:
                        while outX < outWidth {
                            let sum = Int(column[0]) &+ Int(column[1])
                            target.pointee = UInt8(truncatingIfNeeded: (sum &+ half) / divisor)
                            target += 1
                            column += 2
                            outX &+= 1
                        }
                    case 3:
                        while outX < outWidth {
                            let sum = Int(column[0]) &+ Int(column[1]) &+ Int(column[2])
                            target.pointee = UInt8(truncatingIfNeeded: (sum &+ half) / divisor)
                            target += 1
                            column += 3
                            outX &+= 1
                        }
                    case 4:
                        while outX < outWidth {
                            let sum = Int(column[0]) &+ Int(column[1]) &+ Int(column[2]) &+ Int(column[3])
                            target.pointee = UInt8(truncatingIfNeeded: (sum &+ half) / divisor)
                            target += 1
                            column += 4
                            outX &+= 1
                        }
                    default:
                        // four columns at a time, then the rest of the cell
                        let fours = scale & ~3
                        while outX < outWidth {
                            var sum = 0, step = 0
                            while step < fours {
                                sum &+= Int(column[step]) &+ Int(column[step &+ 1]) &+ Int(column[step &+ 2])
                                    &+ Int(column[step &+ 3])
                                step &+= 4
                            }
                            while step < scale {
                                sum &+= Int(column[step])
                                step &+= 1
                            }
                            target.pointee = UInt8(truncatingIfNeeded: (sum &+ half) / divisor)
                            target += 1
                            column += scale
                            outX &+= 1
                        }
                    }
                }
                outY &+= 1
            }
        }
    }

    /// `downsampled` cell by cell, for scales whose sums do not fit into the lanes
    private static func reduceByCells(_ base: UnsafeRawPointer, bytesPerRow: Int, bgra: Bool, scale: Int,
                                      outWidth: Int, outHeight: Int, into out: UnsafeMutablePointer<UInt8>) {
        let divisor = (bgra ? 4 : 1) * scale * scale, half = divisor / 2
        // bytes from one cell of a row to the next
        let cellBytes = (bgra ? 4 : 1) * scale
        var target = out
        var cellSums = [Int](repeating: 0, count: outWidth)
        cellSums.withUnsafeMutableBufferPointer { buffer in
            let sums = buffer.baseAddress!
            var outY = 0
            while outY < outHeight {
                var outX = 0
                while outX < outWidth {
                    sums[outX] = 0
                    outX &+= 1
                }
                var cellY = 0
                while cellY < scale {
                    var cell = (base + (outY &* scale &+ cellY) &* bytesPerRow).assumingMemoryBound(to: UInt8.self)
                    outX = 0
                    while outX < outWidth {
                        var sum = 0, pixel = cell, step = 0
                        while step < scale {
                            sum &+= bgra ? Int(pixel[0]) &+ 2 &* Int(pixel[1]) &+ Int(pixel[2]) : Int(pixel[0])
                            pixel += bgra ? 4 : 1
                            step &+= 1
                        }
                        sums[outX] &+= sum
                        cell += cellBytes
                        outX &+= 1
                    }
                    cellY &+= 1
                }
                outX = 0
                while outX < outWidth {
                    target.pointee = UInt8(truncatingIfNeeded: (sums[outX] &+ half) / divisor)
                    target += 1
                    outX &+= 1
                }
                outY &+= 1
            }
        }
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
