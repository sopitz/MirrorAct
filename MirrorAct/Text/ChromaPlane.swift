// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// The color of 4:2:0 video. Such a frame stores the brightness of every pixel, but its color
// only once for every 2 × 2 pixels: a "cell" holds the two bytes Cb and Cr and belongs to the
// columns 2 c and 2 c + 1 of the rows 2 r and 2 r + 1 of the frame. A cell is taken here as
// the mean of its four pixels. What is drawn into the brightness has to be drawn into the
// cells as well, or a box would keep the color of what it covers.

/// The text mask of a block (`BlockTextMask`) at the resolution of the color: one value per
/// cell, the mean of the mask over the four pixels of the cell.
///
/// Which pixels share a cell depends on where the block is in the frame, because the cells
/// start at even columns and rows of the frame, not of the block. A block at an odd column
/// needs another reduction than one at an even column (`oddX`), the same for rows (`oddY`):
/// with the wrong one the color of the text would sit one pixel beside its brightness.
struct ChromaMask: Equatable {
    /// Cells of one row that have text: the cells `start ..< end` of `row`
    struct Run: Equatable {
        var row: Int
        var start: Int
        var end: Int
    }

    /// the position the mask was reduced for: the block starts at an odd column / row of the frame
    let oddX: Bool
    let oddY: Bool
    /// in cells; the first cell is the one that holds the top left pixel of the block
    let width: Int
    let height: Int
    /// 0 (no text in the cell) … 255 (all four pixels are text), row by row from the top
    let pixels: [UInt8]
    /// where there is text at all, from the top; blending walks along these instead of
    /// looking at every cell of every frame
    let runs: [Run]

    /// `mask`: `width` × `height` values, row by row from the top (`BlockTextMask.pixels`)
    init(mask: [UInt8], width maskWidth: Int, height maskHeight: Int, oddX: Bool, oddY: Bool) {
        precondition(maskWidth >= 0 && maskHeight >= 0 && mask.count == maskWidth * maskHeight,
                     "ChromaMask: size and pixel count differ")
        // A block at an odd column starts in the right half of a cell: its first cell has only
        // the first column of the mask, the following ones the columns 1 and 2, 3 and 4 …
        let shiftX = oddX ? 1 : 0, shiftY = oddY ? 1 : 0
        let width = maskWidth == 0 ? 0 : (maskWidth + shiftX + 1) / 2
        let height = maskHeight == 0 ? 0 : (maskHeight + shiftY + 1) / 2
        var pixels = [UInt8](repeating: 0, count: width * height)
        var runs: [Run] = []
        for row in 0..<height {
            // the rows and columns of the mask in a cell; those outside the mask count as empty
            let upper = 2 * row - shiftY, lower = upper + 1
            var runStart = -1
            for column in 0..<width {
                let left = 2 * column - shiftX, right = left + 1
                var sum = 0
                if upper >= 0 {
                    if left >= 0 { sum += Int(mask[upper * maskWidth + left]) }
                    if right < maskWidth { sum += Int(mask[upper * maskWidth + right]) }
                }
                if lower < maskHeight {
                    if left >= 0 { sum += Int(mask[lower * maskWidth + left]) }
                    if right < maskWidth { sum += Int(mask[lower * maskWidth + right]) }
                }
                let value = (sum + 2) / 4
                pixels[row * width + column] = UInt8(value)
                if value > 0, runStart < 0 {
                    runStart = column
                } else if value == 0, runStart >= 0 {
                    runs.append(Run(row: row, start: runStart, end: column))
                    runStart = -1
                }
            }
            if runStart >= 0 { runs.append(Run(row: row, start: runStart, end: width)) }
        }
        self.oddX = oddX
        self.oddY = oddY
        self.width = width
        self.height = height
        self.pixels = pixels
        self.runs = runs
    }
}

/// The color plane of a bi-planar 4:2:0 frame (`CVPixelBufferGetBaseAddressOfPlane(_, 1)`)
/// while its buffer is locked. Rectangles and positions are given in pixels of the frame;
/// what lies outside the plane is left out.
struct ChromaPlane {
    let base: UnsafeMutableRawPointer
    let bytesPerRow: Int
    /// in cells
    let width: Int
    let height: Int

