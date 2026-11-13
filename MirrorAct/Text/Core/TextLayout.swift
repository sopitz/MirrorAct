// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
// CGRect is a Foundation type on Linux; on Apple platforms its members come with CoreGraphics
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A line of text found on the screen. `rect` is in image coordinates 0…1, origin at the top left.
struct RecognizedLine: Equatable {
    var text: String
    var rect: CGRect
    /// 0…1 where the recognizer says how sure it is, nil otherwise
    var confidence: Double?

    init(text: String, rect: CGRect, confidence: Double? = nil) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}

/// Lines that belong together (a paragraph); `rect` like `RecognizedLine.rect`
struct TextBlock: Equatable {
    var text: String
    var rect: CGRect
    var lineCount: Int
    /// that of the least certain line, nil when the recognizer reports none
    var confidence: Double?
    /// The edges (`FrameMotion.top`, `.bottom`) beyond which the paragraph goes on, hidden: it is
    /// a line of which only a part shows and that was read as garbage (then both), or such a line
    /// lies right above or below it (see `TextLayout.blocks`). Such a paragraph is not complete.
    var cutOffEdges: Int

    init(text: String, rect: CGRect, lineCount: Int, confidence: Double? = nil, cutOffEdges: Int = 0) {
        self.text = text
        self.rect = rect
        self.lineCount = lineCount
        self.confidence = confidence
        self.cutOffEdges = cutOffEdges
    }
}

