// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The pixels of a block in the thumbnail it was read from: the reference the block is followed
/// by and checked against in every later frame. Its position is always measured against these
/// pixels, never added up from frame to frame, so that rounding does not pile up.
struct BlockPatch {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    /// per row and per column: the mean of the largest step from a pixel to a neighbour, i.e.
    /// how much the row (column) changes when it is misaligned by up to a pixel
    let rowTexture: [Double]
    let columnTexture: [Double]

    /// The part `rect` of `image` (clipped to it); nil when nothing of it lies inside
    init?(image: LumaImage, rect: ThumbnailRect) {
        let clipped = rect.intersection(ThumbnailRect(x: 0, y: 0, width: image.width, height: image.height))
        guard clipped == rect, !rect.isEmpty else { return nil }
        width = rect.width
        height = rect.height
        var copied = [UInt8](repeating: 0, count: rect.width * rect.height)
        for row in 0..<rect.height {
            let source = (rect.y + row) * image.width + rect.x
            for column in 0..<rect.width {
                copied[row * rect.width + column] = image.pixels[source + column]
            }
        }
        pixels = copied
        var rows = [Double](repeating: 0, count: height)
        var columns = [Double](repeating: 0, count: width)
        for row in 0..<height {
            for column in 0..<width {
                let value = Int(copied[row * width + column])
                var step = 0
                if column > 0 { step = max(step, abs(value - Int(copied[row * width + column - 1]))) }
                if column + 1 < width { step = max(step, abs(value - Int(copied[row * width + column + 1]))) }
                if row > 0 { step = max(step, abs(value - Int(copied[(row - 1) * width + column]))) }
                if row + 1 < height { step = max(step, abs(value - Int(copied[(row + 1) * width + column]))) }
                rows[row] += Double(step)
                columns[column] += Double(step)
            }
        }
        for row in 0..<height {
            rows[row] /= Double(width)
        }
        for column in 0..<width {
            columns[column] /= Double(height)
        }
        rowTexture = rows
        columnTexture = columns
    }
}

/// Finds a `BlockPatch` in a frame and tells which part of it can still be seen there. Keeps
/// buffers for the sampled pixels and the verdicts per row and column.
final class PatchMatcher {
    private let configuration: OverlayTracker.Configuration
    /// the frame under the patch, value × `BilinearShift.one`; -1 outside of the frame
    private var sampled: [Int] = []
    private var foreignRows: [Bool] = []
    private var rowSigned: [Double] = []
    private var foreignChunks: [Bool] = []

    /// three in four lines of a run from an edge must be foreign for it to count as covered
    private static let coveredParts = 3
    private static let coveredOf = 4
    /// a correlation over fewer pixels than this says nothing
    private static let fewestCorrelated = 8

    init(configuration: OverlayTracker.Configuration) {
        self.configuration = configuration
    }

    /// Samples `image` under `part` of the patch placed with its top left pixel at (x, y), which
    /// may lie between pixels, every `step`-th row and column. Returns how many samples lie inside.
    @discardableResult
    private func sample(_ patch: BlockPatch, in image: LumaImage, x: Double, y: Double, part: ThumbnailRect,
                        step: Int, columnStep: Int? = nil) -> Int {
        let count = patch.width * patch.height
        if sampled.count < count {
            sampled = [Int](repeating: -1, count: count)
        }
        // the patch pixel (i, j) shows the image at (x + i, y + j): a shift by (-x, -y)
        let shift = BilinearShift(dx: -x, dy: -y)
        let width = image.width, height = image.height, patchWidth = patch.width
        var inside = 0
        sampled.withUnsafeMutableBufferPointer { target in
            image.pixels.withUnsafeBufferPointer { pixels in
                for row in stride(from: part.y, to: part.maxY, by: step) {
                    let sourceY = row - shift.whole.y
                    let rowStart = row * patchWidth
                    for column in stride(from: part.x, to: part.maxX, by: columnStep ?? step) {
                        let sourceX = column - shift.whole.x
                        // (the interpolation also reads the pixel left of and above the source)
                        guard sourceX >= 1, sourceY >= 1, sourceX < width, sourceY < height else {
                            target[rowStart + column] = -1
                            continue
                        }
                        target[rowStart + column] = shift.sample(pixels, at: sourceY * width + sourceX, rowLength: width)
                        inside += 1
                    }
                }
            }
        }
        return inside
    }