    /// Gives the pixels of `area` one color. A cell that lies in the area with only one or two
    /// of its four pixels (the area starts or ends at an odd column or row) gets that share of
    /// the color and keeps the rest of what it had: its other pixels show something else.
    func fill(_ area: PixelRect, cb: UInt8, cr: UInt8) {
        let minX = max(area.minX, 0), maxX = min(area.maxX, 2 * width)
        let minY = max(area.minY, 0), maxY = min(area.maxY, 2 * height)
        guard minX < maxX, minY < maxY else { return }
        // the cells that lie in the area with both of their columns
        let firstFull = (minX + 1) >> 1, endFull = maxX >> 1
        var pattern = (cb, cr, cb, cr)
        var row = minY >> 1
        let endRow = (maxY + 1) >> 1
        while row < endRow {
            let cells = (base + row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            // rows of the frame that this row of cells has in the area: one or two
            let rows = min(maxY, 2 * row + 2) - max(minY, 2 * row)
            if rows == 2 {
                // The bulk of a box, and what has to stay fast in a debug build: a memory fill
                // with the pair of bytes instead of a loop over the cells
                if firstFull < endFull {
                    memset_pattern4(cells + 2 * firstFull, &pattern, 2 * (endFull - firstFull))
                }
                if minX & 1 == 1 { Self.mix(cells + (minX >> 1) * 2, cb, cr, quarters: 2) }
                if maxX & 1 == 1 { Self.mix(cells + (maxX >> 1) * 2, cb, cr, quarters: 2) }
            } else {
                var cell = minX >> 1
                let endCell = (maxX + 1) >> 1
                while cell < endCell {
                    let columns = min(maxX, 2 * cell + 2) - max(minX, 2 * cell)
                    Self.mix(cells + cell * 2, cb, cr, quarters: columns)
                    cell += 1
                }
            }
            row += 1
        }
    }

    /// Blends a color in where `mask` has text. `x`, `y`: the top left pixel of the block the
    /// mask belongs to; it has to be an odd or even position as the mask was reduced for.
    /// Only cells that have a pixel in `area` change.
    func blend(_ mask: ChromaMask, x: Int, y: Int, within area: PixelRect, cb: UInt8, cr: UInt8) {
        assert(mask.oddX == (x & 1 == 1) && mask.oddY == (y & 1 == 1), "ChromaPlane: the mask was reduced for another position")
        // the cell of the top left pixel (>> rounds down, also for a block that begins left of or above the frame)
        let originX = x >> 1, originY = y >> 1
        let firstCell = max(area.minX >> 1, 0), endCell = min((area.maxX + 1) >> 1, width)
        let firstRow = max(area.minY >> 1, 0), endRow = min((area.maxY + 1) >> 1, height)
        guard firstCell < endCell, firstRow < endRow else { return }
        mask.pixels.withUnsafeBufferPointer { (shares: UnsafeBufferPointer<UInt8>) -> Void in
            for run in mask.runs {
                let row = originY + run.row
                if row < firstRow { continue }
                if row >= endRow { break }
                var cell = max(originX + run.start, firstCell)
                let end = min(originX + run.end, endCell)
                if cell >= end { continue }
                let cells = (base + row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                // the mask value of a cell of the plane is at `maskIndex + cell`
                let maskIndex = run.row * mask.width - originX
                while cell < end {
                    Self.mix(cells + cell * 2, cb, cr, share: Int(shares[maskIndex + cell]))
                    cell += 1
                }
            }
        }
    }

    /// `share` of 255 of a cell gets the color
    private static func mix(_ cell: UnsafeMutablePointer<UInt8>, _ cb: UInt8, _ cr: UInt8, share: Int) {
        let rest = 255 - share
        let newCb = (Int(cell[0]) * rest + Int(cb) * share + 127) / 255
        let newCr = (Int(cell[1]) * rest + Int(cr) * share + 127) / 255
        cell[0] = UInt8(newCb)
        cell[1] = UInt8(newCr)
    }

    /// `quarters` of the four pixels of a cell get the color
    private static func mix(_ cell: UnsafeMutablePointer<UInt8>, _ cb: UInt8, _ cr: UInt8, quarters: Int) {
        let rest = 4 - quarters
        let newCb = (Int(cell[0]) * rest + Int(cb) * quarters + 2) / 4
        let newCr = (Int(cell[1]) * rest + Int(cr) * quarters + 2) / 4
        cell[0] = UInt8(newCb)
        cell[1] = UInt8(newCr)
    }
}
