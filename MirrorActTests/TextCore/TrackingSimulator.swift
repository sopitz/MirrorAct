// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@testable import MirrorAct

// A deterministic stand-in for the screen of a phone, made for measuring `OverlayTracker`
// (see TrackingBench.swift). Foundation only, whole numbers for everything that draws, no clock
// and no system randomness: the same seed gives the same frames on every run and platform.
//
// How a picture comes about
// -------------------------
// A scenario owns a few *sprites*: rectangular pieces of picture at frame resolution that are
// drawn once – a tall page of text, a title bar, a pop-up – together with the ground truth of
// their text (`SimLine`, `SimParagraph`). Every tick of 1/60 s has a *scene*: layers from back
// to front, each showing one sprite at a whole-pixel position, cut to a clip rectangle. Scrolling
// is a layer whose position changes; a pop-up is a layer that is there for a while; a video is a
// layer whose sprite changes. The ground truth of a frame follows from the same list: a line is
// where its layer puts it, and it is visible where its layer paints and no layer above does.
//
// On top of that comes what a video link does to the picture:
// - loss of detail while content moves fast (`SimLayer.loss`): blocks of 8 × 8 thumbnail cells
//   show the content a few pixels off (a wrong motion vector) or without its fine detail (every
//   cell flat, blurred with its neighbours). It grows with the speed and fades within a few
//   frames after the motion stops; those frames are sent although nothing moves any more.
// - slight noise, different in every picture, with the grain of the thumbnail cells.
//
// Thumbnails
// ----------
// `frame(at:)` composes the frame at full resolution exactly as described; reducing it with
// `LumaImage.downsampled` is the definition of the thumbnail. Doing that for every frame costs
// more than a tenth of a second in a debug build, so `thumbnail(at:)` gets the same pixels
// another way: every sprite is reduced once with `LumaImage.downsampled` for each position it can
// have relative to the grid of thumbnail cells (`SimSprite.reduced`), and frames are copied
// together from these. Cells that a layer paints only a part of (its edge lies between the lines
// of the cell grid: a picture inside a page that scrolls by an odd number of pixels) are composed
// pixel by pixel instead. Both ways give identical bytes;
// `TrackingBenchTests.testThumbnailsAreReducedFrames` checks that for every scenario.

// MARK: - Random numbers

/// SplitMix64: small, fast and the same everywhere
struct SimRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< bound
    mutating func below(_ bound: Int) -> Int {
        precondition(bound > 0, "SimRandom: empty range")
        return Int((next() >> 33) % UInt64(bound))
    }

    /// low ... high
    mutating func int(_ low: Int, _ high: Int) -> Int {
        low + below(high - low + 1)
    }

    mutating func chance(_ percent: Int) -> Bool {
        below(100) < percent
    }

    /// A generator of its own for one purpose, so that drawing more numbers for one thing does
    /// not change another
    func branch(_ purpose: UInt64) -> SimRandom {
        var mixer = SimRandom(seed: state ^ (purpose &* 0xD6E8_FEB8_6659_FD93))
        return SimRandom(seed: mixer.next())
    }
}

// MARK: - Geometry in whole pixels

enum SimMath {
    /// rounds towards minus infinity (`b` > 0)
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        -floorDiv(-a, b)
    }

    /// 0 ..< b also for negative `a`
    static func mod(_ a: Int, _ b: Int) -> Int {
        let rest = a % b
        return rest < 0 ? rest + b : rest
    }
}

struct SimRect: Equatable, Hashable {
    var x = 0
    var y = 0
    var width = 0
    var height = 0

    init() {}

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// the smallest rectangle of whole pixels around `rect`
    init(covering rect: CGRect) {
        guard !rect.isNull, !rect.isInfinite, rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite,
              rect.maxY.isFinite else { return }
        x = Int(rect.minX.rounded(.down))
        y = Int(rect.minY.rounded(.down))
        width = Int(rect.maxX.rounded(.up)) - x
        height = Int(rect.maxY.rounded(.up)) - y
    }

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var isEmpty: Bool { width <= 0 || height <= 0 }
    var area: Int { isEmpty ? 0 : width * height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    func offsetBy(dx: Int, dy: Int) -> SimRect {
        SimRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// empty when the two do not overlap
    func intersection(_ other: SimRect) -> SimRect {
        let left = max(x, other.x), top = max(y, other.y)
        let right = min(maxX, other.maxX), bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return SimRect() }
        return SimRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// the smallest rectangle around both; an empty one does not count
    func union(_ other: SimRect) -> SimRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let left = min(x, other.x), top = min(y, other.y)
        return SimRect(x: left, y: top, width: max(maxX, other.maxX) - left, height: max(maxY, other.maxY) - top)
    }

    func contains(_ other: SimRect) -> Bool {
        other.x >= x && other.y >= y && other.maxX <= maxX && other.maxY <= maxY
    }

    /// What is left of `area` when `covers` lie on top of it
    static func uncovered(_ area: SimRect, by covers: [SimRect]) -> SimRemainder {
        guard !area.isEmpty else { return SimRemainder(area: 0, box: SimRect()) }
        var parts: [SimRect] = []
        for cover in covers {
            let part = cover.intersection(area)
            if !part.isEmpty { parts.append(part) }
        }
        guard !parts.isEmpty else { return SimRemainder(area: area.area, box: area) }
        // the edges of the covers cut the area into a grid; every field of it is covered or not
        var xs = [area.x, area.maxX], ys = [area.y, area.maxY]
        for part in parts {
            xs.append(part.x)
            xs.append(part.maxX)
            ys.append(part.y)
            ys.append(part.maxY)
        }
        xs.sort()
        ys.sort()
        var total = 0
        var box = SimRect()
        for row in 0..<(ys.count - 1) where ys[row + 1] > ys[row] {
            for column in 0..<(xs.count - 1) where xs[column + 1] > xs[column] {
                let left = xs[column], top = ys[row]
                var covered = false
                for part in parts where part.x <= left && left < part.maxX && part.y <= top && top < part.maxY {
                    covered = true
                    break
                }
                if !covered {
                    let field = SimRect(x: left, y: top, width: xs[column + 1] - left, height: ys[row + 1] - top)
                    total += field.area
                    box = box.union(field)
                }
            }
        }
        return SimRemainder(area: total, box: box)
    }
}

/// What can be seen of a rectangle that is partly covered
struct SimRemainder {
    /// number of pixels
    var area: Int
    /// the smallest rectangle around them
    var box: SimRect
}

// MARK: - Text that looks like text

/// A stroke of a glyph in sixteenths of the text size, from the top left corner of the line
struct SimStroke {
    var left: Int
    var right: Int
    var top: Int
    var bottom: Int
}

struct SimGlyph {
    /// to the next glyph, in sixteenths of the text size
    var advance: Int
    var strokes: [SimStroke]
}

/// A made-up typeface: every letter and digit is a fixed set of stems and bars, so that the same
/// text always looks the same and different texts look different. It has the features that
/// matter in a thumbnail: lines, word gaps, ascenders and descenders, strokes of varying density.
enum SimFont {
    static let spaceAdvance = 5
    /// "a"…"z", "A"…"Z", "0"…"9"
    static let glyphs: [SimGlyph] = makeGlyphs()
    /// everything else (punctuation): a dot on the baseline
    static let dot = SimGlyph(advance: 4, strokes: [SimStroke(left: 0, right: 2, top: 10, bottom: 12)])

    static func glyph(for byte: UInt8) -> SimGlyph {
        switch byte {
        case 97...122: return glyphs[Int(byte) - 97]
        case 65...90: return glyphs[Int(byte) - 65 + 26]
        case 48...57: return glyphs[Int(byte) - 48 + 52]
        default: return dot
        }
    }

    private static func makeGlyphs() -> [SimGlyph] {
        var random = SimRandom(seed: 0x466F_6E74_2031_3631)
        var glyphs: [SimGlyph] = []
        for index in 0..<62 {
            let isLower = index < 26, isDigit = index >= 52
            let top = isLower ? 5 : 2
            let stems = isDigit ? 2 : (isLower ? [1, 2, 2, 2, 3][random.below(5)] : [2, 2, 3][random.below(3)])
            let pitch = isLower ? 5 : 6
            var width = (stems - 1) * pitch + 2
            var strokes: [SimStroke] = []
            for stem in 0..<stems {
                var stemTop = top, stemBottom = 12
                if isLower {
                    let zone = random.below(100)
                    if zone < 25 {
                        stemTop = 1      // ascender
                    } else if zone < 40 {
                        stemBottom = 15  // descender
                    }
                }
                strokes.append(SimStroke(left: stem * pitch, right: stem * pitch + 2, top: stemTop, bottom: stemBottom))
            }
            if stems == 1 {
                if random.chance(50) {
                    strokes.append(SimStroke(left: 0, right: 2, top: 1, bottom: 3))        // a dot above
                } else {
                    strokes.append(SimStroke(left: 2, right: 5, top: top, bottom: top + 2)) // a flag
                    width = 5
                }
            } else {
                let middle = (top + 12) / 2
                var bars = 0
                if random.chance(55) {
                    strokes.append(SimStroke(left: 0, right: width, top: top, bottom: top + 2))
                    bars += 1
                }
                if random.chance(40) {
                    strokes.append(SimStroke(left: 0, right: width, top: middle - 1, bottom: middle + 1))
                    bars += 1
                }
                if random.chance(55) || bars == 0 {
                    strokes.append(SimStroke(left: 0, right: width, top: 10, bottom: 12))
                }
            }
            glyphs.append(SimGlyph(advance: width + 2, strokes: strokes))
        }
        return glyphs
    }

    /// thicker strokes
    static func boldExtra(size: Int) -> Int {
        max(1, size / 12)
    }