    /// Every how many rows and columns a comparison of `part` samples: about
    /// `Configuration.patchSamples` pixels (big paragraphs need not be compared pixel by pixel)
    private func step(for part: ThumbnailRect) -> Int {
        var step = 1
        while part.area / (step * step) > configuration.patchSamples {
            step += 1
        }
        return step
    }

    /// Mean difference (grey levels, squared or not) between the patch and the frame over `part`
    /// (patch pixels); nil when less than half of it lies inside the frame
    func difference(_ patch: BlockPatch, in image: LumaImage, x: Double, y: Double, part: ThumbnailRect,
                    squared: Bool) -> Double? {
        let step = step(for: part)
        sample(patch, in: image, x: x, y: y, part: part, step: step)
        let one = BilinearShift.one
        let cap = Int(configuration.matchCostCap) * one
        var sum = 0, count = 0, expected = 0
        let patchWidth = patch.width
        patch.pixels.withUnsafeBufferPointer { reference in
            sampled.withUnsafeBufferPointer { sampled in
            for row in stride(from: part.y, to: part.maxY, by: step) {
                for column in stride(from: part.x, to: part.maxX, by: step) {
                    expected += 1
                    let value = sampled[row * patchWidth + column]
                    guard value >= 0 else { continue }
                    let difference = min(cap, abs(value - Int(reference[row * patchWidth + column]) * one))
                    // (squared in 1/16 grey levels: no overflow for any patch)
                    sum += squared ? (difference >> 4) * (difference >> 4) : difference
                    count += 1
                }
            }
            }
        }
        guard count * 2 >= expected, count > 0 else { return nil }
        return squared ? Double(sum) / Double(count * 256) : Double(sum) / Double(count * one)
    }

    /// The position near (x, y) where the patch fits best over `part`, to a fraction of a pixel:
    /// whole-pixel steps downhill (at most `radius`), then a parabola through the neighbours
    /// along each axis. nil when too little of the patch lies inside the frame.
    func locate(_ patch: BlockPatch, in image: LumaImage, x: Double, y: Double, part: ThumbnailRect,
                radius: Int) -> (x: Double, y: Double)? {
        guard var center = difference(patch, in: image, x: x, y: y, part: part, squared: true) else { return nil }
        var stepX = 0, stepY = 0
        var left = 0.0, right = 0.0, up = 0.0, down = 0.0
        var steps = 0
        while true {
            let baseX = x + Double(stepX), baseY = y + Double(stepY)
            left = difference(patch, in: image, x: baseX - 1, y: baseY, part: part, squared: true) ?? .infinity
            right = difference(patch, in: image, x: baseX + 1, y: baseY, part: part, squared: true) ?? .infinity
            up = difference(patch, in: image, x: baseX, y: baseY - 1, part: part, squared: true) ?? .infinity
            down = difference(patch, in: image, x: baseX, y: baseY + 1, part: part, squared: true) ?? .infinity
            let lowest = min(left, right, up, down)
            guard lowest < center, steps < radius else { break }
            if lowest == left {
                stepX -= 1
            } else if lowest == right {
                stepX += 1
            } else if lowest == up {
                stepY -= 1
            } else {
                stepY += 1
            }
            center = lowest
            steps += 1
        }
        let fineX = left.isFinite && right.isFinite ? MotionEstimator.vertex(left, center, right) : 0
        let fineY = up.isFinite && down.isFinite ? MotionEstimator.vertex(up, center, down) : 0
        return (x + Double(stepX) + fineX, y + Double(stepY) + fineY)
    }

