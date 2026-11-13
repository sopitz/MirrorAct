// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
// CGRect is a Foundation type on Linux; on Apple platforms its members come with CoreGraphics
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A rectangle of whole thumbnail pixels
struct ThumbnailRect: Equatable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    static let empty = ThumbnailRect(x: 0, y: 0, width: 0, height: 0)

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var area: Int { isEmpty ? 0 : width * height }

    func union(_ other: ThumbnailRect) -> ThumbnailRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let left = min(x, other.x), top = min(y, other.y)
        return ThumbnailRect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }

    func intersection(_ other: ThumbnailRect) -> ThumbnailRect {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return .empty }
        return ThumbnailRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    func contains(x px: Double, y py: Double) -> Bool {
        px >= Double(x) && px < Double(maxX) && py >= Double(y) && py < Double(maxY)
    }
}

/// What became of a tile of the thumbnail between two frames
enum TileKind: UInt8 {
    /// the same as before, with something to see in it
    case still
    /// the same as before and plain (about one shade): it may as well have moved
    case plain
    /// content that moved, by the motion `MotionEstimator.motionIndex` names
    case moved
    /// content that came into view where moving content enters
    case entered
    /// changed in a way no motion explains: another picture, a video, a pop-up
    case changed
    /// changed a little in place: the codec repairing what it damaged, a step of a fade
    case drifted
}

/// How a part of the picture moved between two frames
struct FrameMotion: Equatable {
    /// movement in thumbnail pixels, x to the right, y down
    var dx: Double
    var dy: Double
    /// where content that moves like this shows in the current frame (thumbnail pixels); the
    /// edges across the movement are refined to the pixel row or column
    var area: ThumbnailRect
    /// tiles that moved like this
    var tiles: Int
    /// the edges of `area` that were found to the pixel: `FrameMotion.top` … `.right`
    var refinedEdges: Int

    static let top = 1
    static let bottom = 2
    static let left = 4
    static let right = 8
}

/// Finds out for two consecutive thumbnails which parts of the picture stayed, which moved and
/// how far (a scrolling page, and maybe a few more parts that move on their own), and which
/// changed in some other way.
///
/// It works on square tiles (`Configuration.tileSize`). Candidates for a movement come from
/// row and column sums (projection profiles) of the changed part in a few bands, plus the
/// movements of the frame before; each is checked on real pixels of a sample of tiles, the best
/// is refined to a fraction of a pixel, and then every changed tile is checked against it. What
/// it does not explain may be a second moving part; what is left in the end has changed.
/// Buffers are kept from frame to frame.
final class MotionEstimator {
    private let configuration: OverlayTracker.Configuration

    /// the tile grid of the last analysis
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var kinds: [TileKind] = []
    /// index into `motions` for moved and entered tiles, else -1
    private(set) var motionIndex: [Int8] = []
    private(set) var motions: [FrameMotion] = []
    /// tiles whose change no motion explains
    private(set) var changedTiles = 0
    /// per tile: `stillFits` or `stillAgainstMotion` for a tile that did not change, shows
    /// something and lies inside the area of a movement of this frame (whether the movement
    /// explains it), else 0
    private(set) var stillVerdicts: [UInt8] = []
    static let stillFits: UInt8 = 1
    /// something that stays while the content around it moves: a floating button, a header
    /// that sticks (or a tile whose source the codec damaged)
    static let stillAgainstMotion: UInt8 = 2
    /// for a tile `stillAgainstMotion`: the pixels around it (in it and its neighbours) that stay
    /// in place and do not fit the movement – where the thing that stays shows
    private(set) var stayBoxes: [ThumbnailRect] = []

    private var width = 0
    private var height = 0
    // per tile, over the pixels that are sampled (every other row)
    private var samples: [Int32] = []
    private var absoluteSum: [Int32] = []
    private var signedSum: [Int32] = []
    /// sum over the samples of the steps to the next pixel right and down (of the current frame)
    private var textureSum: [Int32] = []
    /// sum over the samples of the current frame, and the mean brightness of every tile when it
    /// was last accepted as it is (moved in, changed, or first seen): a slow fade is a change too
    private var valueSum: [Int32] = []
    private var acceptedMean: [Double] = []
    /// the larger brightness range of the tile in the two frames, and that of the current one
    private var range: [Int32] = []
    private var rangeNow: [Int32] = []
    /// nothing is known about the tiles yet (first frame of this size)
    private var needsFullStructure = true
    // scratch
    private var residual: [Int] = []
    private var visited: [Bool] = []
    private var group: [Int] = []
    private var chosen: [Int] = []
    /// textured tiles of `residual` (the sample `chosen` is drawn from), and the box around it
    private var residualTextured = 0
    private var residualBox = ThumbnailRect.empty
    private var profilePrevious: [Int32] = []
    private var profileCurrent: [Int32] = []
    private var coarsePrevious: [Int32] = []
    private var coarseCurrent: [Int32] = []
    private var firstMoved: [Int] = []
    private var lastMoved: [Int] = []

    init(configuration: OverlayTracker.Configuration) {
        self.configuration = configuration
    }

    private var tileSize: Int { configuration.tileSize }

    /// profiles are first compared at a quarter of their resolution (a long movement costs a
    /// sixteenth then), over at least `shortestProfile` coarse entries in common; a band of a
    /// profile is at least `bandWidth` pixels wide
    private static let coarseGroup = 4
    private static let shortestProfile = 16
    private static let bandWidth = 8
    /// whole-pixel steps downhill when a movement is refined, from the candidate it started at
    private static let refineSteps = 3

    /// The pixels of a tile
    func tileRect(_ index: Int) -> ThumbnailRect {
        let column = index % columns, row = index / columns
        let x = column * tileSize, y = row * tileSize
        return ThumbnailRect(x: x, y: y, width: min(tileSize, width - x), height: min(tileSize, height - y))
    }

    /// The tile a pixel lies in, nil outside of the picture
    func tile(atX x: Double, y: Double) -> Int? {
        guard x >= 0, y >= 0, x < Double(width), y < Double(height) else { return nil }
        return Int(y) / tileSize * columns + Int(x) / tileSize
    }

    /// The tiles a rectangle (thumbnail pixels) touches, clipped to the picture
    func tileRange(of rect: CGRect) -> (columns: Range<Int>, rows: Range<Int>) {
        let left = max(0, Int(floor(rect.minX)) / tileSize), top = max(0, Int(floor(rect.minY)) / tileSize)
        let right = min(columns, Int(ceil(rect.maxX)) / tileSize + 1), bottom = min(rows, Int(ceil(rect.maxY)) / tileSize + 1)
        guard right > left, bottom > top, rect.maxX > 0, rect.maxY > 0 else { return (0..<0, 0..<0) }
        return (left..<right, top..<bottom)
    }

    /// Mean step to the next pixel inside a tile of the current frame: how much there is to see
    func texture(ofTile index: Int) -> Double {
        // (measured on every other column of the rows the differences were taken on)
        2 * Double(textureSum[index]) / Double(max(1, samples[index]))
    }

    // MARK: Analysis

    /// Compares `current` with `previous` (of the same size). Returns false when no tile differs
    /// by more than the noise of the link; the tile kinds are then not filled in.
    func analyze(previous: LumaImage, current: LumaImage, priors: [FrameMotion]) -> Bool {
        prepare(width: current.width, height: current.height)
        motions = []
        changedTiles = 0
        guard measureDifferences(previous, current) > 0 || hasDrifted() else { return false }
        measureStructure(previous, current)
        classify()
        findMotions(previous, current, priors: priors)
        acceptOrNoteDrift()
        judgeStillTiles(previous, current)
        var count = 0
        for kind in kinds where kind == .changed {
            count += 1
        }
        changedTiles = count
        return true
    }