    /// Width in pixels of `text` set in `size` pixels (the height of a line)
    static func width(of text: String, size: Int, bold: Bool = false) -> Int {
        var units = 0
        for byte in text.utf8 {
            units += byte == 32 ? spaceAdvance : glyph(for: byte).advance
        }
        guard units > 0 else { return 0 }
        return ((units - 2) * size + 15) / 16 + (bold ? boldExtra(size: size) : 0)
    }
}

/// Words nobody has used before: every line of text of a scenario is unique unless a scenario
/// repeats one on purpose
final class SimWords {
    private var random: SimRandom
    private var used: Set<String> = []

    init(random: SimRandom) {
        self.random = random
    }

    func word(minLength: Int = 3, maxLength: Int = 9, capitalized: Bool = false) -> String {
        while true {
            let length = random.int(minLength, maxLength)
            var bytes: [UInt8] = []
            for position in 0..<length {
                let letter = UInt8(random.below(26))
                bytes.append((position == 0 && capitalized ? 65 : 97) + letter)
            }
            let word = String(decoding: bytes, as: UTF8.self)
            if used.insert(word).inserted { return word }
        }
    }

    /// `text` as a recognizer might read it another time: one letter differs
    func misreading(of text: String) -> String {
        var bytes = Array(text.utf8)
        let letters = bytes.indices.filter { bytes[$0] >= 97 && bytes[$0] <= 122 }
        guard !letters.isEmpty else { return text + "." }
        while true {
            let position = letters[random.below(letters.count)]
            let original = bytes[position]
            bytes[position] = 97 + UInt8(random.below(26))
            let changed = String(decoding: bytes, as: UTF8.self)
            if bytes[position] != original, used.insert(changed).inserted { return changed }
            bytes[position] = original
        }
    }

    /// A time, a price, a count: nothing to translate
    func number() -> String {
        switch random.below(3) {
        case 0: return "\(random.int(0, 23)):\(random.int(10, 59))"
        case 1: return "\(random.int(1, 99)),\(random.int(10, 99))"
        default: return "\(random.int(2, 999))"
        }
    }
}

// MARK: - Sprites

/// One line of text of a sprite with what is true about it
struct SimLine {
    var text: String
    /// what the recognition sometimes reads instead (one letter differs)
    var alternate: String
    /// in pixels of the sprite
    var rect: SimRect
    var paragraph: Int
    /// has letters; the caller of the tracker drops everything else
    var isTranslatable: Bool
}

/// Lines that the recognition returns as one block when it sees all of them
struct SimParagraph {
    var lines: [Int]
    /// the lines joined by spaces, as `TextLayout.blocks` does
    var text: String
    var rect: SimRect
    var background: UInt8
    var foreground: UInt8
    var isTranslatable: Bool
}

/// Brightness values of sprites stay inside this range, so that noise never wraps around
enum SimLevel {
    static let darkest = 12
    static let brightest = 243

    static func clamped(_ value: Int) -> UInt8 {
        UInt8(max(darkest, min(brightest, value)))
    }
}

/// A sprite reduced by the thumbnail factor for one position relative to the grid of thumbnail
/// cells: cell (i, j) is the mean of the sprite pixels from (i·scale + phaseX, j·scale + phaseY).
/// Made band by band when first needed, because a page is tall and only parts of it are shown.
final class SimReducedCopy {
    static let bandRows = 64

    let width: Int
    let height: Int
    var pixels: [UInt8]
    var isBandReady: [Bool]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height)
        isBandReady = [Bool](repeating: false, count: (height + SimReducedCopy.bandRows - 1) / SimReducedCopy.bandRows)
    }
}

/// A rectangular piece of picture at frame resolution with the ground truth of its text
final class SimSprite {
    let width: Int
    let height: Int
    private(set) var pixels: [UInt8]
    private(set) var lines: [SimLine] = []
    private(set) var paragraphs: [SimParagraph] = []
    /// position in `SimScenario.sprites`
    fileprivate(set) var index = -1

    /// paragraphs from top to bottom and the height of the tallest: for finding those of an area
    private var paragraphOrder: [Int] = []
    private var tallestParagraph = 0
    private var reducedCopies: [Int: SimReducedCopy] = [:]
    private var isSealed = false