/// Puts recognized lines in order: as plain text and as paragraphs for translating.
///
/// The height of a line's box says little about the size of its text: Vision's box reaches from
/// the highest to the lowest ink of the line, so lines of one paragraph differ by half their
/// height and more depending on ascenders, descenders and accents on capitals. The width does not
/// depend on that: the size of the text is measured from the width of the line and the letters
/// it holds (`textSize`).
enum TextLayout {
    /// Top to bottom; lines at the same height from left to right
    static func readingOrder(_ lines: [RecognizedLine]) -> [[RecognizedLine]] {
        var rows: [[RecognizedLine]] = []
        for line in lines.sorted(by: { $0.rect.midY < $1.rect.midY }) {
            if let first = rows.last?.first,
               abs(line.rect.midY - first.rect.midY) < min(first.rect.height, line.rect.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { $0.sorted { $0.rect.minX < $1.rect.minX } }
    }

    /// All text the way it reads when pasted somewhere: one paragraph per line (its lines on the
    /// screen joined), in reading order. Left out: lines cut off at the top or bottom edge of the
    /// picture or by something in front of them (of which only part shows, see `blocks`), and a
    /// status bar (lines in the top `statusBarShare` of the picture).
    static func plainText(_ lines: [RecognizedLine], imageSize: CGSize) -> String {
        let edge = Double(imageSize.height) * screenEdgeShare
        let kept = lines.filter { line in
            let top = Double(line.rect.minY * imageSize.height), bottom = Double(line.rect.maxY * imageSize.height)
            return bottom > Double(imageSize.height) * statusBarShare && top > edge
                && bottom < Double(imageSize.height) - edge
        }
        let whole = measure(kept, imageSize: imageSize).filter { !$0.1.isPart }.map(\.0)
        return blocks(whole, imageSize: imageSize).map(\.text).joined(separator: "\n")
    }

    /// Joins the lines of a paragraph. `imageSize` in pixels, because x and y of the rects have
    /// different scales. A line continues the paragraph above it when
    /// - its text has the same size: their sizes (`textSize`) are within `sameSize` (`sameSizeShort`
    ///   when a line is short). Lines that lie as close as lines of a paragraph do (a gap of less
    ///   than `closeGap` of the higher box) are split only by a size that is `clearlyLarger` and a
    ///   box that is higher by more than `sameBoxHeight` as well: the size measured from the width
    ///   alone is not trusted to split lines that close. When a line is too short to measure, the
    ///   box heights are compared instead (within `sameHeight`).
    /// - the gap between the two boxes is less than `paragraphGap` of the height of a line (the
    ///   larger text size, kept between `sizeUnderBox` and `sizeOverBox` times the higher box: a
    ///   box is higher than its text with accents on capitals and descenders; a box may also
    ///   reach into the one above by up to `overlap` of the higher box),
    /// - their left edges or their centres are within `alignment` of the height of a line,
    /// - neither shows only part of its letters, and it does not start a list item ("• …").
    /// Of several paragraphs it could continue, it continues the last one begun.
    ///
    /// Part of a line shows (something hides the rest: a bar, the edge of the screen or of the
    /// part that was read) when its box is lower than `partHeight` of its text size and at most
    /// `partOfNeighbour` of the box of a line right above or below it that could be the next
    /// line of its paragraph. (The low box alone does not tell: with letters of unusual widths the
    /// text size comes out too large.) A line whose box is even lower than `cutOffHeight` of its
    /// text size (`looksCutOff`) was read mostly as garbage; near the top or bottom edge of the
    /// picture (within `edgeReach` times its text size), where bars lie, it needs no line next to
    /// it to tell. A part of a line is a block of its own; one read as garbage and the paragraph
    /// it would continue or that would continue it are marked as going on beyond it
    /// (`TextBlock.cutOffEdges`).
    static func blocks(_ lines: [RecognizedLine], imageSize: CGSize) -> [TextBlock] {
        struct Open {
            var block: TextBlock
            var first: Measured
            var last: Measured
        }
        var open: [Open] = []
        for (line, measured) in measure(lines, imageSize: imageSize) {
            let match = open.lastIndex { candidate in
                continues(candidate.last, with: measured)
            }
            if let match {
                open[match].block.text += separator(after: open[match].block.text) + line.text
                open[match].block.rect = open[match].block.rect.union(line.rect)
                open[match].block.lineCount += 1
                if let confidence = line.confidence {
                    open[match].block.confidence = min(open[match].block.confidence ?? confidence, confidence)
                }
                open[match].last = measured
            } else {
                let cutOff = measured.isPart && measured.isCutOff ? FrameMotion.top | FrameMotion.bottom : 0
                open.append(Open(block: TextBlock(text: line.text, rect: line.rect, lineCount: 1,
                                                  confidence: line.confidence, cutOffEdges: cutOff),
                                 first: measured, last: measured))
            }
        }
        let cutOff = open.map(\.last).filter { $0.isPart && $0.isCutOff }
        for index in open.indices where !open[index].last.isPart {
            for line in cutOff {
                if adjoins(open[index].last, below: line, size: open[index].last.size) {
                    open[index].block.cutOffEdges |= FrameMotion.bottom
                }
                if adjoins(line, below: open[index].first, size: open[index].first.size) {
                    open[index].block.cutOffEdges |= FrameMotion.top
                }
            }
        }
        return open.map(\.block)
    }

    /// The lines in reading order, measured (pixels, text size, whether only part shows)
    private static func measure(_ lines: [RecognizedLine], imageSize: CGSize) -> [(RecognizedLine, Measured)] {
        var all = readingOrder(lines).flatMap { $0 }.map { line in
            let rect = CGRect(x: line.rect.minX * imageSize.width, y: line.rect.minY * imageSize.height,
                              width: line.rect.width * imageSize.width, height: line.rect.height * imageSize.height)
            let units = widthUnits(of: line.text)
            return (line, Measured(rect: rect, units: units, size: units >= minUnits ? Double(rect.width) / units : nil,
                                   isLow: isLow(line.text, width: Double(rect.width), height: Double(rect.height),
                                                share: partHeight),
                                   isCutOff: looksCutOff(line.text, width: Double(rect.width), height: Double(rect.height)),
                                   isPart: false, startsListItem: startsListItem(line.text)))
        }
        for index in all.indices where all[index].1.isLow {
            let line = all[index].1
            // (near the top or bottom of the picture, where bars lie, a box low enough for garbage
            // is cut off without a line next to it to compare)
            let nearEdge = line.size.map { size in
                Double(line.rect.minY) < edgeReach * size || Double(imageSize.height - line.rect.maxY) < edgeReach * size
            } ?? false
            all[index].1.isPart = (line.isCutOff && nearEdge) || all.contains { _, neighbour in
                Double(line.rect.height) <= partOfNeighbour * Double(neighbour.rect.height)
                    && (adjoins(neighbour, below: line, size: neighbour.size)
                        || adjoins(line, below: neighbour, size: neighbour.size))
            }
        }
        return all
    }

    /// A line as `blocks` compares it with others
    private struct Measured {
        /// in pixels
        var rect: CGRect
        var units: Double
        /// nil = too short to tell
        var size: Double?
        /// the box is lower than `partHeight` of the text size …
        var isLow: Bool
        /// … or even lower than `cutOffHeight`
        var isCutOff: Bool
        /// only part of its letters show (see `blocks`)
        var isPart: Bool
        var startsListItem: Bool
    }

    /// Whether `line` is the next line of the paragraph whose last line is `last`
    private static func continues(_ last: Measured, with line: Measured) -> Bool {
        guard !last.isPart, !line.isPart, !line.startsListItem else { return false }
        if let lastSize = last.size, let size = line.size {
            let limit = min(last.units, line.units) >= shortUnits ? sameSize : sameSizeShort
            let ratio = max(lastSize, size) / min(lastSize, size)
            if ratio > limit {
                let gap = Double(line.rect.minY - last.rect.maxY)
                // the box of the line with the larger text, against the other one
                let larger = Double(lastSize > size ? last.rect.height : line.rect.height)
                let smaller = Double(lastSize > size ? line.rect.height : last.rect.height)
                guard gap < closeGap * max(larger, smaller),
                      ratio <= clearlyLarger || larger <= sameBoxHeight * smaller else { return false }
            }
        } else {
            let higher = Double(max(last.rect.height, line.rect.height))
            guard higher <= sameHeight * Double(min(last.rect.height, line.rect.height)) else { return false }
        }
        var size: Double?
        if let lastSize = last.size, let lineSize = line.size { size = max(lastSize, lineSize) }
        return adjoins(last, below: line, size: size)
    }

    /// Whether `lower` lies right below `upper` as the next line of a paragraph would: close below
    /// it and aligned with it. Distances count in the height of a line: the text `size`, kept
    /// between `sizeUnderBox` and `sizeOverBox` times the higher of the two boxes (a size
    /// measured from letters of unusual widths may be far off); the box when the size is nil.
    private static func adjoins(_ upper: Measured, below lower: Measured, size: Double?) -> Bool {
        let box = Double(max(upper.rect.height, lower.rect.height))
        let lineHeight = min(max(size ?? box, sizeUnderBox * box), sizeOverBox * box)
        let gap = Double(lower.rect.minY - upper.rect.maxY)
        return gap > -overlap * box && gap < paragraphGap * lineHeight
            && (abs(Double(upper.rect.minX - lower.rect.minX)) < alignment * lineHeight
                || abs(Double(upper.rect.midX - lower.rect.midX)) < alignment * lineHeight)
    }

    // MARK: Size of text

    /// Lines of one paragraph measure within this factor of each other …
    static let sameSize = 1.18
    /// … or within this one when a line has fewer than `shortUnits` (a few letters)
    static let sameSizeShort = 1.3
    static let shortUnits = 4.0
    /// lines closer than this share of the higher box are of different sizes only when one
    /// measures larger by this factor and its box is higher by `sameBoxHeight`
    static let closeGap = 0.4
    static let clearlyLarger = 1.3
    static let sameBoxHeight = 1.15
    /// a line of fewer units is too short to measure; its box height is compared instead, within
    /// this factor
    static let minUnits = 2.0
    static let sameHeight = 1.5
    /// largest gap between two lines of a paragraph, as a share of the height of a line
    static let paragraphGap = 0.7
    static let sizeUnderBox = 0.8
    static let sizeOverBox = 1.25
    /// how far a line's box may reach into the box above, as a share of the higher box
    static let overlap = 0.3
    /// how far left edges or centres of the lines of a paragraph may lie apart, as a share of the
    /// height of a line
    static let alignment = 0.6
    /// a box lower than this share of the size of its text and at most `partOfNeighbour` of the
    /// box of the line next to it holds only part of its letters; one lower than `cutOffHeight`
    /// of its size was read as garbage
    static let partHeight = 0.78
    static let partOfNeighbour = 0.75
    static let cutOffHeight = 0.62
    static let edgeReach = 2.0
    /// `plainText`: the status bar lies in this top share of the picture; a line within this share
    /// of the top or bottom edge is cut off there
    static let statusBarShare = 0.04
    static let screenEdgeShare = 0.004

    /// The size of the text of a line (about the height of its font, in the units of `width`),
    /// measured from its width: `width` divided by `widthUnits`. nil when the text is too short to
    /// tell (less than `minUnits`).
    static func textSize(of text: String, width: Double) -> Double? {
        let units = widthUnits(of: text)
        return units >= minUnits ? width / units : nil
    }

    /// How wide a text is in units of the size of its font, as an average sans-serif typeface sets
    /// it: a space 0.28, i j l f t r I and narrow punctuation 0.3, m w M W 0.85, other capitals
    /// 0.66, digits 0.55, other letters and signs 0.52, Chinese, Japanese and Korean characters
    /// and full-width forms 1. A full stop or comma of these scripts at the end of a line counts
    /// 0.4: its ink sits at the left of its cell, and the box of the line ends there.
    static func widthUnits(of text: String) -> Double {
        var units = 0.0
        var last: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            units += widthUnits(of: scalar)
            last = scalar
        }
        if let last, [0x3001, 0x3002, 0xFF0C, 0xFF0E].contains(last.value) { units -= 0.6 }
        return units
    }

    private static func widthUnits(of scalar: Unicode.Scalar) -> Double {
        switch scalar.value {
        case 0x20: return 0.28
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFF60, 0xFFE0...0xFFE6: return 1
        default: break
        }
        if "ijlI.,:;'!|ftr()[]-/\"\u{201E}\u{201C}\u{201D}\u{2018}\u{2019}".unicodeScalars.contains(scalar) { return 0.3 }
        if "mwMW".unicodeScalars.contains(scalar) { return 0.85 }
        if scalar.properties.isUppercase { return 0.66 }
        if (0x30...0x39).contains(scalar.value) { return 0.55 }
        return 0.52
    }

    /// Whether a line's box (`width` and `height` in pixels) is too low for its text, as when
    /// something hides part of the line. Only said of text with tall letters (capitals, digits,
    /// ascenders, Chinese, Japanese or Korean): a line of x-height letters alone is low anyway.
    static func looksCutOff(_ text: String, width: Double, height: Double) -> Bool {
        isLow(text, width: width, height: height, share: cutOffHeight)
    }

    /// Whether the box is lower than `share` of the text size, for text with tall letters
    private static func isLow(_ text: String, width: Double, height: Double, share: Double) -> Bool {
        guard let size = textSize(of: text, width: width), height < share * size else { return false }
        return text.unicodeScalars.contains { scalar in
            scalar.properties.isUppercase || (0x30...0x39).contains(scalar.value) || "bdfhklt".unicodeScalars.contains(scalar)
                || (0x2E80...0xD7AF).contains(scalar.value)
        }
    }

    /// A bullet and a space at the start: an item of a list, not the next line of a paragraph
    private static func startsListItem(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.prefix(2))
        guard scalars.count == 2, scalars[1] == " " else { return false }
        return "•◦▪‣●○■□–—*".unicodeScalars.contains(scalars[0])
    }

    /// Space between two lines of a paragraph; none in scripts written without spaces
    private static func separator(after text: String) -> String {
        guard let scalar = text.unicodeScalars.last else { return "" }
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x9FFF, 0xFF00...0xFFEF, 0x3000...0x303F: return ""
        default: return " "
        }
    }

    /// Worth translating: contains at least two letters (not a time, a price or a symbol)
    static func isTranslatable(_ text: String) -> Bool {
        var letters = 0
        for character in text where character.isLetter {
            letters += 1
            if letters >= 2 { return true }
        }
        return false
    }
}