    /// The part of `inner` (patch pixels: the block itself) that shows in the frame with the
    /// patch at (x, y): rows and columns that differ clearly from the patch are something that
    /// lies over the text or has replaced it. Cut off from the edges where they begin there;
    /// nil when they lie inside (something covers the middle, the text changed) or too little
    /// is left.
    func visiblePart(_ patch: BlockPatch, in image: LumaImage, x: Double, y: Double, inner: ThumbnailRect) -> ThumbnailRect? {
        // every row is judged, on every other column of wide blocks
        let columnStep = inner.width > 2 * configuration.columnChunk ? 2 : 1
        sample(patch, in: image, x: x, y: y, part: inner, step: 1, columnStep: columnStep)
        let one = BilinearShift.one
        if foreignRows.count < inner.height {
            foreignRows = [Bool](repeating: false, count: inner.height)
            rowSigned = [Double](repeating: 0, count: inner.height)
        }
        // per row: the mean signed difference first, then each row judged with its neighbours
        // for the shift of brightness (a thin stroke that falls between two pixels moves the mean
        // of one row a lot and that of the next back; something plain over the text moves several)
        for row in inner.y..<inner.maxY {
            var absolute = 0, signed = 0, count = 0, expected = 0
            for column in stride(from: inner.x, to: inner.maxX, by: columnStep) {
                expected += 1
                let value = sampled[row * patch.width + column]
                guard value >= 0 else { continue }
                let difference = value - Int(patch.pixels[row * patch.width + column]) * one
                absolute += abs(difference)
                signed += difference
                count += 1
            }
            let index = row - inner.y
            // (mostly outside of the frame: nothing of it can be seen)
            guard count * 2 >= expected, count > 0 else {
                foreignRows[index] = true
                rowSigned[index] = .nan
                continue
            }
            rowSigned[index] = Double(signed) / Double(one * count)
            foreignRows[index] = Double(absolute) / Double(one * count)
                > configuration.foreignDifference + configuration.foreignTexture * patch.rowTexture[row]
        }
        for index in 0..<inner.height where !rowSigned[index].isNaN {
            let above = index > 0 && !rowSigned[index - 1].isNaN ? rowSigned[index - 1] : rowSigned[index]
            let below = index + 1 < inner.height && !rowSigned[index + 1].isNaN ? rowSigned[index + 1] : rowSigned[index]
            let smoothed = (above + 2 * rowSigned[index] + below) / 4
            if abs(smoothed) > configuration.foreignShift
                + configuration.foreignShiftTexture * patch.rowTexture[inner.y + index] {
                foreignRows[index] = true
            }
        }
        guard let rows = PatchMatcher.uncovered(foreignRows, count: inner.height,
                                                divisor: configuration.interiorForeignDivisor) else { return nil }
        let top = inner.y + rows.lowerBound, bottom = inner.y + rows.upperBound

        // columns, in narrow chunks, over the rows that can be seen
        let chunk = configuration.columnChunk
        let chunks = (inner.width + chunk - 1) / chunk
        if foreignChunks.count < chunks {
            foreignChunks = [Bool](repeating: false, count: chunks)
        }
        for index in 0..<chunks {
            let start = inner.x + index * chunk, end = min(inner.maxX, start + chunk)
            var absolute = 0, signed = 0, count = 0
            var texture = 0.0
            // sums for the correlation of the chunk with the frame (grey levels)
            var sumP = 0, sumC = 0, sumPP = 0, sumCC = 0, sumPC = 0
            for column in stride(from: start, to: end, by: columnStep) {
                texture += patch.columnTexture[column]
                for row in top..<bottom {
                    let value = sampled[row * patch.width + column]
                    guard value >= 0 else { continue }
                    let reference = Int(patch.pixels[row * patch.width + column])
                    let difference = value - reference * one
                    absolute += abs(difference)
                    signed += difference
                    count += 1
                    let frame = value >> 8
                    sumP += reference
                    sumC += frame
                    sumPP += reference * reference
                    sumCC += frame * frame
                    sumPC += reference * frame
                }
            }
            let lines = (end - start + columnStep - 1) / columnStep
            foreignChunks[index] = isForeign(absolute: Double(absolute) / Double(one), signed: Double(signed) / Double(one),
                                             count: count, expected: lines * (bottom - top),
                                             texture: texture / Double(lines))
                || isOtherDetail(count: count, sumP: sumP, sumC: sumC, sumPP: sumPP, sumCC: sumCC, sumPC: sumPC)
        }
        guard let columns = PatchMatcher.uncovered(foreignChunks, count: chunks,
                                                   divisor: configuration.interiorForeignDivisor) else { return nil }
        let left = inner.x + columns.lowerBound * chunk, right = min(inner.maxX, inner.x + columns.upperBound * chunk)
        let visible = ThumbnailRect(x: left, y: top, width: right - left, height: bottom - top)
        guard Double(visible.area) >= configuration.minVisibleShare * Double(inner.area) else { return nil }
        // what is left must hold a good part of the text, not just the plain rows around it
        var total = 0.0, kept = 0.0
        for row in inner.y..<inner.maxY {
            total += patch.rowTexture[row]
            if row >= top, row < bottom { kept += patch.rowTexture[row] }
        }
        guard kept >= configuration.minVisibleTexture * total else { return nil }
        return visible
    }