    init(width: Int, height: Int, level: UInt8) {
        precondition(width > 0 && height > 0, "SimSprite: empty")
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: level, count: width * height)
    }

    var bounds: SimRect { SimRect(x: 0, y: 0, width: width, height: height) }

    // MARK: Drawing

    func fill(_ rect: SimRect, level: UInt8) {
        precondition(!isSealed, "SimSprite: already in use")
        let area = rect.intersection(bounds)
        guard !area.isEmpty else { return }
        let stride = width
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for row in area.y..<area.maxY {
                (base + row * stride + area.x).update(repeating: level, count: area.width)
            }
        }
    }

    /// Brightness changing evenly from left to right and from top to bottom
    func fillGradient(_ rect: SimRect, from first: Int, to last: Int, down: Int) {
        let area = rect.intersection(bounds)
        guard !area.isEmpty else { return }
        // the same ramp for a few rows at a time, shifted a little further down
        var ramp = [UInt8](repeating: 0, count: area.width)
        var row = area.y
        while row < area.maxY {
            let shift = down * (row - area.y) / max(1, area.height)
            for column in 0..<area.width {
                ramp[column] = SimLevel.clamped(first + (last - first) * column / max(1, area.width - 1) + shift)
            }
            let rows = min(4, area.maxY - row)
            copyRows(ramp, x: area.x, y: row, rows: rows)
            row += rows
        }
    }

    /// Patches of different brightness, as a photo looks in a thumbnail
    func fillTexture(_ rect: SimRect, base: Int, spread: Int, random: inout SimRandom) {
        let area = rect.intersection(bounds)
        guard !area.isEmpty else { return }
        fill(area, level: SimLevel.clamped(base))
        let patches = max(8, area.area / 900)
        for _ in 0..<patches {
            let patchWidth = random.int(4, max(5, area.width / 6)), patchHeight = random.int(4, max(5, area.height / 5))
            let patch = SimRect(x: area.x + random.below(area.width), y: area.y + random.below(area.height),
                                width: patchWidth, height: patchHeight).intersection(area)
            fill(patch, level: SimLevel.clamped(base + random.int(-spread, spread)))
        }
    }

    private func copyRows(_ row: [UInt8], x: Int, y: Int, rows: Int) {
        precondition(!isSealed, "SimSprite: already in use")
        let stride = width
        pixels.withUnsafeMutableBufferPointer { buffer in
            row.withUnsafeBufferPointer { source in
                guard let base = buffer.baseAddress, let from = source.baseAddress else { return }
                for offset in 0..<rows {
                    (base + (y + offset) * stride + x).update(from: from, count: row.count)
                }
            }
        }
    }

    /// Draws `text` with its top left corner at (x, y); `size` is the height of the line in pixels
    func drawText(_ text: String, x: Int, y: Int, size: Int, level: UInt8, bold: Bool = false) {
        precondition(!isSealed, "SimSprite: already in use")
        let extra = bold ? SimFont.boldExtra(size: size) : 0
        let stride = width, limitX = width, limitY = height
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var pen = 0
            for byte in text.utf8 {
                if byte == 32 {
                    pen += SimFont.spaceAdvance
                    continue
                }
                let glyph = SimFont.glyph(for: byte)
                for stroke in glyph.strokes {
                    let left = max(0, x + (pen + stroke.left) * size / 16)
                    let right = min(limitX, x + ((pen + stroke.right) * size + 15) / 16 + extra)
                    let top = max(0, y + stroke.top * size / 16)
                    let bottom = min(limitY, min(y + size, y + (stroke.bottom * size + 15) / 16 + extra))
                    guard right > left, bottom > top else { continue }
                    for row in top..<bottom {
                        (base + row * stride + left).update(repeating: level, count: right - left)
                    }
                }
                pen += glyph.advance
            }
        }
    }

    // MARK: Ground truth

    /// Records a line of text (drawn by the caller) and returns its index
    @discardableResult
    func addLine(_ text: String, alternate: String, rect: SimRect) -> Int {
        lines.append(SimLine(text: text, alternate: alternate, rect: rect, paragraph: -1,
                             isTranslatable: TextLayout.isTranslatable(text)))
        return lines.count - 1
    }

    /// Makes a paragraph of lines recorded before, top to bottom
    func addParagraph(lines members: [Int], background: UInt8, foreground: UInt8) {
        guard !members.isEmpty else { return }
        var rect = SimRect()
        var texts: [String] = []
        for member in members {
            lines[member].paragraph = paragraphs.count
            rect = rect.union(lines[member].rect)
            texts.append(lines[member].text)
        }
        let text = texts.joined(separator: " ")
        paragraphs.append(SimParagraph(lines: members, text: text, rect: rect, background: background,
                                       foreground: foreground, isTranslatable: TextLayout.isTranslatable(text)))
    }

    /// Draws a line and records it as a paragraph of its own
    func addText(_ text: String, alternate: String, x: Int, y: Int, size: Int, level: UInt8, background: UInt8,
                 bold: Bool = false) {
        drawText(text, x: x, y: y, size: size, level: level, bold: bold)
        let rect = SimRect(x: x, y: y, width: SimFont.width(of: text, size: size, bold: bold), height: size)
        addParagraph(lines: [addLine(text, alternate: alternate, rect: rect)], background: background, foreground: level)
    }

    /// Copies a part of another sprite including the paragraphs that reach into it. Their lines
    /// keep their place relative to the picture, so some may lie outside of this sprite.
    func copy(from source: SimSprite, rect: SimRect, toX: Int, toY: Int) {
        precondition(!isSealed, "SimSprite: already in use")
        let area = rect.intersection(source.bounds)
        let target = SimRect(x: toX + area.x - rect.x, y: toY + area.y - rect.y, width: area.width, height: area.height)
            .intersection(bounds)
        guard !target.isEmpty else { return }
        let dx = toX - rect.x, dy = toY - rect.y
        let stride = width, sourceStride = source.width
        pixels.withUnsafeMutableBufferPointer { buffer in
            source.pixels.withUnsafeBufferPointer { from in
                guard let base = buffer.baseAddress, let fromBase = from.baseAddress else { return }
                for row in target.y..<target.maxY {
                    (base + row * stride + target.x)
                        .update(from: fromBase + (row - dy) * sourceStride + target.x - dx, count: target.width)
                }
            }
        }
        for paragraph in source.paragraphs where !paragraph.rect.intersection(area).isEmpty {
            var members: [Int] = []
            for member in paragraph.lines {
                let line = source.lines[member]
                members.append(addLine(line.text, alternate: line.alternate, rect: line.rect.offsetBy(dx: dx, dy: dy)))
            }
            addParagraph(lines: members, background: paragraph.background, foreground: paragraph.foreground)
        }
    }

    /// The same picture a quarter darker, as under the veil of a dialog; the text stays the same
    func dimmed() -> SimSprite {
        let copy = SimSprite(width: width, height: height, level: 0)
        let count = pixels.count
        copy.pixels.withUnsafeMutableBufferPointer { target in
            pixels.withUnsafeBufferPointer { source in
                guard let to = target.baseAddress, let from = source.baseAddress else { return }
                for index in 0..<count {
                    to[index] = from[index] &- (from[index] >> 2) &+ 3
                }
            }
        }
        copy.lines = lines
        copy.paragraphs = paragraphs
        for index in copy.paragraphs.indices {
            copy.paragraphs[index].background = paragraphs[index].background - paragraphs[index].background / 4 + 3
            copy.paragraphs[index].foreground = paragraphs[index].foreground - paragraphs[index].foreground / 4 + 3
        }
        return copy
    }

    /// The same picture as seen through frosted glass of brightness `tint`: nothing of the text
    /// can be read, but it still moves when the content behind the glass does
    func frosted(tint: UInt8) -> SimSprite {
        let copy = SimSprite(width: width, height: height, level: tint)
        var work = pixels
        // averaging with a copy shifted by 1, 2, 4 … pixels is a box blur over twice the last shift
        for shift in [1, 2, 4, 8, 16] {
            SimSprite.averageShifted(&work, by: shift, roundingUp: shift == 2 || shift == 8)
            SimSprite.averageShifted(&work, by: shift * width, roundingUp: shift == 1 || shift == 4)
        }
        // three parts glass, one part of what lies behind it
        let count = work.count
        copy.pixels.withUnsafeMutableBufferPointer { target in
            work.withUnsafeBufferPointer { source in
                guard let to = target.baseAddress, let from = source.baseAddress else { return }
                for index in 0..<count {
                    let half = (from[index] & tint) &+ ((from[index] ^ tint) >> 1)
                    to[index] = (half & tint) &+ ((half ^ tint) >> 1)
                }
            }
        }
        return copy
    }

    /// Every pixel becomes the mean of itself and the one `distance` further on
    private static func averageShifted(_ pixels: inout [UInt8], by distance: Int, roundingUp: Bool) {
        let count = pixels.count - distance
        guard count > 0 else { return }
        pixels.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let other = base + distance
            if roundingUp {
                for index in 0..<count {
                    base[index] = (base[index] | other[index]) &- ((base[index] ^ other[index]) >> 1)
                }
            } else {
                for index in 0..<count {
                    base[index] = (base[index] & other[index]) &+ ((base[index] ^ other[index]) >> 1)
                }
            }
        }
    }

    /// A mixture of this picture and another one of the same size, `weight`/`total` of it the
    /// other one (a step of a cross-fade). `keepsOwnText` and `keepsOtherText` say whose text
    /// can be read in it: in the middle of a fade both can.
    func blended(with other: SimSprite, weight: Int, of total: Int, keepsOwnText: Bool, keepsOtherText: Bool) -> SimSprite {
        precondition(other.width == width && other.height == height && total > 0 && weight >= 0 && weight <= total,
                     "SimSprite: cannot blend these")
        let copy = SimSprite(width: width, height: height, level: 0)
        let count = pixels.count
        let ownWeight = total - weight, half = total / 2
        copy.pixels.withUnsafeMutableBufferPointer { target in
            pixels.withUnsafeBufferPointer { first in
                other.pixels.withUnsafeBufferPointer { second in
                    guard let to = target.baseAddress, let own = first.baseAddress, let theirs = second.baseAddress else { return }
                    for index in 0..<count {
                        let mine: Int = Int(own[index]) * ownWeight
                        let others: Int = Int(theirs[index]) * weight
                        to[index] = UInt8((mine + others + half) / total)
                    }
                }
            }
        }
        if keepsOwnText { copy.adoptText(of: self, dx: 0, dy: 0) }
        if keepsOtherText { copy.adoptText(of: other, dx: 0, dy: 0) }
        return copy
    }

    /// The part `window` of another sprite enlarged to `width` × `height` pixels (every pixel
    /// shows the nearest one of the source), with the text that reaches into it
    static func magnified(_ source: SimSprite, window: SimRect, width: Int, height: Int) -> SimSprite {
        precondition(!window.isEmpty, "SimSprite: nothing to magnify")
        let sprite = SimSprite(width: width, height: height, level: 0)
        var columns = [Int](repeating: 0, count: width)
        for x in 0..<width {
            columns[x] = min(source.width - 1, max(0, window.x + (2 * x + 1) * window.width / (2 * width)))
        }
        let sourceStride = source.width
        sprite.pixels.withUnsafeMutableBufferPointer { target in
            source.pixels.withUnsafeBufferPointer { from in
                guard let to = target.baseAddress, let base = from.baseAddress else { return }
                for y in 0..<height {
                    let row = min(source.height - 1, max(0, window.y + (2 * y + 1) * window.height / (2 * height)))
                    let line = base + row * sourceStride
                    let out = to + y * width
                    for x in 0..<width {
                        out[x] = line[columns[x]]
                    }
                }
            }
        }
        for paragraph in source.paragraphs where !paragraph.rect.intersection(window).isEmpty {
            var members: [Int] = []
            for member in paragraph.lines {
                let line = source.lines[member]
                let left = SimMath.floorDiv((line.rect.x - window.x) * width, window.width)
                let top = SimMath.floorDiv((line.rect.y - window.y) * height, window.height)
                let right = SimMath.ceilDiv((line.rect.maxX - window.x) * width, window.width)
                let bottom = SimMath.ceilDiv((line.rect.maxY - window.y) * height, window.height)
                members.append(sprite.addLine(line.text, alternate: line.alternate,
                                              rect: SimRect(x: left, y: top, width: right - left, height: bottom - top)))
            }
            sprite.addParagraph(lines: members, background: paragraph.background, foreground: paragraph.foreground)
        }
        return sprite
    }

    /// Records the lines and paragraphs of another sprite as its own, moved by (dx, dy). A
    /// paragraph that is there already (same text in the same place) is not recorded twice.
    func adoptText(of source: SimSprite, dx: Int, dy: Int) {
        for paragraph in source.paragraphs {
            let place = paragraph.rect.offsetBy(dx: dx, dy: dy)
            if paragraphs.contains(where: { $0.text == paragraph.text && $0.rect == place }) { continue }
            var members: [Int] = []
            for member in paragraph.lines {
                let line = source.lines[member]
                members.append(addLine(line.text, alternate: line.alternate, rect: line.rect.offsetBy(dx: dx, dy: dy)))
            }
            addParagraph(lines: members, background: paragraph.background, foreground: paragraph.foreground)
        }
    }

    // MARK: Use in frames

    /// No more drawing: the reduced copies made from now on stay valid
    func seal() {
        guard !isSealed else { return }
        isSealed = true
        paragraphOrder = paragraphs.indices.sorted {
            (paragraphs[$0].rect.y, $0) < (paragraphs[$1].rect.y, $1)
        }
        tallestParagraph = paragraphs.map(\.rect.height).max() ?? 0
    }

    /// Paragraphs that reach into the rows from `top` to `bottom` (pixels of the sprite)
    func paragraphs(fromY top: Int, toY bottom: Int) -> [Int] {
        precondition(isSealed, "SimSprite: seal it first")
        // the first one that starts late enough to reach `top` at all
        var low = 0, high = paragraphOrder.count
        while low < high {
            let middle = (low + high) / 2
            if paragraphs[paragraphOrder[middle]].rect.y < top - tallestParagraph {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var found: [Int] = []
        var position = low
        while position < paragraphOrder.count {
            let rect = paragraphs[paragraphOrder[position]].rect
            if rect.y >= bottom { break }
            if rect.maxY > top { found.append(paragraphOrder[position]) }
            position += 1
        }
        return found
    }

    /// The copy reduced by `scale` for one position relative to the cell grid, with at least the
    /// cell rows `rows` filled in
    func reduced(scale: Int, phaseX: Int, phaseY: Int, rows: Range<Int>) -> SimReducedCopy {
        precondition(isSealed, "SimSprite: seal it first")
        let key = phaseY * 64 + phaseX
        let copy: SimReducedCopy
        if let existing = reducedCopies[key] {
            copy = existing
        } else {
            copy = SimReducedCopy(width: max(0, (width - phaseX) / scale), height: max(0, (height - phaseY) / scale))
            reducedCopies[key] = copy
        }
        guard copy.width > 0, copy.height > 0 else { return copy }
        let bandRows = SimReducedCopy.bandRows
        let firstBand = max(0, rows.lowerBound) / bandRows
        let endBand = min(copy.isBandReady.count, (max(0, rows.upperBound) + bandRows - 1) / bandRows)
        guard firstBand < endBand else { return copy }
        for band in firstBand..<endBand where !copy.isBandReady[band] {
            let top = band * bandRows
            let count = min(bandRows, copy.height - top)
            let stride = width
            let part: LumaImage = pixels.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return LumaImage(width: 0, height: 0) }
                return LumaImage.downsampled(from: base + (top * scale + phaseY) * stride + phaseX, width: stride - phaseX,
                                             height: count * scale, bytesPerRow: stride, format: .luma8, scale: scale)
            }
            precondition(part.width == copy.width && part.height == count, "SimSprite: reduced band has the wrong size")
            let offset = top * copy.width
            copy.pixels.withUnsafeMutableBufferPointer { target in
                part.pixels.withUnsafeBufferPointer { source in
                    guard let to = target.baseAddress, let from = source.baseAddress else { return }
                    (to + offset).update(from: from, count: part.pixels.count)
                }
            }
            copy.isBandReady[band] = true
        }
        return copy
    }
}