    /// Forgets the pictures compared so far. What it keeps from one comparison to the next (how
    /// every tile was accepted, how much there is to see in it) describes a screen that may be
    /// long gone after a pause; the next comparison measures every tile anew.
    func reset() {
        for index in acceptedMean.indices {
            acceptedMean[index] = -1
        }
        needsFullStructure = true
    }

    private func prepare(width newWidth: Int, height newHeight: Int) {
        guard newWidth != width || newHeight != height || kinds.isEmpty else { return }
        width = newWidth
        height = newHeight
        columns = (width + tileSize - 1) / tileSize
        rows = (height + tileSize - 1) / tileSize
        let count = columns * rows
        kinds = [TileKind](repeating: .still, count: count)
        motionIndex = [Int8](repeating: -1, count: count)
        samples = [Int32](repeating: 0, count: count)
        absoluteSum = [Int32](repeating: 0, count: count)
        signedSum = [Int32](repeating: 0, count: count)
        textureSum = [Int32](repeating: 0, count: count)
        range = [Int32](repeating: 0, count: count)
        rangeNow = [Int32](repeating: 0, count: count)
        valueSum = [Int32](repeating: 0, count: count)
        stillVerdicts = [UInt8](repeating: 0, count: count)
        stayBoxes = [ThumbnailRect](repeating: .empty, count: count)
        acceptedMean = [Double](repeating: -1, count: count)
        needsFullStructure = true
    }

    /// Differences of the tiles at the same place, over every other row. Returns the number of
    /// tiles that differ.
    private func measureDifferences(_ previous: LumaImage, _ current: LumaImage) -> Int {
        let size = tileSize, columns = columns, width = width, height = height
        samples.withUnsafeMutableBufferPointer { countBuffer in
            absoluteSum.withUnsafeMutableBufferPointer { absoluteBuffer in
                signedSum.withUnsafeMutableBufferPointer { signedBuffer in
                  valueSum.withUnsafeMutableBufferPointer { valueBuffer in
                    // (plain loops over pointers: this runs for every frame, also in builds without
                    // optimization, where ranges and buffer subscripts are calls)
                    guard let counts = countBuffer.baseAddress, let absolutes = absoluteBuffer.baseAddress,
                          let signeds = signedBuffer.baseAddress, let values = valueBuffer.baseAddress else { return }
                    let tiles = countBuffer.count
                    var tile = 0
                    while tile < tiles {
                        counts[tile] = 0
                        absolutes[tile] = 0
                        signeds[tile] = 0
                        values[tile] = 0
                        tile += 1
                    }
                    previous.pixels.withUnsafeBufferPointer { beforeBuffer in
                        current.pixels.withUnsafeBufferPointer { nowBuffer in
                            guard let before = beforeBuffer.baseAddress, let now = nowBuffer.baseAddress else { return }
                            var y = 0
                            while y < height {
                                let row = y * width, tileRow = (y / size) * columns
                                var column = 0
                                while column < columns {
                                    let start = row + column * size
                                    let end = row + (width < column * size + size ? width : column * size + size)
                                    var absolute: Int32 = 0, signed: Int32 = 0, value: Int32 = 0
                                    var index = start
                                    while index < end {
                                        let pixel = Int32(now[index])
                                        let difference = pixel - Int32(before[index])
                                        absolute += difference < 0 ? -difference : difference
                                        signed += difference
                                        value += pixel
                                        index += 1
                                    }
                                    absolutes[tileRow + column] += absolute
                                    signeds[tileRow + column] += signed
                                    values[tileRow + column] += value
                                    counts[tileRow + column] += Int32(end - start)
                                    column += 1
                                }
                                y += 2
                            }
                        }
                    }
                  }
                }
            }
        }
        var differing = 0
        for index in samples.indices where differs(index) {
            differing += 1
        }
        return differing
    }

    private func differs(_ index: Int) -> Bool {
        let count = Double(max(1, samples[index]))
        return Double(absoluteSum[index]) / count > configuration.tileChangeDifference
            || abs(Double(signedSum[index])) / count > configuration.tileChangeShift
    }