    /// The lines (rows or column chunks) left between what covers a block from its edges: from
    /// each end, the longest run in which at least three in four lines are foreign and that ends
    /// with a foreign one (a line half under a bar may pass for its own). nil when nothing is
    /// left, or more than one in `divisor` of what is left is foreign as well.
    static func uncovered(_ foreign: [Bool], count: Int, divisor: Int) -> Range<Int>? {
        // (a run from an edge counts as covered when at least `coveredParts` of `coveredOf` of its
        // lines are foreign)
        var start = 0, foreignSeen = 0
        for index in 0..<count where foreign[index] {
            foreignSeen += 1
            if foreignSeen * coveredOf >= (index + 1) * coveredParts { start = index + 1 }
        }
        var end = count
        foreignSeen = 0
        for index in stride(from: count - 1, through: start, by: -1) where foreign[index] {
            foreignSeen += 1
            if foreignSeen * coveredOf >= (count - index) * coveredParts { end = index }
        }
        guard end > start else { return nil }
        var interior = 0
        for index in start..<end where foreign[index] {
            interior += 1
        }
        guard interior <= max(1, (end - start) / divisor) else { return nil }
        return start..<end
    }

    /// Both the patch and the frame show detail in a chunk, but not the same: their correlation
    /// is low. (A misalignment by a fraction of a pixel or a blur keeps it high; other letters
    /// in the same place – a line that looks alike – do not.)
    private func isOtherDetail(count: Int, sumP: Int, sumC: Int, sumPP: Int, sumCC: Int, sumPC: Int) -> Bool {
        guard count >= PatchMatcher.fewestCorrelated else { return false }
        let n = Double(count)
        let varianceP = Double(sumPP) / n - (Double(sumP) / n) * (Double(sumP) / n)
        let varianceC = Double(sumCC) / n - (Double(sumC) / n) * (Double(sumC) / n)
        let minimum = configuration.detailVariance
        guard varianceP >= minimum, varianceC >= minimum else { return false }
        let covariance = Double(sumPC) / n - (Double(sumP) / n) * (Double(sumC) / n)
        return covariance / (varianceP * varianceC).squareRoot() < configuration.minDetailCorrelation
    }

    /// A row or column of the patch differs from the frame by more than noise and misalignment
    /// explain: its brightness moved (something plain lies over it) or its detail differs
    private func isForeign(absolute: Double, signed: Double, count: Int, expected: Int, texture: Double) -> Bool {
        // (mostly outside of the frame: nothing of it can be seen)
        guard count * 2 >= expected, count > 0 else { return true }
        let meanSigned = abs(signed) / Double(count), meanAbsolute = absolute / Double(count)
        return meanSigned > configuration.foreignShift + configuration.foreignShiftTexture * texture
            || meanAbsolute > configuration.foreignDifference + configuration.foreignTexture * texture
    }
}