// MARK: - Scenes

/// One sprite as a frame shows it
struct SimLayer: Equatable {
    /// tells the layers of a scene apart and stays the same over time
    var slot: Int
    /// index into `SimScenario.sprites`
    var sprite: Int
    /// where the top left corner of the sprite lies in the frame
    var x: Int
    var y: Int
    /// the part of the frame the layer may paint
    var clip: SimRect
    /// content that scrolls: loses detail when it moves fast
    var degrades = false
    /// 0…100, how much detail the video link has lost here (set by `SimScenario.finish`)
    var loss = 0
    var lossAlongX = false

    init(slot: Int, sprite: Int, x: Int, y: Int, clip: SimRect, degrades: Bool = false) {
        self.slot = slot
        self.sprite = sprite
        self.x = x
        self.y = y
        self.clip = clip
        self.degrades = degrades
    }
}

/// What the screen shows during one tick: layers from back to front
struct SimScene: Equatable {
    var layers: [SimLayer] = []
}

/// A block of thumbnail cells of a layer that the video link got wrong
struct SimBlockDamage {
    /// thumbnail cells
    var cells: SimRect
    /// the content appears displaced by so many frame pixels; both 0 = it lost its detail instead
    var shiftX: Int
    var shiftY: Int
}

/// A line as one frame shows it
struct SimLineSight {
    /// index into the layers of the scene
    var layer: Int
    var sprite: Int
    var line: Int
    /// the whole line in frame pixels, seen or not
    var rect: SimRect
    /// the smallest rectangle around what can be seen of it
    var visible: SimRect
    var visibleArea: Int
}

/// A paragraph as one frame shows it
struct SimParagraphSight {
    /// the same for the same paragraph of the same sprite in the same layer slot in every frame
    var key: Int
    var layer: Int
    var slot: Int
    var sprite: Int
    var paragraph: Int
    /// all its lines in frame pixels, seen or not
    var rect: SimRect
    /// the smallest rectangle around what can be seen of `rect`
    var visible: SimRect
    /// all of `rect` can be seen: a translation drawn over it covers nothing else
    var isFullyVisible: Bool
    /// what can be seen of `rect` is exactly `visible` (cut by straight edges only)
    var isVisiblePartWhole: Bool
}

// MARK: - Scenario

/// A screen with everything that happens on it for a few seconds, the frames a source would send
/// of it and the truth about every one of them
final class SimScenario {
    static let ticksPerSecond = 60
    private static let noiseFieldLength = 1 << 16
    /// side of a block of thumbnail cells that the video link codes as one
    private static let blockCells = 8

    let name: String
    let seed: UInt64
    let frameWidth: Int
    let frameHeight: Int
    /// factor between frame and thumbnail, as the real pipeline chooses it
    let scale: Int

    private(set) var sprites: [SimSprite] = []
    /// one per tick of 1/60 s
    var scenes: [SimScene] = []
    /// the source has a frame for this tick (its frame rate, less the frames that got lost)
    var frameDue: [Bool] = []
    /// wireless sources send a frame only when the picture changed; a cable sends every one
    var sendsOnlyChanges = true
    /// largest change of a thumbnail pixel by noise, 0…8
    var noise = 2
    /// a cable source whose frames of a still picture differ by their noise
    var noiseOnRepeats = false
    /// strength of the loss of detail at speed in percent; 0 = a perfect link
    var compression = 100
    /// seconds a batch of translations takes
    var translatorLatency: TimeInterval = 0.08
    /// a slow or billed translator is asked once the picture has come to rest (at most 1.5 s later)
    var translatorWaitsForRest = false
    /// By how much each edge of a recognized line may be off: so many pixels for every 30 pixels
    /// of line height, at least one
    var recognitionRectNoise = 1

    /// The largest error of an edge of a line of the given height
    func rectNoise(lineHeight: Int) -> Int {
        max(1, recognitionRectNoise * lineHeight / 30)
    }
    /// how often, in percent, a line that was read before is read slightly differently
    var misreadingPercent = 8
    /// The recognizer says how sure it is (Vision does; recognizers on other platforms may not,
    /// and then every block comes with `confidence` nil). Even where it does, a line that is cut
    /// off is not reliably marked as uncertain, and some complete lines are.
    var reportsConfidence = true
    /// the passes (counted from 1) in which the recognition fails: `abandonRecognition`
    var failingPasses: [Int] = []
    /// share of the texts, in percent, whose first translation is answered with "not now":
    /// `translationFailed`, and the text is offered again after the tracker's retry delay
    var postponedPercent = 0
    /// What the source shows next, when it goes on with frames of another size (the phone was
    /// turned). The bench plays it right after this one, with the same tracker.
    var sequel: SimScenario?

    private var noiseField: [UInt8] = []
    private var isFinished = false
    private var cachedSightsTick = -1
    private var cachedSights: [SimParagraphSight] = []

    init(name: String, seed: UInt64, frameWidth: Int, frameHeight: Int) {
        self.name = name
        self.seed = seed
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        scale = LumaImage.scale(forFrameWidth: frameWidth, height: frameHeight)
    }

    var frameRect: SimRect { SimRect(x: 0, y: 0, width: frameWidth, height: frameHeight) }
    var tickCount: Int { scenes.count }
    var duration: TimeInterval { Double(scenes.count) / Double(SimScenario.ticksPerSecond) }

    /// this scenario and what follows it
    var parts: [SimScenario] {
        var parts: [SimScenario] = [self]
        var next = sequel
        while let part = next {
            parts.append(part)
            next = part.sequel
        }
        return parts
    }

    /// ticks of all parts
    var totalTickCount: Int {
        var count = 0
        for part in parts {
            count += part.tickCount
        }
        return count
    }

    @discardableResult
    func add(_ sprite: SimSprite) -> Int {
        precondition(!isFinished, "SimScenario: already finished")
        sprite.index = sprites.count
        sprites.append(sprite)
        return sprite.index
    }

    /// Call once after the last scene: works out the loss of detail and prepares the noise
    func finish() {
        precondition(!isFinished && !scenes.isEmpty, "SimScenario: no scenes, or finished twice")
        precondition(noise >= 0 && noise <= 8, "SimScenario: noise out of range")
        if frameDue.count != scenes.count {
            frameDue = [Bool](repeating: true, count: scenes.count)
        }
        frameDue[0] = true
        for sprite in sprites {
            sprite.seal()
        }
        // the truth tells layers apart by their slot
        for (tick, scene) in scenes.enumerated() {
            var slots: Set<Int> = []
            for layer in scene.layers {
                precondition(slots.insert(layer.slot).inserted, "SimScenario \(name): two layers in slot \(layer.slot) at tick \(tick)")
            }
        }
        setLoss()
        if noise > 0 {
            var random = SimRandom(seed: seed).branch(0x6E6F_6973_65)
            noiseField = (0..<(SimScenario.noiseFieldLength + frameWidth / scale)).map { _ in
                UInt8(truncatingIfNeeded: random.int(-noise, noise))
            }
        }
        isFinished = true
    }

    /// Content loses detail in proportion to the share of its area it moves by per tick (all of
    /// it at 15 %) and gets it back within three ticks.
    private func setLoss() {
        var before: [Int: SimLayer] = [:]
        for tick in scenes.indices {
            var now: [Int: SimLayer] = [:]
            for index in scenes[tick].layers.indices where scenes[tick].layers[index].degrades {
                var layer = scenes[tick].layers[index]
                var loss = 0
                var alongX = false
                if let previous = before[layer.slot] {
                    loss = max(0, previous.loss - 34)
                    alongX = previous.lossAlongX
                    if previous.sprite == layer.sprite {
                        let dx = abs(layer.x - previous.x), dy = abs(layer.y - previous.y)
                        let share = max(dx * 1000 / max(1, layer.clip.width), dy * 1000 / max(1, layer.clip.height))
                        // slow movement is coded without loss
                        let fresh = share < 5 ? 0 : min(100, share * compression / 150)
                        if fresh >= loss {
                            loss = fresh
                            alongX = dx > dy
                        }
                    }
                }
                layer.loss = loss
                layer.lossAlongX = alongX
                scenes[tick].layers[index] = layer
                now[layer.slot] = layer
            }
            before = now
        }
    }

    // MARK: Frames

    /// The picture of tick `a` differs from that of tick `b`
    func pictureDiffers(_ a: Int, from b: Int) -> Bool {
        if scenes[a] != scenes[b] { return true }
        // damaged blocks are different ones in every picture
        return scenes[a].layers.contains { $0.loss > 0 }
    }

    /// The part of the frame a layer paints
    func paintedRect(of layer: SimLayer) -> SimRect {
        let sprite = sprites[layer.sprite]
        return layer.clip.intersection(frameRect)
            .intersection(SimRect(x: layer.x, y: layer.y, width: sprite.width, height: sprite.height))
    }