    /// How much there is to see in every tile (over the same rows as the differences)
    private func measureStructure(_ previous: LumaImage, _ current: LumaImage) {
        let size = tileSize, columns = columns, rows = rows, width = width, height = height
        let measureAll = needsFullStructure
        needsFullStructure = false
        range.withUnsafeMutableBufferPointer { ranges in
            rangeNow.withUnsafeMutableBufferPointer { rangesNow in
                textureSum.withUnsafeMutableBufferPointer { textures in
                    previous.pixels.withUnsafeBufferPointer { beforeBuffer in
                        current.pixels.withUnsafeBufferPointer { nowBuffer in
                            // (plain loops over pointers, as in `measureDifferences`)
                            guard let before = beforeBuffer.baseAddress, let now = nowBuffer.baseAddress else { return }
                            var tileRow = 0
                            while tileRow < rows {
                                defer { tileRow += 1 }
                                let top = tileRow * size, bottom = min(height, top + size)
                                var column = 0
                                while column < columns {
                                    defer { column += 1 }
                                    // (a tile that did not change keeps what was measured of it)
                                    let index = tileRow * columns + column
                                    if !measureAll, !differs(index) { continue }
                                    let start = column * size, end = min(width, start + size)
                                    var lowNow: Int32 = 255, highNow: Int32 = 0, lowBefore: Int32 = 255
                                    var highBefore: Int32 = 0, texture: Int32 = 0
                                    var y = top
                                    while y < bottom {
                                        let row = y * width
                                        let below = y + 1 < height ? row + width : row
                                        var x = start
                                        while x < end {
                                            let value = Int32(now[row + x]), old = Int32(before[row + x])
                                            if value < lowNow { lowNow = value }
                                            if value >= highNow { highNow = value }
                                            if old < lowBefore { lowBefore = old }
                                            if old >= highBefore { highBefore = old }
                                            let right = x + 1 < width ? Int32(now[row + x + 1]) : value
                                            let across = right - value, down = Int32(now[below + x]) - value
                                            texture += (across < 0 ? -across : across) + (down < 0 ? -down : down)
                                            x += 2
                                        }
                                        y += 2
                                    }
                                    ranges[index] = max(highNow - lowNow, highBefore - lowBefore)
                                    rangesNow[index] = highNow - lowNow
                                    textures[index] = texture
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Some tile drifted from how it was accepted by more than the limit (also noting the mean of
    /// tiles that were not seen before)
    private func hasDrifted() -> Bool {
        var drifted = false
        for index in acceptedMean.indices {
            let mean = Double(valueSum[index]) / Double(max(1, samples[index]))
            if acceptedMean[index] < 0 {
                acceptedMean[index] = mean
            } else if abs(mean - acceptedMean[index]) > configuration.tileDriftLimit {
                drifted = true
            }
        }
        return drifted
    }

    /// Fills `stillVerdicts`: inside the area of every movement, whether the tiles that stayed as
    /// they were fit it
    private func judgeStillTiles(_ previous: LumaImage, _ current: LumaImage) {
        for index in stillVerdicts.indices {
            stillVerdicts[index] = 0
        }
        guard !motions.isEmpty else { return }
        let width = width, height = height
        previous.pixels.withUnsafeBufferPointer { before in
            current.pixels.withUnsafeBufferPointer { now in
                for (index, motion) in motions.enumerated() {
                    let shift = BilinearShift(dx: motion.dx, dy: motion.dy)
                    let area = motion.area
                    guard !area.isEmpty else { continue }
                    let alongY = abs(motion.dy) >= abs(motion.dx)
                    let firstRow = area.y / tileSize, lastRow = (area.maxY - 1) / tileSize
                    let firstColumn = area.x / tileSize, lastColumn = (area.maxX - 1) / tileSize
                    // per line along the movement (a column when it is vertical): the first and the last
                    // tile of it that moved like this
                    let lines = alongY ? columns : rows
                    if firstMoved.count != lines {
                        firstMoved = [Int](repeating: 0, count: lines)
                        lastMoved = [Int](repeating: 0, count: lines)
                    }
                    for line in 0..<lines {
                        firstMoved[line] = Int.max
                        lastMoved[line] = -1
                    }
                    // (while loops: ranges are calls in builds without optimization)
                    var row = firstRow
                    while row <= lastRow {
                        var column = firstColumn
                        while column <= lastColumn {
                            if motionIndex[row * columns + column] == Int8(index) {
                                let line = alongY ? column : row, position = alongY ? row : column
                                firstMoved[line] = min(firstMoved[line], position)
                                lastMoved[line] = max(lastMoved[line], position)
                            }
                            column += 1
                        }
                        row += 1
                    }
                    row = firstRow
                    while row <= lastRow {
                        defer { row += 1 }
                        var column = firstColumn
                        while column <= lastColumn {
                            defer { column += 1 }
                            let tile = row * columns + column
                            guard kinds[tile] == .still, stillVerdicts[tile] == 0 else { continue }
                            // only an island in what moves: content moved on both sides of it along the
                            // movement (the edge of a bar is no overlay)
                            let line = alongY ? column : row, position = alongY ? row : column
                            guard firstMoved[line] < position, position < lastMoved[line] else { continue }
                            let rect = tileRect(tile)
                            guard rect.x - shift.whole.x - 1 >= 0, rect.y - shift.whole.y - 1 >= 0,
                                  rect.maxX - shift.whole.x <= width, rect.maxY - shift.whole.y <= height else { continue }
                            let fits = tileDifference(rect, shift: shift, before, now, width: width)
                                <= configuration.matchBase + 2 * configuration.matchTexture * texture(ofTile: tile)
                            if fits {
                                stillVerdicts[tile] = MotionEstimator.stillFits
                            } else {
                                stillVerdicts[tile] = MotionEstimator.stillAgainstMotion
                                stayBoxes[tile] = stayingPixels(around: tile, shift: shift, before, now)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The box of the pixels in a tile and its neighbours that stay as they were and do not fit
    /// the movement `shift` (every pixel: an overlay must be avoided to the pixel)
    private func stayingPixels(around tile: Int, shift: BilinearShift, _ before: UnsafeBufferPointer<UInt8>,
                               _ now: UnsafeBufferPointer<UInt8>) -> ThumbnailRect {
        let center = tileRect(tile)
        let left = max(1 + max(0, shift.whole.x), center.x - tileSize)
        let top = max(1 + max(0, shift.whole.y), center.y - tileSize)
        let right = min(width + min(0, shift.whole.x), center.maxX + tileSize)
        let bottom = min(height + min(0, shift.whole.y), center.maxY + tileSize)
        guard right > left, bottom > top else { return .empty }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        guard let beforePixels = before.baseAddress, let nowPixels = now.baseAddress else { return .empty }
        let width = width, one = BilinearShift.one
        let stayDifference = configuration.stayDifference, contrast = configuration.stayContrast * one
        // (plain loops over pointers: every pixel of nine tiles, also in builds without optimization)
        var y = top
        while y < bottom {
            let row = y * width
            let source = (y - shift.whole.y) * width - shift.whole.x
            var x = left
            while x < right {
                defer { x += 1 }
                let value = Int(nowPixels[row + x])
                let still = value - Int(beforePixels[row + x])
                guard (still < 0 ? -still : still) <= stayDifference else { continue }
                let moved = value * one - shift.sample(beforePixels, at: source + x, rowLength: width)
                if (moved < 0 ? -moved : moved) >= contrast {
                    if x < minX { minX = x }
                    if x >= maxX { maxX = x }
                    if y < minY { minY = y }
                    if y >= maxY { maxY = y }
                }
            }
            y += 1
        }
        guard maxX >= 0 else { return .empty }
        return ThumbnailRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Tiles that moved in or changed are accepted as they are now; a tile that only drifted, a
    /// little in every frame, has changed once it drifted far enough from how it was accepted
    private func acceptOrNoteDrift() {
        for index in kinds.indices {
            let mean = Double(valueSum[index]) / Double(max(1, samples[index]))
            switch kinds[index] {
            case .moved, .entered, .changed:
                acceptedMean[index] = mean
            case .still, .plain, .drifted:
                if acceptedMean[index] < 0 {
                    acceptedMean[index] = mean
                } else if abs(mean - acceptedMean[index]) > configuration.tileDriftLimit {
                    kinds[index] = .changed
                    motionIndex[index] = -1
                    acceptedMean[index] = mean
                }
            }
        }
    }

    private func classify() {
        for index in kinds.indices {
            motionIndex[index] = -1
            if differs(index) {
                kinds[index] = .changed
            } else {
                kinds[index] = range[index] <= Int32(configuration.plainRange) ? .plain : .still
            }
        }
    }

    // MARK: Motions

    private struct Candidate {
        var dx: Int
        var dy: Int
        var cost = Double.infinity
        var matched = 0
        var valid = 0
        var isPrior = false
    }

    private func findMotions(_ previous: LumaImage, _ current: LumaImage, priors: [FrameMotion]) {
        for _ in 0..<configuration.maxMotions {
            residual.removeAll(keepingCapacity: true)
            if motions.isEmpty {
                for index in kinds.indices where kinds[index] == .changed {
                    residual.append(index)
                }
                guard residual.count >= configuration.minMotionTiles else { return }
            } else {
                // another moving part is one connected group of tiles, not damage strewn about
                largestChangedGroup()
                guard residual.count >= configuration.minSecondMotionTiles else { return }
            }
            chooseSample()
            guard chosen.count >= configuration.minMotionTiles else { return }

            // the movements of the frame before first: while scrolling one of them is right
            var tried: [Candidate] = []
            for prior in priors {
                // the whole pixels around it: the speed changes by a fraction of a pixel per frame
                for dx in Set([Int(floor(prior.dx)), Int(ceil(prior.dx))]).sorted() {
                    for dy in Set([Int(floor(prior.dy)), Int(ceil(prior.dy))]).sorted() {
                        var candidate = Candidate(dx: dx, dy: dy, isPrior: true)
                        if candidate.dx == 0, candidate.dy == 0 { continue }
                        if tried.contains(where: { $0.dx == candidate.dx && $0.dy == candidate.dy }) { continue }
                        score(&candidate, previous, current)
                        tried.append(candidate)
                    }
                }
            }
            var found: (dx: Double, dy: Double)?
            var still = Candidate(dx: 0, dy: 0)
            score(&still, previous, current)
            // (when nothing moving fits better, the movement may have stopped: rows that repeat look
            // the same moved by one row as not moved at all, and the full search decides)
            if let prior = choose(tried), still.cost > prior.cost {
                found = accepted(prior, share: configuration.priorShortcutShare, previous, current)
            }
            if found == nil {
                // nothing moved and it only drifted (the codec repairs what it damaged, a fade): no search
                if Double(still.matched) >= configuration.priorShortcutShare * Double(still.valid),
                   let motion = accepted(still, share: configuration.priorShortcutShare, previous, current),
                   motion.dx == 0, motion.dy == 0 {
                    found = motion
                }
            }
            if found == nil {
                // no movement at all (the codec still repairs the picture after a movement), and a
                // step of less than a pixel: it changes everything a little
                for unit in [(0, 0), (0, -1), (0, 1), (-1, 0), (1, 0)] {
                    tried.append(Candidate(dx: unit.0, dy: unit.1))
                }
                for candidate in profileCandidates(previous, current) {
                    tried.append(candidate)
                }
                var scored: [Candidate] = []
                for candidate in tried {
                    if scored.contains(where: { $0.dx == candidate.dx && $0.dy == candidate.dy }) { continue }
                    var copy = candidate
                    if copy.valid == 0 { score(&copy, previous, current) }
                    scored.append(copy)
                }
                // the cheapest few, checked to a fraction of a pixel
                var firstAccepted: (candidate: Candidate, motion: (dx: Double, dy: Double))?
                for _ in 0..<configuration.profileCandidates {
                    guard let best = choose(scored) else { break }
                    scored.removeAll { $0.dx == best.dx && $0.dy == best.dy }
                    if let motion = accepted(best, share: configuration.minMatchedShare, previous, current) {
                        firstAccepted = (best, motion)
                        break
                    }
                }
                found = firstAccepted?.motion
                // Scrolling does not jump from one speed to a very different one between two frames:
                // a movement of the frame before that still explains the picture keeps winning
                // unless another one is clearly better (rows that look alike repeat at one row's
                // distance; the codec damages the true movement more, as it is the faster one).
                if let other = firstAccepted, !other.candidate.isPrior,
                   let prior = tried.filter({ $0.isPrior && isAcceptable($0) }).min(by: { $0.cost < $1.cost }),
                   other.candidate.cost > (1 - configuration.priorAdvantage) * prior.cost,
                   let motion = accepted(prior, share: configuration.minMatchedShare, previous, current) {
                    found = motion
                }
            }
            guard let (dx, dy) = found else { return }
            if dx == 0, dy == 0 {
                // nothing moved: what it explains is damage that is being repaired
                guard labelStill(previous, current) >= configuration.minMotionTiles else { return }
                continue
            }
            let index = motions.count
            let moved = labelMoved(index, dx: dx, dy: dy, previous, current)
            var movedBox = ThumbnailRect.empty
            for tile in kinds.indices where motionIndex[tile] == Int8(index) {
                movedBox = movedBox.union(tileRect(tile))
            }
            // (a part that moves is more than a line of tiles: one row of letters may fit anywhere;
            // a second one is most of what shows where it is, not a few tiles strewn over another)
            guard moved >= configuration.minMotionTiles, movedBox.width > tileSize, movedBox.height > tileSize,
                  index == 0 || Double(moved) >= configuration.minMotionDensity * Double(texturedTiles(in: movedBox))
            else {
                // (it explains too little: undo)
                for tile in kinds.indices where motionIndex[tile] == Int8(index) {
                    kinds[tile] = .changed
                    motionIndex[tile] = -1
                }
                return
            }
            labelEntered(index, dx: dx, dy: dy)
            var area = trimmedBox(of: index)
            let refined = refineEdges(&area, dx: dx, dy: dy, previous, current)
            motions.append(FrameMotion(dx: dx, dy: dy, area: area, tiles: moved, refinedEdges: refined))
        }
    }

    /// The movement a candidate leads to, to a fraction of a pixel, when it explains at least
    /// `share` of the tiles it can be checked on and a good part of all that changed
    private func accepted(_ candidate: Candidate, share: Double, _ previous: LumaImage,
                          _ current: LumaImage) -> (dx: Double, dy: Double)? {
        guard isAcceptable(candidate) else { return nil }
        let (dx, dy) = refine(candidate, previous, current)
        let (matched, valid) = check(dx: dx, dy: dy, previous, current)
        guard valid >= configuration.minMotionTiles, Double(matched) >= share * Double(valid),
              Double(matched) >= configuration.minExplainedShare * Double(chosen.count) else { return nil }
        if dx != 0 || dy != 0 {
            // Content that moves changes nearly every tile that shows something. Tiles that stayed
            // as they were but do not fit the movement say that it did not happen: rows that look
            // alike, one row apart, while the codec repairs a picture that came to rest.
            let explained = Double(matched) * Double(residualTextured) / Double(max(1, chosen.count))
            let contradicting = contradictingStillTiles(dx: dx, dy: dy, previous, current)
            if contradicting >= Double(configuration.minMotionTiles),
               contradicting > configuration.maxContradictingShare * explained {
                return nil
            }
        }
        return (dx, dy)
    }

    /// About how many tiles inside the changed part that did not change and show something are
    /// not explained by a movement (from an even sample of at most `motionSampleTiles` of them)
    private func contradictingStillTiles(dx: Double, dy: Double, _ previous: LumaImage, _ current: LumaImage) -> Double {
        guard !residualBox.isEmpty else { return 0 }
        let shift = BilinearShift(dx: dx, dy: dy)
        let width = width, height = height
        let firstColumn = residualBox.x / tileSize, lastColumn = (residualBox.maxX - 1) / tileSize
        let firstRow = residualBox.y / tileSize, lastRow = (residualBox.maxY - 1) / tileSize
        var still = 0
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn where kinds[row * columns + column] == .still {
                still += 1
            }
        }
        guard still > 0 else { return 0 }
        let step = max(1, still / configuration.motionSampleTiles)
        var counter = 0, contradicted = 0
        previous.pixels.withUnsafeBufferPointer { before in
            current.pixels.withUnsafeBufferPointer { now in
                for row in firstRow...lastRow {
                    for column in firstColumn...lastColumn where kinds[row * columns + column] == .still {
                        counter += 1
                        guard counter % step == 0 else { continue }
                        let tile = row * columns + column
                        let rect = tileRect(tile)
                        guard rect.x - shift.whole.x - 1 >= 0, rect.y - shift.whole.y - 1 >= 0,
                              rect.maxX - shift.whole.x <= width, rect.maxY - shift.whole.y <= height else { continue }
                        // (clearly: a movement measured to a fraction of a pixel leaves some of the edges)
                        if tileDifference(rect, shift: shift, before, now, width: width)
                            > configuration.matchBase + 2 * configuration.matchTexture * texture(ofTile: tile) {
                            contradicted += 1
                        }
                    }
                }
            }
        }
        return Double(contradicted * step)
    }

    /// How many of the sampled tiles a movement explains, sampled between pixels
    private func check(dx: Double, dy: Double, _ previous: LumaImage, _ current: LumaImage) -> (matched: Int, valid: Int) {
        let shift = BilinearShift(dx: dx, dy: dy)
        let width = width
        var matched = 0, valid = 0
        previous.pixels.withUnsafeBufferPointer { before in
            current.pixels.withUnsafeBufferPointer { now in
                for tile in chosen {
                    let rect = tileRect(tile)
                    guard rect.x - shift.whole.x - 1 >= 0, rect.y - shift.whole.y - 1 >= 0,
                          rect.maxX - shift.whole.x <= width, rect.maxY - shift.whole.y <= height else { continue }
                    valid += 1
                    if tileDifference(rect, shift: shift, before, now, width: width)
                        <= configuration.matchBase + configuration.matchTexture * texture(ofTile: tile) {
                        matched += 1
                    }
                }
            }
        }
        return (matched, valid)
    }

    /// Mean difference of a tile to where `shift` says it came from (every other row)
    private func tileDifference(_ rect: ThumbnailRect, shift: BilinearShift, _ before: UnsafeBufferPointer<UInt8>,
                                _ now: UnsafeBufferPointer<UInt8>, width: Int) -> Double {
        guard let before = before.baseAddress, let now = now.baseAddress else { return 0 }
        let one = BilinearShift.one, wholeX = shift.whole.x, wholeY = shift.whole.y
        let left = rect.x, right = rect.maxX, bottom = rect.maxY
        var sum = 0, samples = 0
        var y = rect.y
        while y < bottom {
            let row = y * width
            let source = (y - wholeY) * width - wholeX
            var x = left
            while x < right {
                let difference = Int(now[row + x]) * one - shift.sample(before, at: source + x, rowLength: width)
                sum += difference < 0 ? -difference : difference
                samples += 1
                x += 2
            }
            y += 2
        }
        return Double(sum) / Double(max(1, samples * one))
    }

    /// The box of the tiles of a motion, without edge rows and columns in which it explains only
    /// a stray tile or two among others that show something (a few tiles of a bar that happen to
    /// fit the movement do not make the bar part of what moves)
    private func trimmedBox(of index: Int) -> ThumbnailRect {
        var left = columns, top = rows, right = -1, bottom = -1
        for tile in kinds.indices where motionIndex[tile] == Int8(index) {
            left = min(left, tile % columns)
            right = max(right, tile % columns)
            top = min(top, tile / columns)
            bottom = max(bottom, tile / columns)
        }
        guard right >= left else { return .empty }
        func isSparse(_ line: Int, alongY: Bool) -> Bool {
            var mine = 0, textured = 0
            let range = alongY ? left...right : top...bottom
            for position in range {
                let tile = alongY ? line * columns + position : position * columns + line
                if motionIndex[tile] == Int8(index) { mine += 1 }
                if rangeNow[tile] > Int32(configuration.plainRange) { textured += 1 }
            }
            return mine <= 2 && Double(mine) < configuration.minEdgeShare * Double(max(1, textured))
        }
        while top < bottom, isSparse(top, alongY: true) { top += 1 }
        while bottom > top, isSparse(bottom, alongY: true) { bottom -= 1 }
        while left < right, isSparse(left, alongY: false) { left += 1 }
        while right > left, isSparse(right, alongY: false) { right -= 1 }
        let first = tileRect(top * columns + left), last = tileRect(bottom * columns + right)
        return ThumbnailRect(x: first.x, y: first.y, width: last.maxX - first.x, height: last.maxY - first.y)
    }

    /// Tiles inside `box` that show something
    private func texturedTiles(in box: ThumbnailRect) -> Int {
        var count = 0
        for row in (box.y / tileSize)..<((box.maxY + tileSize - 1) / tileSize) {
            for column in (box.x / tileSize)..<((box.maxX + tileSize - 1) / tileSize)
            where rangeNow[row * columns + column] > Int32(configuration.plainRange) {
                count += 1
            }
        }
        return count
    }

    private func isAcceptable(_ candidate: Candidate) -> Bool {
        candidate.valid >= configuration.minMotionTiles
            && Double(candidate.valid) >= configuration.minOverlapShare * Double(chosen.count)
    }

    /// The candidate with the lowest cost; one that continues a movement of the frame before
    /// wins a near tie
    private func choose(_ candidates: [Candidate]) -> Candidate? {
        var best: Candidate?
        var bestCost = Double.infinity
        for candidate in candidates where isAcceptable(candidate) {
            let cost = candidate.isPrior ? candidate.cost * (1 - configuration.priorPreference) : candidate.cost
            if cost < bestCost {
                bestCost = cost
                best = candidate
            }
        }
        return best
    }

    /// `residual` becomes the largest group of changed tiles that touch each other
    private func largestChangedGroup() {
        let count = kinds.count
        if visited.count != count {
            visited = [Bool](repeating: false, count: count)
        }
        for index in 0..<count {
            visited[index] = false
        }
        var best: [Int] = []
        for start in 0..<count where kinds[start] == .changed && !visited[start] {
            group.removeAll(keepingCapacity: true)
            group.append(start)
            visited[start] = true
            var next = 0
            while next < group.count {
                let tile = group[next]
                next += 1
                let column = tile % columns
                // left, right, above, below (without making an array of them for every tile)
                visitChanged(column > 0 ? tile - 1 : -1)
                visitChanged(column + 1 < columns ? tile + 1 : -1)
                visitChanged(tile - columns)
                visitChanged(tile + columns)
            }
            if group.count > best.count { best = group }
        }
        residual.removeAll(keepingCapacity: true)
        residual.append(contentsOf: best)
    }

    /// Adds a changed tile that was not visited yet to `group` (nothing for -1 or one outside)
    private func visitChanged(_ neighbour: Int) {
        guard neighbour >= 0, neighbour < kinds.count, !visited[neighbour], kinds[neighbour] == .changed else { return }
        visited[neighbour] = true
        group.append(neighbour)
    }

    /// The tiles of `residual` that show something in the current frame (a plain tile fits any
    /// plain place it may have come from), evenly thinned out to at most `motionSampleTiles`
    private func chooseSample() {
        chosen.removeAll(keepingCapacity: true)
        var textured = 0
        residualBox = .empty
        for index in residual {
            residualBox = residualBox.union(tileRect(index))
            if rangeNow[index] > Int32(configuration.plainRange) { textured += 1 }
        }
        residualTextured = textured
        let step = max(1, textured / max(1, configuration.motionSampleTiles))
        var counter = 0
        for index in residual where rangeNow[index] > Int32(configuration.plainRange) {
            if counter % step == 0 { chosen.append(index) }
            counter += 1
        }
    }

    /// How well a whole-pixel movement explains the sampled tiles
    private func score(_ candidate: inout Candidate, _ previous: LumaImage, _ current: LumaImage) {
        let dx = candidate.dx, dy = candidate.dy, width = width
        var cost = 0.0
        var matched = 0, valid = 0
        previous.pixels.withUnsafeBufferPointer { beforeBuffer in
            current.pixels.withUnsafeBufferPointer { nowBuffer in
                guard let before = beforeBuffer.baseAddress, let now = nowBuffer.baseAddress else { return }
                for index in chosen {
                    let rect = tileRect(index)
                    let right = rect.maxX, bottom = rect.maxY
                    guard rect.x - dx >= 0, rect.y - dy >= 0, right - dx <= width, bottom - dy <= height else {
                        continue
                    }
                    var sum: Int32 = 0, count: Int32 = 0
                    var y = rect.y
                    while y < bottom {
                        let row = y * width, source = (y - dy) * width - dx
                        var x = rect.x
                        while x < right {
                            let difference = Int32(now[row + x]) - Int32(before[source + x])
                            sum += difference < 0 ? -difference : difference
                            x += 1
                        }
                        count += Int32(rect.width)
                        y += 2
                    }
                    let mean = Double(sum) / Double(max(1, count))
                    valid += 1
                    // (a whole-pixel movement may be half a pixel off: the steps of the content count)
                    if mean <= configuration.matchBase + 2 * configuration.matchTexture * texture(ofTile: index) {
                        matched += 1
                    }
                    cost += min(mean, configuration.matchCostCap)
                }
            }
        }
        candidate.valid = valid
        candidate.matched = matched
        candidate.cost = valid > 0 ? cost / Double(valid) : .infinity
    }

    /// Movements that the row and column sums of the changed part suggest
    private func profileCandidates(_ previous: LumaImage, _ current: LumaImage) -> [Candidate] {
        var box = ThumbnailRect.empty
        for index in residual {
            box = box.union(tileRect(index))
        }
        // (each with its mirror: rows that repeat look the same moved half a row up or down)
        var vertical = shifts(previous, current, box: box, alongY: true)
        var horizontal = shifts(previous, current, box: box, alongY: false)
        for shift in vertical where !vertical.contains(-shift) {
            vertical.append(-shift)
        }
        for shift in horizontal where !horizontal.contains(-shift) {
            horizontal.append(-shift)
        }
        // along one axis each, and the best two of each together (a diagonal movement)
        var result: [Candidate] = []
        for dy in vertical {
            result.append(Candidate(dx: 0, dy: dy))
        }
        for dx in horizontal {
            result.append(Candidate(dx: dx, dy: 0))
        }
        for dy in vertical.prefix(2) {
            for dx in horizontal.prefix(2) {
                result.append(Candidate(dx: dx, dy: dy))
            }
        }
        return result
    }

    /// The best shifts of the profiles across `box` (rows when `alongY`, else columns): sums
    /// in `profileBands` bands, compared at a quarter of the resolution first, then at full
    private func shifts(_ previous: LumaImage, _ current: LumaImage, box: ThumbnailRect, alongY: Bool) -> [Int] {
        let length = alongY ? box.height : box.width
        let across = alongY ? box.width : box.height
        let bands = max(1, min(configuration.profileBands, across / MotionEstimator.bandWidth))
        guard length >= MotionEstimator.shortestProfile else { return [] }
        fillProfile(previous, box: box, alongY: alongY, bands: bands, into: &profilePrevious)
        fillProfile(current, box: box, alongY: alongY, bands: bands, into: &profileCurrent)

        let group = MotionEstimator.coarseGroup
        let coarseLength = length / group
        coarsen(profilePrevious, length: length, bands: bands, group: group, into: &coarsePrevious)
        coarsen(profileCurrent, length: length, bands: bands, group: group, into: &coarseCurrent)
        let minOverlap = max(group, Int(Double(coarseLength) * configuration.minOverlapShare))
        let reach = coarseLength - minOverlap
        guard reach > 0 else { return [] }
        var costs = [Double](repeating: .infinity, count: 2 * reach + 1)
        for shift in -reach...reach {
            costs[shift + reach] = profileCost(coarsePrevious, coarseCurrent, length: coarseLength, bands: bands,
                                               shift: shift)
        }
        // local minima of the coarse costs, refined at full resolution
        var minima: [(cost: Double, shift: Int)] = []
        let fullOverlap = max(MotionEstimator.shortestProfile, Int(Double(length) * configuration.minOverlapShare))
        for index in costs.indices {
            let cost = costs[index]
            if index > 0, costs[index - 1] < cost { continue }
            if index + 1 < costs.count, costs[index + 1] <= cost { continue }
            var bestShift = (index - reach) * group, bestCost = Double.infinity
            for shift in ((index - reach) * group - group)...((index - reach) * group + group)
            where abs(shift) <= length - fullOverlap {
                let fine = profileCost(profilePrevious, profileCurrent, length: length, bands: bands, shift: shift)
                if fine < bestCost {
                    bestCost = fine
                    bestShift = shift
                }
            }
            if bestCost.isFinite { minima.append((bestCost, bestShift)) }
        }
        // small movements at full resolution: a quarter of the resolution misses them on a page whose
        // lines repeat at about the same distance
        let near = min(configuration.fineProfileReach, length - fullOverlap)
        if near > 0 {
            var nearCosts = [Double](repeating: .infinity, count: 2 * near + 1)
            for shift in -near...near {
                nearCosts[shift + near] = profileCost(profilePrevious, profileCurrent, length: length, bands: bands,
                                                      shift: shift)
            }
            for index in nearCosts.indices {
                let cost = nearCosts[index]
                if index > 0, nearCosts[index - 1] < cost { continue }
                if index + 1 < nearCosts.count, nearCosts[index + 1] <= cost { continue }
                minima.append((cost, index - near))
            }
        }
        minima.sort { $0.cost < $1.cost || ($0.cost == $1.cost && abs($0.shift) < abs($1.shift)) }
        var result: [Int] = []
        for minimum in minima where minimum.shift != 0 && !result.contains(minimum.shift) {
            result.append(minimum.shift)
            if result.count == configuration.profileCandidates { break }
        }
        return result
    }

    private func fillProfile(_ image: LumaImage, box: ThumbnailRect, alongY: Bool, bands: Int, into profile: inout [Int32]) {
        let length = alongY ? box.height : box.width
        let count = length * bands
        if profile.count < count {
            profile = [Int32](repeating: 0, count: count)
        }
        let width = width
        image.pixels.withUnsafeBufferPointer { pixelBuffer in
            // (every other pixel across: enough for sums of a band)
            profile.withUnsafeMutableBufferPointer { sumBuffer in
                guard let sums = sumBuffer.baseAddress else { return }
                var index = 0
                while index < count {
                    sums[index] = 0
                    index += 1
                }
                guard let pixels = pixelBuffer.baseAddress else { return }
                let left = box.x, top = box.y, right = box.maxX, bottom = box.maxY
                if alongY {
                    let bandWidth = box.width / bands
                    var y = top
                    while y < bottom {
                        let row = y * width
                        var band = 0
                        while band < bands {
                            let start = left + band * bandWidth
                            let end = band == bands - 1 ? right : start + bandWidth
                            var sum: Int32 = 0
                            var x = start
                            while x < end {
                                sum += Int32(pixels[row + x])
                                x += 2
                            }
                            sums[band * length + y - top] = sum
                            band += 1
                        }
                        y += 1
                    }
                } else {
                    let bandHeight = box.height / bands
                    var band = 0
                    while band < bands {
                        let start = top + band * bandHeight
                        let end = band == bands - 1 ? bottom : start + bandHeight
                        let line = band * length - left
                        var y = start
                        while y < end {
                            let row = y * width
                            var x = left
                            while x < right {
                                sums[line + x] += Int32(pixels[row + x])
                                x += 1
                            }
                            y += 2
                        }
                        band += 1
                    }
                }
            }
        }
    }

    private func coarsen(_ profile: [Int32], length: Int, bands: Int, group: Int, into coarse: inout [Int32]) {
        let coarseLength = length / group
        if coarse.count < coarseLength * bands {
            coarse = [Int32](repeating: 0, count: coarseLength * bands)
        }
        profile.withUnsafeBufferPointer { profileBuffer in
            coarse.withUnsafeMutableBufferPointer { coarseBuffer in
                guard let profile = profileBuffer.baseAddress, let coarse = coarseBuffer.baseAddress else { return }
                var band = 0
                while band < bands {
                    var index = 0
                    while index < coarseLength {
                        var sum: Int32 = 0
                        var inner = 0
                        while inner < group {
                            sum += profile[band * length + index * group + inner]
                            inner += 1
                        }
                        coarse[band * coarseLength + index] = sum
                        index += 1
                    }
                    band += 1
                }
            }
        }
    }

    /// Mean difference of two profiles when the second is shifted by `shift`
    private func profileCost(_ first: [Int32], _ second: [Int32], length: Int, bands: Int, shift: Int) -> Double {
        let start = max(0, -shift), end = min(length, length - shift)
        guard end > start else { return .infinity }
        var sum = 0.0
        first.withUnsafeBufferPointer { firstBuffer in
            second.withUnsafeBufferPointer { secondBuffer in
                // (plain loops over pointers: this runs for many shifts per frame, also in builds
                // without optimization)
                guard let first = firstBuffer.baseAddress, let second = secondBuffer.baseAddress else { return }
                var band = 0
                while band < bands {
                    let base = band * length
                    var bandSum: Int64 = 0
                    var index = start
                    while index < end {
                        let difference = first[base + index] - second[base + index + shift]
                        bandSum += Int64(difference < 0 ? -difference : difference)
                        index += 1
                    }
                    sum += Double(bandSum)
                    band += 1
                }
            }
        }
        return sum / Double((end - start) * bands)
    }

    /// The movement to a fraction of a pixel: a parabola through the squared differences at
    /// the best whole-pixel movement and its neighbours, along each axis
    private func refine(_ candidate: Candidate, _ previous: LumaImage, _ current: LumaImage) -> (Double, Double) {
        var tiles: [Int] = []
        let dx0 = candidate.dx, dy0 = candidate.dy
        let step = max(1, chosen.count / configuration.refineTiles)
        for index in stride(from: 0, to: chosen.count, by: step).map({ chosen[$0] }) {
            let rect = tileRect(index)
            // room for a step of three pixels in every direction
            guard rect.x - dx0 - 3 >= 0, rect.y - dy0 - 3 >= 0, rect.maxX - dx0 + 3 <= width,
                  rect.maxY - dy0 + 3 <= height else { continue }
            tiles.append(index)
        }
        guard !tiles.isEmpty else { return (Double(dx0), Double(dy0)) }
        var dx = dx0, dy = dy0
        var center = squaredDifference(tiles, dx: dx, dy: dy, previous, current)
        var left = 0.0, right = 0.0, up = 0.0, down = 0.0
        for _ in 0..<MotionEstimator.refineSteps {
            left = squaredDifference(tiles, dx: dx - 1, dy: dy, previous, current)
            right = squaredDifference(tiles, dx: dx + 1, dy: dy, previous, current)
            up = squaredDifference(tiles, dx: dx, dy: dy - 1, previous, current)
            down = squaredDifference(tiles, dx: dx, dy: dy + 1, previous, current)
            let lowest = min(left, right, up, down)
            let reach = MotionEstimator.refineSteps - 1
            guard lowest < center, abs(dx - dx0) < reach, abs(dy - dy0) < reach else { break }
            if lowest == left {
                dx -= 1
            } else if lowest == right {
                dx += 1
            } else if lowest == up {
                dy -= 1
            } else {
                dy += 1
            }
            center = lowest
        }
        var fineX = Double(dx) + MotionEstimator.vertex(left, center, right)
        var fineY = Double(dy) + MotionEstimator.vertex(up, center, down)
        // (no movement across the scrolling direction is invented from noise)
        if abs(fineX) < configuration.subpixelSnap { fineX = 0 }
        if abs(fineY) < configuration.subpixelSnap { fineY = 0 }
        return (fineX, fineY)
    }

    /// Where a parabola through (-1, a), (0, b), (1, c) has its lowest point, within ±½
    static func vertex(_ a: Double, _ b: Double, _ c: Double) -> Double {
        let curvature = a - 2 * b + c
        guard curvature > 0 else { return 0 }
        return min(0.5, max(-0.5, (a - c) / (2 * curvature)))
    }

    private func squaredDifference(_ tiles: [Int], dx: Int, dy: Int, _ previous: LumaImage, _ current: LumaImage) -> Double {
        let width = width, cap = Int32(configuration.matchCostCap * configuration.matchCostCap)
        var sum: Int64 = 0, count = 0
        previous.pixels.withUnsafeBufferPointer { beforeBuffer in
            current.pixels.withUnsafeBufferPointer { nowBuffer in
                guard let before = beforeBuffer.baseAddress, let now = nowBuffer.baseAddress else { return }
                for index in tiles {
                    let rect = tileRect(index)
                    let right = rect.maxX, bottom = rect.maxY
                    var y = rect.y
                    while y < bottom {
                        let row = y * width, source = (y - dy) * width - dx
                        var x = rect.x
                        while x < right {
                            let difference = Int32(now[row + x]) - Int32(before[source + x])
                            let squared = difference * difference
                            sum += Int64(squared < cap ? squared : cap)
                            x += 1
                        }
                        count += rect.width
                        y += 2
                    }
                }
            }
        }
        return Double(sum) / Double(max(1, count))
    }

    /// Marks the changed tiles that the frame before explains as they are (within the tolerance
    /// of a match) as still. Returns their number.
    private func labelStill(_ previous: LumaImage, _ current: LumaImage) -> Int {
        let shift = BilinearShift(dx: 0, dy: 0)
        let width = width
        var count = 0
        previous.pixels.withUnsafeBufferPointer { before in
            current.pixels.withUnsafeBufferPointer { now in
                for tile in kinds.indices where kinds[tile] == .changed {
                    let rect = tileRect(tile)
                    let mean = tileDifference(rect, shift: shift, before, now, width: width)
                    if mean <= configuration.matchBase + configuration.matchTexture * texture(ofTile: tile) {
                        kinds[tile] = .drifted
                        count += 1
                    }
                }
            }
        }
        return count
    }

    /// Marks the changed tiles that `previous` moved by (dx, dy) explains. Returns their number.
    private func labelMoved(_ index: Int, dx: Double, dy: Double, _ previous: LumaImage, _ current: LumaImage) -> Int {
        let shift = BilinearShift(dx: dx, dy: dy)
        let width = width
        var count = 0
        previous.pixels.withUnsafeBufferPointer { before in
            current.pixels.withUnsafeBufferPointer { now in
                for tile in kinds.indices where kinds[tile] == .changed {
                    let rect = tileRect(tile)
                    // the source of every pixel and its neighbour for the interpolation
                    guard rect.x - shift.whole.x - 1 >= 0, rect.y - shift.whole.y - 1 >= 0,
                          rect.maxX - shift.whole.x <= width, rect.maxY - shift.whole.y <= height else { continue }
                    let mean = tileDifference(rect, shift: shift, before, now, width: width)
                    if mean <= configuration.matchBase + configuration.matchTexture * texture(ofTile: tile) {
                        kinds[tile] = .moved
                        motionIndex[tile] = Int8(index)
                        count += 1
                    }
                }
            }
        }
        return count
    }

    /// Marks the changed tiles along the edge where content moved by (dx, dy) comes into view:
    /// from the edge of what moved outwards, across rows (columns) of plain tiles, up to a row
    /// (column) that mostly stays in place (a bar) or the edge of the picture
    private func labelEntered(_ index: Int, dx: Double, dy: Double) {
        var left = columns, top = rows, right = -1, bottom = -1
        for tile in kinds.indices where motionIndex[tile] == Int8(index) {
            let column = tile % columns, row = tile / columns
            left = min(left, column)
            right = max(right, column)
            top = min(top, row)
            bottom = max(bottom, row)
        }
        guard right >= left else { return }
        let snap = configuration.subpixelSnap
        if dy > snap {
            markEntered(index, lines: stride(from: top + 1, through: 0, by: -1), across: left...right, alongY: true)
        } else if dy < -snap {
            markEntered(index, lines: stride(from: bottom - 1, through: rows - 1, by: 1), across: left...right, alongY: true)
        }
        if dx > snap {
            markEntered(index, lines: stride(from: left + 1, through: 0, by: -1), across: top...bottom, alongY: false)
        } else if dx < -snap {
            markEntered(index, lines: stride(from: right - 1, through: columns - 1, by: 1), across: top...bottom,
                        alongY: false)
        }
    }

    private func markEntered(_ index: Int, lines: StrideThrough<Int>, across: ClosedRange<Int>, alongY: Bool) {
        var first = true
        for line in lines {
            var still = 0
            for position in across {
                let tile = alongY ? line * columns + position : position * columns + line
                if kinds[tile] == .still || kinds[tile] == .drifted { still += 1 }
            }
            // (the first line overlaps what moved and may well hold still tiles)
            if !first, still * 2 >= across.count { return }
            first = false
            for position in across {
                let tile = alongY ? line * columns + position : position * columns + line
                if kinds[tile] == .changed {
                    kinds[tile] = .entered
                    motionIndex[tile] = Int8(index)
                }
            }
        }
    }

    /// Moves the upper and lower edges of a moving area to the pixel row: the first row beyond
    /// which the picture stays while the content moves is where something that does not scroll
    /// begins (a bar)
    private func refineEdges(_ area: inout ThumbnailRect, dx: Double, dy: Double, _ previous: LumaImage,
                             _ current: LumaImage) -> Int {
        let shift = BilinearShift(dx: dx, dy: dy)
        var refined = 0
        if abs(dy) > configuration.subpixelSnap {
            let top = edge(from: area.y + tileSize - 1, to: area.y - tileSize, step: -1, area: area, alongY: true,
                           shift: shift, previous, current)
            let bottom = edge(from: area.maxY - tileSize, to: area.maxY + tileSize - 1, step: 1, area: area,
                              alongY: true, shift: shift, previous, current)
            let newTop = top.map { $0 + 1 } ?? area.y, newBottom = bottom ?? area.maxY
            if newBottom > newTop {
                area = ThumbnailRect(x: area.x, y: newTop, width: area.width, height: newBottom - newTop)
                if top != nil { refined |= FrameMotion.top }
                if bottom != nil { refined |= FrameMotion.bottom }
            }
        }
        // (Columns are not refined: where content slides sideways, a stroke of a letter can stay
        // in place by chance, and the bars that end a page sideways are the edges of the frame.)
        return refined
    }

    /// The first line (row when `alongY`, else column) from `start` towards `end` that stays
    /// in place rather than moving with the content, nil when there is none
    private func edge(from start: Int, to end: Int, step: Int, area: ThumbnailRect, alongY: Bool, shift: BilinearShift,
                      _ previous: LumaImage, _ current: LumaImage) -> Int? {
        let limit = alongY ? height : width
        var line = start
        while step < 0 ? line >= end : line <= end {
            defer { line += step }
            guard line >= 0, line < limit else { continue }
            let (still, moving) = lineDifferences(line, area: area, alongY: alongY, shift: shift, previous, current)
            // (and a real boundary looks different from the line just inside of it)
            if still <= configuration.matchBase, still + configuration.edgeMargin < moving,
               lineContrast(line, inside: line - step, area: area, alongY: alongY, current) >= configuration.edgeContrast {
                return line
            }
        }
        return nil
    }

    /// Mean difference between two rows (or columns) of the current frame across the area
    private func lineContrast(_ line: Int, inside other: Int, area: ThumbnailRect, alongY: Bool, _ current: LumaImage) -> Double {
        let limit = alongY ? height : width
        guard other >= 0, other < limit else { return 0 }
        let width = width
        var sum = 0, count = 0
        current.pixels.withUnsafeBufferPointer { now in
            let positions = alongY ? stride(from: area.x, to: area.maxX, by: 2) : stride(from: area.y, to: area.maxY, by: 2)
            for position in positions {
                let first = alongY ? line * width + position : position * width + line
                let second = alongY ? other * width + position : position * width + other
                sum += abs(Int(now[first]) - Int(now[second]))
                count += 1
            }
        }
        return Double(sum) / Double(max(1, count))
    }

    /// Mean difference of one row (or column) of the area to the same place in the frame before,
    /// and to where the movement says it came from
    private func lineDifferences(_ line: Int, area: ThumbnailRect, alongY: Bool, shift: BilinearShift,
                                 _ previous: LumaImage, _ current: LumaImage) -> (Double, Double) {
        let width = width
        var still = 0, moving = 0, count = 0, movingCount = 0
        previous.pixels.withUnsafeBufferPointer { before in
            current.pixels.withUnsafeBufferPointer { now in
                let positions = alongY ? stride(from: area.x, to: area.maxX, by: 2) : stride(from: area.y, to: area.maxY, by: 2)
                for position in positions {
                    let x = alongY ? position : line, y = alongY ? line : position
                    let value = Int(now[y * width + x])
                    still += abs(value - Int(before[y * width + x]))
                    count += 1
                    let sourceX = x - shift.whole.x, sourceY = y - shift.whole.y
                    guard sourceX - 1 >= 0, sourceY - 1 >= 0, sourceX < width, sourceY < height else { continue }
                    let interpolated = shift.sample(before, at: sourceY * width + sourceX, rowLength: width)
                    moving += abs(value * BilinearShift.one - interpolated)
                    movingCount += 1
                }
            }
        }
        let stillMean = Double(still) / Double(max(1, count))
        let movingMean = movingCount > 0 ? Double(moving) / Double(movingCount * BilinearShift.one) : .infinity
        return (stillMean, movingMean)
    }
}

/// Sampling of a picture moved by a fraction of a pixel, in integer arithmetic: the value at
/// (x - dx, y - dy) is mixed from the four pixels around it, weights in 1/16
struct BilinearShift {
    static let one = 256
    /// the pixel at (x, y) - whole lies at or right/below the point that is sampled
    let whole: (x: Int, y: Int)
    private let weightLeft: Int
    private let weightUp: Int

    init(dx: Double, dy: Double) {
        // (x - dx) = (x - wholeX) + (1 - fraction) - 1 with whole = floor(dx)
        let floorX = floor(dx), floorY = floor(dy)
        whole = (Int(floorX), Int(floorY))
        weightLeft = Int(((dx - floorX) * 16).rounded())
        weightUp = Int(((dy - floorY) * 16).rounded())
    }

    /// Value × `one` at the point that lies the fractions left of and above `index`
    func sample(_ pixels: UnsafeBufferPointer<UInt8>, at index: Int, rowLength: Int) -> Int {
        sample(pixels.baseAddress!, at: index, rowLength: rowLength)
    }

    /// The same for the pixels at `pixels`
    func sample(_ pixels: UnsafePointer<UInt8>, at index: Int, rowLength: Int) -> Int {
        let wx = weightLeft, wy = weightUp
        if wx == 0, wy == 0 { return Int(pixels[index]) * BilinearShift.one }
        let here = Int(pixels[index]), left = wx > 0 ? Int(pixels[index - 1]) : here
        let lower = (16 - wx) * here + wx * left
        guard wy > 0 else { return lower * 16 }
        let above = index - rowLength
        let upHere = Int(pixels[above]), upLeft = wx > 0 ? Int(pixels[above - 1]) : upHere
        let upper = (16 - wx) * upHere + wx * upLeft
        return (16 - wy) * lower + wy * upper
    }
}