    /// Thumbnail cells that lie completely inside the part of the frame a layer paints
    private func paintedCells(of layer: SimLayer) -> SimRect {
        let rect = paintedRect(of: layer)
        guard !rect.isEmpty else { return SimRect() }
        let left = SimMath.ceilDiv(rect.x, scale), top = SimMath.ceilDiv(rect.y, scale)
        let right = min(frameWidth / scale, SimMath.floorDiv(rect.maxX, scale))
        let bottom = min(frameHeight / scale, SimMath.floorDiv(rect.maxY, scale))
        guard right > left, bottom > top else { return SimRect() }
        return SimRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The blocks of a layer that the video link got wrong in the picture of one tick
    func damage(to layer: SimLayer, tick: Int) -> [SimBlockDamage] {
        guard layer.loss > 0 else { return [] }
        let cells = paintedCells(of: layer)
        guard !cells.isEmpty else { return [] }
        let sprite = sprites[layer.sprite]
        var random = SimRandom(seed: seed ^ 0x626C_6F63_6B73).branch(UInt64(tick * 256 + layer.slot))
        let shifted = layer.loss * 2, softened = layer.loss * 9 / 2     // of 1000 blocks
        let reach = 1 + layer.loss / 40
        var damage: [SimBlockDamage] = []
        let side = SimScenario.blockCells
        var top = cells.y
        while top < cells.maxY {
            var left = cells.x
            while left < cells.maxX {
                let block = SimRect(x: left, y: top, width: min(side, cells.maxX - left),
                                    height: min(side, cells.maxY - top))
                let draw = random.next()
                let pick = Int(draw % 1000)
                if pick < shifted {
                    let distance = (1 + Int((draw >> 20) % UInt64(reach))) * ((draw >> 40) & 1 == 0 ? 1 : -1)
                    let shiftX = layer.lossAlongX ? distance : 0, shiftY = layer.lossAlongX ? 0 : distance
                    // only where the sprite has content to show instead
                    let source = SimRect(x: block.x * scale - layer.x - shiftX, y: block.y * scale - layer.y - shiftY,
                                         width: block.width * scale, height: block.height * scale)
                    if sprite.bounds.contains(source) {
                        damage.append(SimBlockDamage(cells: block, shiftX: shiftX, shiftY: shiftY))
                    }
                } else if pick < shifted + softened {
                    damage.append(SimBlockDamage(cells: block, shiftX: 0, shiftY: 0))
                }
                left += side
            }
            top += side
        }
        return damage
    }

    /// The thumbnail of the frame of one tick, identical to `frame(at:)` reduced by `scale`
    func thumbnail(at tick: Int) -> LumaImage {
        precondition(isFinished, "SimScenario: finish it first")
        var image = LumaImage(width: frameWidth / scale, height: frameHeight / scale)
        let layers = scenes[tick].layers
        var damages: [[SimBlockDamage]] = []
        var hasPartialCells = false
        for layer in layers {
            let blocks = damage(to: layer, tick: tick)
            damages.append(blocks)
            let cells = paintedCells(of: layer)
            if cells != touchedCells(of: layer) { hasPartialCells = true }
            guard !cells.isEmpty else { continue }
            copyCells(of: layer, shiftX: 0, shiftY: 0, cells: cells, into: &image)
            for block in blocks {
                if block.shiftX != 0 || block.shiftY != 0 {
                    copyCells(of: layer, shiftX: block.shiftX, shiftY: block.shiftY, cells: block.cells, into: &image)
                } else {
                    let values = softened(layer, cells: block.cells)
                    for row in 0..<block.cells.height {
                        for column in 0..<block.cells.width {
                            image[block.cells.x + column, block.cells.y + row] = values[row * block.cells.width + column]
                        }
                    }
                }
            }
        }
        if hasPartialCells { fillPartialCells(of: layers, damages: damages, into: &image) }
        addNoise(to: &image, tick: tick, cell: 1)
        return image
    }

    /// Thumbnail cells that the part of the frame a layer paints reaches into
    private func touchedCells(of layer: SimLayer) -> SimRect {
        let rect = paintedRect(of: layer)
        guard !rect.isEmpty else { return SimRect() }
        let left = SimMath.floorDiv(rect.x, scale), top = SimMath.floorDiv(rect.y, scale)
        let right = min(frameWidth / scale, SimMath.ceilDiv(rect.maxX, scale))
        let bottom = min(frameHeight / scale, SimMath.ceilDiv(rect.maxY, scale))
        guard right > left, bottom > top else { return SimRect() }
        return SimRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Cells that a layer paints only a part of (its edge does not lie on the grid of the
    /// cells) get the mean of their pixels, composed the way `frame(at:)` does it
    private func fillPartialCells(of layers: [SimLayer], damages: [[SimBlockDamage]], into image: inout LumaImage) {
        var buffer = [Int](repeating: 0, count: scale * scale)
        var done: Set<Int> = []
        for layer in layers {
            let outer = touchedCells(of: layer)
            let inner = paintedCells(of: layer)
            guard !outer.isEmpty, outer != inner else { continue }
            for row in outer.y..<outer.maxY {
                let isInnerRow = !inner.isEmpty && row >= inner.y && row < inner.maxY
                var column = outer.x
                while column < outer.maxX {
                    if isInnerRow, column >= inner.x, column < inner.maxX {
                        // the cells in between belong to the layer completely
                        column = inner.maxX
                        continue
                    }
                    if done.insert(row * image.width + column).inserted {
                        image[column, row] = composedCell(column: column, row: row, layers: layers, damages: damages,
                                                          buffer: &buffer)
                    }
                    column += 1
                }
            }
        }
    }

    /// The mean of the frame pixels of one thumbnail cell
    private func composedCell(column: Int, row: Int, layers: [SimLayer], damages: [[SimBlockDamage]],
                              buffer: inout [Int]) -> UInt8 {
        let cell = SimRect(x: column * scale, y: row * scale, width: scale, height: scale)
        for index in buffer.indices {
            buffer[index] = 0
        }
        for (number, layer) in layers.enumerated() {
            let part = paintedRect(of: layer).intersection(cell)
            guard !part.isEmpty else { continue }
            let sprite = sprites[layer.sprite]
            for y in part.y..<part.maxY {
                for x in part.x..<part.maxX {
                    buffer[(y - cell.y) * scale + x - cell.x] = Int(sprite.pixels[(y - layer.y) * sprite.width + x - layer.x])
                }
            }
            // a damaged block of this layer has the whole cell
            for block in damages[number] where column >= block.cells.x && column < block.cells.maxX
                && row >= block.cells.y && row < block.cells.maxY {
                if block.shiftX != 0 || block.shiftY != 0 {
                    for y in 0..<scale {
                        let from = (cell.y + y - layer.y - block.shiftY) * sprite.width + cell.x - layer.x - block.shiftX
                        for x in 0..<scale {
                            buffer[y * scale + x] = Int(sprite.pixels[from + x])
                        }
                    }
                } else {
                    let value = Int(softened(layer, cells: SimRect(x: column, y: row, width: 1, height: 1))[0])
                    for index in buffer.indices {
                        buffer[index] = value
                    }
                }
            }
        }
        var sum = 0
        for value in buffer {
            sum += value
        }
        return UInt8((sum + scale * scale / 2) / (scale * scale))
    }

    /// The frame of one tick at full resolution. Slow; the bench itself only needs thumbnails.
    func frame(at tick: Int) -> LumaImage {
        precondition(isFinished, "SimScenario: finish it first")
        var image = LumaImage(width: frameWidth, height: frameHeight)
        for layer in scenes[tick].layers {
            copyPixels(of: layer, shiftX: 0, shiftY: 0, area: paintedRect(of: layer), into: &image)
            for block in damage(to: layer, tick: tick) {
                let area = SimRect(x: block.cells.x * scale, y: block.cells.y * scale,
                                   width: block.cells.width * scale, height: block.cells.height * scale)
                if block.shiftX != 0 || block.shiftY != 0 {
                    copyPixels(of: layer, shiftX: block.shiftX, shiftY: block.shiftY, area: area, into: &image)
                } else {
                    let values = softened(layer, cells: block.cells)
                    for row in 0..<area.height {
                        for column in 0..<area.width {
                            image[area.x + column, area.y + row] = values[(row / scale) * block.cells.width + column / scale]
                        }
                    }
                }
            }
        }
        addNoise(to: &image, tick: tick, cell: scale)
        return image
    }

    /// Copies thumbnail cells of a layer from the reduced copy of its sprite that fits its position
    private func copyCells(of layer: SimLayer, shiftX: Int, shiftY: Int, cells: SimRect, into image: inout LumaImage) {
        let x = layer.x + shiftX, y = layer.y + shiftY
        let phaseX = SimMath.mod(-x, scale), phaseY = SimMath.mod(-y, scale)
        let column = (cells.x * scale - x - phaseX) / scale, row = (cells.y * scale - y - phaseY) / scale
        let copy = sprites[layer.sprite].reduced(scale: scale, phaseX: phaseX, phaseY: phaseY,
                                                 rows: row..<(row + cells.height))
        precondition(column >= 0 && row >= 0 && column + cells.width <= copy.width && row + cells.height <= copy.height,
                     "SimScenario \(name): a layer shows more than its sprite has")
        let stride = image.width, sourceStride = copy.width
        image.pixels.withUnsafeMutableBufferPointer { target in
            copy.pixels.withUnsafeBufferPointer { source in
                guard let to = target.baseAddress, let from = source.baseAddress else { return }
                for offset in 0..<cells.height {
                    (to + (cells.y + offset) * stride + cells.x)
                        .update(from: from + (row + offset) * sourceStride + column, count: cells.width)
                }
            }
        }
    }

    /// Copies frame pixels of a layer straight from its sprite
    private func copyPixels(of layer: SimLayer, shiftX: Int, shiftY: Int, area: SimRect, into image: inout LumaImage) {
        guard !area.isEmpty else { return }
        let sprite = sprites[layer.sprite]
        let x = layer.x + shiftX, y = layer.y + shiftY
        precondition(sprite.bounds.contains(area.offsetBy(dx: -x, dy: -y)),
                     "SimScenario \(name): a layer shows more than its sprite has")
        let stride = image.width, sourceStride = sprite.width
        image.pixels.withUnsafeMutableBufferPointer { target in
            sprite.pixels.withUnsafeBufferPointer { source in
                guard let to = target.baseAddress, let from = source.baseAddress else { return }
                for row in area.y..<area.maxY {
                    (to + row * stride + area.x)
                        .update(from: from + (row - y) * sourceStride + area.x - x, count: area.width)
                }
            }
        }
    }

    /// Thumbnail cells of a layer without their fine detail: a quarter of the cell itself, half
    /// of its four neighbours and a quarter of those two cells away
    private func softened(_ layer: SimLayer, cells: SimRect) -> [UInt8] {
        let phaseX = SimMath.mod(-layer.x, scale), phaseY = SimMath.mod(-layer.y, scale)
        let column = (cells.x * scale - layer.x - phaseX) / scale, row = (cells.y * scale - layer.y - phaseY) / scale
        let copy = sprites[layer.sprite].reduced(scale: scale, phaseX: phaseX, phaseY: phaseY,
                                                 rows: (row - 2)..<(row + cells.height + 2))
        var values = [UInt8](repeating: 0, count: cells.width * cells.height)
        let lastColumn = copy.width - 1, lastRow = copy.height - 1
        copy.pixels.withUnsafeBufferPointer { source in
            guard let from = source.baseAddress else { return }
            for offsetY in 0..<cells.height {
                let y = row + offsetY
                let here = from + min(lastRow, max(0, y)) * copy.width
                let up = from + min(lastRow, max(0, y - 1)) * copy.width
                let down = from + min(lastRow, max(0, y + 1)) * copy.width
                let up2 = from + min(lastRow, max(0, y - 2)) * copy.width
                let down2 = from + min(lastRow, max(0, y + 2)) * copy.width
                for offsetX in 0..<cells.width {
                    let x = min(lastColumn, max(0, column + offsetX))
                    let left = max(0, x - 1), right = min(lastColumn, x + 1)
                    let left2 = max(0, x - 2), right2 = min(lastColumn, x + 2)
                    let near = SimScenario.mean(SimScenario.mean(here[left], here[right]),
                                                SimScenario.mean(up[x], down[x]))
                    let far = SimScenario.mean(SimScenario.mean(here[left2], here[right2]),
                                               SimScenario.mean(up2[x], down2[x]))
                    values[offsetY * cells.width + offsetX] = SimScenario.mean(near, SimScenario.mean(here[x], far))
                }
            }
        }
        return values
    }

    /// (a + b) / 2 rounded down, without leaving eight bits
    private static func mean(_ a: UInt8, _ b: UInt8) -> UInt8 {
        (a & b) &+ ((a ^ b) >> 1)
    }

    /// Adds the noise of one picture: the same value for all pixels of a thumbnail cell
    /// (`cell` = side of a cell in pixels of `image`), a different stretch of the noise field for
    /// every row of cells
    private func addNoise(to image: inout LumaImage, tick: Int, cell: Int) {
        guard noise > 0 else { return }
        var random = SimRandom(seed: seed ^ 0x6772_6169_6E).branch(UInt64(tick))
        let columns = frameWidth / scale, rows = frameHeight / scale
        let stride = image.width
        let fieldLength = SimScenario.noiseFieldLength
        noiseField.withUnsafeBufferPointer { field in
            image.pixels.withUnsafeMutableBufferPointer { target in
                guard let from = field.baseAddress, let to = target.baseAddress else { return }
                for row in 0..<rows {
                    let source = from + random.below(fieldLength)
                    if cell == 1 {
                        let line = to + row * stride
                        for column in 0..<columns {
                            line[column] = line[column] &+ source[column]
                        }
                    } else {
                        for inner in 0..<cell {
                            let line = to + (row * cell + inner) * stride
                            for column in 0..<(columns * cell) {
                                line[column] = line[column] &+ source[column / cell]
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Ground truth

    /// The parts of the frame the layers of a tick paint, in their order
    func paintedRects(at tick: Int) -> [SimRect] {
        scenes[tick].layers.map { paintedRect(of: $0) }
    }

    /// The lines of which something can be seen in the frame of a tick, counting only what lies
    /// inside `region` (the recognition sees nothing else)
    func lineSights(at tick: Int, within region: SimRect) -> [SimLineSight] {
        let scene = scenes[tick]
        let painted = paintedRects(at: tick)
        var sights: [SimLineSight] = []
        for (index, layer) in scene.layers.enumerated() {
            let area = painted[index].intersection(region)
            let sprite = sprites[layer.sprite]
            guard !area.isEmpty, !sprite.lines.isEmpty else { continue }
            let covers = Array(painted[(index + 1)...])
            for paragraph in sprite.paragraphs(fromY: area.y - layer.y, toY: area.maxY - layer.y) {
                for line in sprite.paragraphs[paragraph].lines {
                    let rect = sprite.lines[line].rect.offsetBy(dx: layer.x, dy: layer.y)
                    let part = SimRect.uncovered(rect.intersection(area), by: covers)
                    if part.area > 0 {
                        sights.append(SimLineSight(layer: index, sprite: layer.sprite, line: line, rect: rect,
                                                   visible: part.box, visibleArea: part.area))
                    }
                }
            }
        }
        return sights
    }

    /// The paragraphs of which something can be seen in the frame of a tick
    func paragraphSights(at tick: Int) -> [SimParagraphSight] {
        if tick == cachedSightsTick { return cachedSights }
        let scene = scenes[tick]
        let painted = paintedRects(at: tick)
        var sights: [SimParagraphSight] = []
        for (index, layer) in scene.layers.enumerated() {
            let area = painted[index]
            let sprite = sprites[layer.sprite]
            guard !area.isEmpty, !sprite.paragraphs.isEmpty else { continue }
            let covers = Array(painted[(index + 1)...])
            for paragraphIndex in sprite.paragraphs(fromY: area.y - layer.y, toY: area.maxY - layer.y) {
                let paragraph = sprite.paragraphs[paragraphIndex]
                let rect = paragraph.rect.offsetBy(dx: layer.x, dy: layer.y)
                let whole = SimRect.uncovered(rect.intersection(area), by: covers)
                guard whole.area > 0 else { continue }
                let key = SimScenario.paragraphKey(slot: layer.slot, sprite: layer.sprite, paragraph: paragraphIndex)
                sights.append(SimParagraphSight(key: key, layer: index, slot: layer.slot, sprite: layer.sprite,
                                                paragraph: paragraphIndex, rect: rect, visible: whole.box,
                                                isFullyVisible: whole.area == rect.area,
                                                isVisiblePartWhole: whole.area == whole.box.area))
            }
        }
        cachedSightsTick = tick
        cachedSights = sights
        return sights
    }

    static func paragraphKey(slot: Int, sprite: Int, paragraph: Int) -> Int {
        (slot << 44) | (sprite << 24) | paragraph
    }
}

// MARK: - Movement

/// The position of scrolling content over time, in whole pixels per tick. Counted in 1/1024
/// pixel, with whole numbers only, so that it comes out the same everywhere.
struct SimTrack {
    private(set) var positions: [Int] = []
    private var fine: Int
    /// the ends of the content; `flick` and `release` treat them like a rubber band
    let lower: Int
    let upper: Int

    init(start: Int, lower: Int, upper: Int) {
        fine = start << 10
        self.lower = lower
        self.upper = max(lower, upper)
    }

    var position: Int { (fine + 512) >> 10 }

    private mutating func move(to newFine: Int) {
        fine = newFine
        positions.append(position)
    }

    mutating func rest(_ ticks: Int) {
        for _ in 0..<max(0, ticks) {
            move(to: fine)
        }
    }

    /// A finger on the glass: moves by `distance` pixels in `ticks`, starting and ending gently
    mutating func drag(by distance: Int, ticks: Int) {
        let start = fine
        for tick in 1...max(1, ticks) {
            let t = tick * 1024 / max(1, ticks)
            let eased = (3 * t * t - 2 * t * t * t / 1024) / 1024
            move(to: start + distance * eased)
        }
    }

    /// Constant speed in 1/1024 pixel per tick
    mutating func glide(speed: Int, ticks: Int) {
        for _ in 0..<max(0, ticks) {
            move(to: fine + speed)
        }
    }

    /// Let go at `speed` (1/1024 pixel per tick): every tick keeps `keep`/1000 of the speed.
    /// Content that runs past an end stretches like a rubber band and comes back.
    mutating func flick(speed: Int, keep: Int = 967, maxTicks: Int = 600) {
        var velocity = speed
        for _ in 0..<maxTicks {
            let beyond = fine < lower << 10 ? fine - (lower << 10) : (fine > upper << 10 ? fine - (upper << 10) : 0)
            if beyond != 0 {
                // a damped spring that does not swing back
                velocity = velocity * 400 / 1000 - beyond * 90 / 1000
                if abs(beyond) < 600 && abs(velocity) < 300 {
                    move(to: beyond < 0 ? lower << 10 : upper << 10)
                    return
                }
            } else {
                velocity = velocity * keep / 1000
                if abs(velocity) < 300 { return }
            }
            move(to: fine + velocity)
        }
    }

    /// Lets go of content that was dragged past an end
    mutating func release() {
        flick(speed: 0)
    }

    /// Tiny steps back and forth around the current position, as under a resting finger
    mutating func tremble(amplitude: Int, ticks: Int, random: inout SimRandom) {
        let center = fine
        var remaining = ticks
        while remaining > 0 {
            let hold = min(remaining, random.int(1, 4))
            let target = center + (random.int(-amplitude, amplitude) << 10)
            for _ in 0..<hold {
                move(to: target)
            }
            remaining -= hold
        }
        fine = center
    }

    /// Runs to `target` in `ticks`, fast first and gently at the end (a pager snapping into place)
    mutating func settle(at target: Int, ticks: Int) {
        let start = fine, distance = (target << 10) - fine
        for tick in 1...max(1, ticks) {
            let rest = 1024 - tick * 1024 / max(1, ticks)
            let eased = 1024 - rest * rest / 1024 * rest / 1024
            move(to: start + distance * eased / 1024)
        }
        fine = target << 10
        positions[positions.count - 1] = target
    }
}

/// Which ticks bring a frame
enum SimCadence {
    /// Every `interval`-th tick, less `dropPercent` of them that get lost, sometimes two or three
    /// in a row
    static func frames(ticks: Int, interval: Int = 1, dropPercent: Int = 0, random: inout SimRandom) -> [Bool] {
        var due = [Bool](repeating: false, count: ticks)
        var dropping = 0
        var tick = 0
        while tick < ticks {
            if dropping > 0 {
                dropping -= 1
            } else if dropPercent > 0, tick > 0, random.chance(dropPercent) {
                dropping = random.chance(30) ? random.int(1, 2) : 0
            } else {
                due[tick] = true
            }
            tick += interval
        }
        return due
    }
}

// MARK: - Building screens

/// Brightness values of a screen design
struct SimTheme {
    var background: UInt8
    var text: UInt8
    var secondary: UInt8
    var accent: UInt8
    var onAccent: UInt8
    var separator: UInt8
    var card: UInt8
    var bar: UInt8

    /// text that is barely there: a placeholder, something switched off
    var faint: UInt8 {
        background > 128 ? background - 38 : background + 38
    }

    static func light(_ random: inout SimRandom) -> SimTheme {
        let background = random.int(232, SimLevel.brightest)
        return SimTheme(background: UInt8(background), text: UInt8(random.int(18, 40)),
                        secondary: UInt8(random.int(105, 135)), accent: UInt8(random.int(70, 100)),
                        onAccent: UInt8(random.int(232, 243)),
                        separator: UInt8(background - random.int(22, 34)), card: UInt8(background - random.int(10, 16)),
                        bar: UInt8(background - random.int(6, 12)))
    }

    static func dark(_ random: inout SimRandom) -> SimTheme {
        let background = random.int(SimLevel.darkest, 26)
        return SimTheme(background: UInt8(background), text: UInt8(random.int(215, 240)),
                        secondary: UInt8(random.int(140, 165)), accent: UInt8(random.int(150, 180)),
                        onAccent: UInt8(random.int(14, 30)),
                        separator: UInt8(background + random.int(28, 40)), card: UInt8(background + random.int(14, 22)),
                        bar: UInt8(background + random.int(8, 16)))
    }
}

enum SimAlign {
    case left
    case center
    case right
}

/// How the rows of a list relate to each other
enum SimListKind {
    /// every row has its own label
    case distinct
    /// same icon, same first word, a short second word of its own: rows look almost alike
    case alike
    /// the same label on every row: rows look exactly alike
    case identical
}

/// What a page mostly consists of
enum SimPageProfile {
    /// headings, running text, the odd picture and button
    case article
    /// lists of rows with labels and values
    case settings
    /// cards with a picture and a caption
    case feed
    /// little text, large empty areas and pictures
    case sparse
    /// lists whose rows look almost alike, with little else
    case alike
    /// lists whose rows look exactly alike, with a few rows of their own in between
    case identical
    /// sections of list rows under header bands (for headers that stick to the top)
    case sections
    /// very large, very small and barely visible text, lines flush right, text on pictures
    case typography
}

/// Lays text and other things out on a sprite from top to bottom and records the ground truth.
/// Sizes are given in points; `unit` is the number of pixels per point.
final class SimPageBuilder {
    let sprite: SimSprite
    let unit: Int
    let theme: SimTheme
    let words: SimWords
    /// the column the builder fills
    let left: Int
    let columnWidth: Int
    let margin: Int
    /// where the next item starts
    private(set) var y: Int
    /// the header bands of sections, in pixels of the sprite
    private(set) var sections: [SimRect] = []

    private var random: SimRandom
    /// bottom and size of the last text: `TextLayout.blocks` joins lines that follow each other
    /// closely, so different items keep their distance
    private var textBottom = Int.min / 2
    private var textSize = 0

    init(sprite: SimSprite, unit: Int, theme: SimTheme, words: SimWords, random: SimRandom, top: Int,
         left: Int = 0, width: Int? = nil) {
        self.sprite = sprite
        self.unit = unit
        self.theme = theme
        self.words = words
        self.random = random
        self.left = left
        columnWidth = width ?? sprite.width - left
        margin = 16 * unit
        y = top
    }

    private func begin(textOfSize size: Int) {
        y = max(y, textBottom + max(size, textSize) + 3 * unit)
    }

    private func end(textOfSize size: Int) {
        textBottom = y
        textSize = size
    }

    func gap(_ points: Int) {
        y += points * unit
    }

    /// Words that fill at most `width` pixels at `size`, at least one
    private func line(width: Int, size: Int, bold: Bool, capitalized: Bool) -> String {
        var text = words.word(capitalized: capitalized)
        while true {
            let longer = text + " " + words.word()
            if SimFont.width(of: longer, size: size, bold: bold) > width { return text }
            text = longer
        }
    }

    /// Draws lines of text below each other as one paragraph and moves on
    func text(_ lines: [String], size: Int, x: Int, width: Int, align: SimAlign, level: UInt8, background: UInt8,
              bold: Bool = false) {
        begin(textOfSize: size)
        let pitch = size * 128 / 100
        var members: [Int] = []
        for (index, text) in lines.enumerated() {
            let textWidth = SimFont.width(of: text, size: size, bold: bold)
            let lineX: Int
            switch align {
            case .left: lineX = x
            case .center: lineX = x + (width - textWidth) / 2
            case .right: lineX = x + width - textWidth
            }
            let lineY = y + index * pitch
            sprite.drawText(text, x: lineX, y: lineY, size: size, level: level, bold: bold)
            members.append(sprite.addLine(text, alternate: words.misreading(of: text),
                                          rect: SimRect(x: lineX, y: lineY, width: textWidth, height: size)))
        }
        sprite.addParagraph(lines: members, background: background, foreground: level)
        y += (lines.count - 1) * pitch + size
        end(textOfSize: size)
    }

    /// Running text of `count` lines; the last one is shorter
    func paragraph(lines count: Int, points: Int = 17, level: UInt8? = nil, align: SimAlign = .left, bold: Bool = false) {
        let size = points * unit, width = columnWidth - 2 * margin
        var lines: [String] = []
        for index in 0..<count {
            let share = index == count - 1 && count > 1 ? random.int(30, 85) : 100
            lines.append(line(width: width * share / 100, size: size, bold: bold, capitalized: index == 0))
        }
        text(lines, size: size, x: left + margin, width: width, align: align, level: level ?? theme.text,
             background: theme.background, bold: bold)
        y += 6 * unit
    }

    func heading(points: Int = 24, centered: Bool = false) {
        y += 8 * unit
        let size = points * unit, width = columnWidth - 2 * margin
        let count = random.chance(25) ? 2 : 1
        var lines: [String] = []
        for index in 0..<count {
            lines.append(line(width: width * (index == 0 ? random.int(55, 100) : random.int(30, 70)) / 100, size: size,
                              bold: true, capitalized: true))
        }
        text(lines, size: size, x: left + margin, width: width, align: centered ? .center : .left, level: theme.text,
             background: theme.background, bold: true)
        y += 6 * unit
    }

    /// A filled button with its label in the middle
    func button() {
        y += 10 * unit
        let size = 17 * unit
        let label = words.word(minLength: 4, maxLength: 8, capitalized: true)
        let width = columnWidth * random.int(45, 80) / 100, height = 46 * unit
        let frame = SimRect(x: left + (columnWidth - width) / 2, y: y, width: width, height: height)
        sprite.fill(frame, level: theme.accent)
        y += (height - size) / 2
        text([label], size: size, x: frame.x, width: width, align: .center, level: theme.onAccent, background: theme.accent,
             bold: true)
        y = frame.maxY + 10 * unit
    }

    /// A picture: an even gradient or patches like a photo
    func image(points: Int, inset: Bool = true) {
        y += 8 * unit
        let frame = SimRect(x: left + (inset ? margin : 0), y: y, width: columnWidth - (inset ? 2 * margin : 0),
                            height: points * unit)
        if random.chance(50) {
            sprite.fillGradient(frame, from: random.int(60, 200), to: random.int(60, 200), down: random.int(-40, 40))
        } else {
            sprite.fillTexture(frame, base: random.int(80, 180), spread: random.int(25, 60), random: &random)
        }
        y = frame.maxY + 8 * unit
    }

    /// Lines flush right with a ragged left edge, as in a script that is written from right to
    /// left. A recognizer returns them one by one (`TextLayout.blocks` joins lines by their left
    /// edges or their centres), so every line is a paragraph of its own here.
    func rightAlignedLines(_ count: Int, points: Int = 17) {
        let size = points * unit, width = columnWidth - 2 * margin
        begin(textOfSize: size)
        let pitch = size * 128 / 100
        var lastWidth = -width
        for index in 0..<count {
            // widths that differ clearly, so that no two lines look centred on each other
            var text = ""
            var textWidth = 0
            repeat {
                text = line(width: width * random.int(45, 100) / 100, size: size, bold: false, capitalized: index == 0)
                textWidth = SimFont.width(of: text, size: size)
            } while abs(textWidth - lastWidth) < 2 * size
            lastWidth = textWidth
            let lineX = left + margin + width - textWidth, lineY = y + index * pitch
            sprite.drawText(text, x: lineX, y: lineY, size: size, level: theme.text)
            let member = sprite.addLine(text, alternate: words.misreading(of: text),
                                        rect: SimRect(x: lineX, y: lineY, width: textWidth, height: size))
            sprite.addParagraph(lines: [member], background: theme.background, foreground: theme.text)
        }
        y += (count - 1) * pitch + size
        end(textOfSize: size)
        y += 6 * unit
    }

    /// A dark picture with a line of light text set into it
    func captionedImage(points: Int) {
        y += 8 * unit
        let frame = SimRect(x: left + margin, y: y, width: columnWidth - 2 * margin, height: points * unit)
        let base = random.int(60, 100)
        sprite.fillTexture(frame, base: base, spread: random.int(12, 28), random: &random)
        let size = 20 * unit
        let label = line(width: (frame.width - 24 * unit) * random.int(40, 85) / 100, size: size, bold: true, capitalized: true)
        let labelX = frame.x + 12 * unit, labelY = frame.maxY - size - 14 * unit
        let level = SimLevel.clamped(236)
        sprite.drawText(label, x: labelX, y: labelY, size: size, level: level, bold: true)
        let member = sprite.addLine(label, alternate: words.misreading(of: label),
                                    rect: SimRect(x: labelX, y: labelY, width: SimFont.width(of: label, size: size, bold: true),
                                                  height: size))
        sprite.addParagraph(lines: [member], background: UInt8(base), foreground: level)
        y = frame.maxY + 8 * unit
        textBottom = labelY + size
        textSize = size
    }

    /// A card with a picture, a headline and a short text
    func card() {
        y += 10 * unit
        let top = y
        let x = left + margin, width = columnWidth - 2 * margin
        let pictureHeight = random.int(90, 150) * unit
        // the card first, as tall as it can get; cut to its height at the end
        sprite.fill(SimRect(x: x, y: top, width: width, height: pictureHeight + 110 * unit), level: theme.card)
        sprite.fillTexture(SimRect(x: x, y: top, width: width, height: pictureHeight), base: random.int(80, 180),
                           spread: random.int(25, 60), random: &random)
        y = top + pictureHeight + 10 * unit
        let inner = width - 24 * unit
        let headline = line(width: inner * random.int(50, 95) / 100, size: 17 * unit, bold: true, capitalized: true)
        text([headline], size: 17 * unit, x: x + 12 * unit, width: inner, align: .left, level: theme.text,
             background: theme.card, bold: true)
        y += 5 * unit
        var lines: [String] = []
        for index in 0..<random.int(1, 2) {
            lines.append(line(width: inner * (index == 0 ? 100 : random.int(30, 80)) / 100, size: 13 * unit, bold: false,
                              capitalized: index == 0))
        }
        text(lines, size: 13 * unit, x: x + 12 * unit, width: inner, align: .left, level: theme.secondary,
             background: theme.card)
        y += 12 * unit
        let used = y - top
        sprite.fill(SimRect(x: x, y: y, width: width, height: pictureHeight + 110 * unit - used), level: theme.background)
        y += 6 * unit
    }

    /// The band over a section of a list
    func sectionHeader() {
        let size = 13 * unit, height = 32 * unit
        let band = SimRect(x: left, y: y, width: columnWidth, height: height)
        sprite.fill(band, level: theme.card)
        let label = words.word(minLength: 5, maxLength: 9, capitalized: true) + " " + words.word(minLength: 3, maxLength: 7)
        sprite.addText(label, alternate: words.misreading(of: label), x: left + margin, y: y + (height - size) / 2,
                       size: size, level: theme.secondary, background: theme.card, bold: true)
        sections.append(band)
        y = band.maxY
        textBottom = y - (height - size) / 2
        textSize = size
    }

    /// Rows with a label, sometimes an icon in front and a value at the right, and a thin line
    /// under each
    func list(rows: Int, kind: SimListKind, points: Int = 48, icons: Bool = false, values: Bool = false,
              everyNthDistinct: Int = 0) {
        let size = 17 * unit, height = points * unit
        // the first label keeps its distance from text above the list
        y = max(y, textBottom + max(size, textSize) + 3 * unit - (height - size) / 2)
        let labelX = left + margin + (icons ? 40 * unit : 0)
        let shared = words.word(minLength: 5, maxLength: 8, capitalized: true)
        let sharedAlternate = words.misreading(of: shared)
        let iconLevel = theme.accent
        for row in 0..<rows {
            let top = y + row * height
            var label: String, alternate: String
            switch kind {
            case .distinct:
                label = words.word(minLength: 4, maxLength: 9, capitalized: true)
                if random.chance(50) { label += " " + words.word(minLength: 3, maxLength: 8) }
                alternate = words.misreading(of: label)
            case .alike:
                label = shared + " " + words.word(minLength: 3, maxLength: 3)
                alternate = words.misreading(of: label)
            case .identical:
                label = shared
                alternate = sharedAlternate
            }
            if everyNthDistinct > 0, row % everyNthDistinct == everyNthDistinct - 1 {
                label = words.word(minLength: 4, maxLength: 9, capitalized: true) + " "
                    + words.word(minLength: 3, maxLength: 8)
                alternate = words.misreading(of: label)
            }
            if icons {
                sprite.fill(SimRect(x: left + margin, y: top + (height - 28 * unit) / 2, width: 28 * unit,
                                    height: 28 * unit), level: iconLevel)
            }
            sprite.addText(label, alternate: alternate, x: labelX, y: top + (height - size) / 2, size: size,
                           level: theme.text, background: theme.background)
            if values {
                // a number (nothing to translate) or a word, flush right
                let small = 15 * unit
                var shown = "12:30"
                if kind != .identical {
                    shown = random.chance(60) ? words.number() : words.word(minLength: 3, maxLength: 7)
                }
                let valueWidth = SimFont.width(of: shown, size: small)
                sprite.addText(shown, alternate: TextLayout.isTranslatable(shown) ? words.misreading(of: shown) : shown,
                               x: left + columnWidth - margin - 14 * unit - valueWidth, y: top + (height - small) / 2,
                               size: small, level: theme.secondary, background: theme.background)
            }
            // a chevron and the line under the row
            sprite.fill(SimRect(x: left + columnWidth - margin - 6 * unit, y: top + height / 2 - 4 * unit, width: 3 * unit,
                                height: 8 * unit), level: theme.separator)
            sprite.fill(SimRect(x: labelX, y: top + height - 1, width: left + columnWidth - labelX, height: 1),
                        level: theme.separator)
        }
        y += rows * height
        textBottom = y - (height - size) / 2
        textSize = size
    }

    /// An empty box, for a layer of its own on top of the page; returns it in pixels of the sprite
    func reserve(points: Int) -> SimRect {
        y += 8 * unit
        let box = SimRect(x: left, y: y, width: columnWidth, height: points * unit)
        y = box.maxY + 8 * unit
        return box
    }

    /// Adds items of a profile until the page is filled down to `bottom`
    func fill(_ profile: SimPageProfile, to bottom: Int) {
        while y < bottom - 60 * unit {
            let pick = random.below(100)
            switch profile {
            case .article:
                if pick < 12 {
                    heading(points: random.chance(40) ? 28 : 22, centered: random.chance(25))
                } else if pick < 72 {
                    paragraph(lines: random.int(1, 6), points: random.chance(20) ? 15 : 17,
                              level: random.chance(15) ? theme.secondary : nil, align: random.chance(12) ? .center : .left)
                } else if pick < 82 {
                    image(points: random.int(90, 220))
                } else if pick < 88 {
                    button()
                } else if pick < 95 {
                    paragraph(lines: random.int(1, 3), points: 13, level: theme.secondary)
                } else {
                    gap(random.int(20, 60))
                }
            case .settings:
                if pick < 15 {
                    heading(points: 22)
                } else if pick < 80 {
                    list(rows: random.int(3, 8), kind: .distinct, points: random.int(44, 56), icons: random.chance(50),
                         values: random.chance(60))
                    gap(random.int(12, 30))
                } else {
                    paragraph(lines: random.int(1, 3), points: 13, level: theme.secondary)
                }
            case .feed:
                if pick < 75 {
                    card()
                } else if pick < 90 {
                    heading(points: 22)
                } else {
                    paragraph(lines: random.int(1, 3))
                }
            case .sparse:
                if pick < 40 {
                    gap(random.int(120, 320))
                } else if pick < 65 {
                    image(points: random.int(140, 300), inset: random.chance(50))
                } else if pick < 85 {
                    paragraph(lines: random.int(1, 2), align: random.chance(50) ? .center : .left)
                } else {
                    heading(centered: true)
                }
            case .alike:
                if pick < 85 {
                    list(rows: random.int(8, 16), kind: .alike, points: random.int(44, 52), icons: true,
                         values: random.chance(40))
                    gap(random.int(8, 24))
                } else {
                    heading(points: 22)
                }
            case .identical:
                if pick < 85 {
                    list(rows: random.int(8, 16), kind: .identical, points: random.int(44, 52), icons: random.chance(60),
                         values: random.chance(40), everyNthDistinct: random.chance(50) ? random.int(4, 7) : 0)
                    gap(random.int(8, 24))
                } else {
                    paragraph(lines: random.int(1, 2))
                }
            case .sections:
                sectionHeader()
                list(rows: random.int(4, 9), kind: .distinct, points: random.int(44, 52), icons: random.chance(40),
                     values: random.chance(50))
            case .typography:
                if pick < 12 {
                    heading(points: 40)
                } else if pick < 30 {
                    paragraph(lines: random.int(2, 5), points: 11, level: theme.secondary)
                } else if pick < 45 {
                    paragraph(lines: random.int(1, 3), level: theme.faint)
                } else if pick < 62 {
                    rightAlignedLines(random.int(2, 4))
                } else if pick < 76 {
                    captionedImage(points: random.int(110, 180))
                } else if pick < 92 {
                    paragraph(lines: random.int(1, 4), align: random.chance(40) ? .center : .left)
                } else {
                    gap(random.int(10, 30))
                }
            }
        }
    }
}
