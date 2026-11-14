// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A rectangle of whole pixels of a frame: the columns `minX ..< maxX` of the rows
/// `minY ..< maxY`. Rows are counted from the top, like everything else about the frames.
struct PixelRect: Equatable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
    var isEmpty: Bool { maxX <= minX || maxY <= minY }

    var cgRect: CGRect {
        CGRect(x: CGFloat(minX), y: CGFloat(minY), width: CGFloat(width), height: CGFloat(height))
    }

    func intersection(_ other: PixelRect) -> PixelRect {
        PixelRect(minX: max(minX, other.minX), minY: max(minY, other.minY),
                  maxX: min(maxX, other.maxX), maxY: min(maxY, other.maxY))
    }

    /// larger by `margin` pixels on every side
    func grown(by margin: Int) -> PixelRect {
        PixelRect(minX: minX - margin, minY: minY - margin, maxX: maxX + margin, maxY: maxY + margin)
    }
}

/// Where the translation of a block goes in a frame.
///
/// The tracker moves the blocks by fractions of a pixel. They are drawn at whole pixels: a box
/// whose edges lie between two pixels would get soft edges that flicker while the content
/// scrolls. The size is rounded on its own, not as the difference of two rounded edges, so
/// that a block keeps its size (and with it its drawn text) while it moves.
struct BlockPlacement: Equatable {
    /// the place of the original text; the translation is set into it
    let text: PixelRect
    /// what gets painted over: `text` and a margin around it
    let backdrop: PixelRect
    /// of the corners of `backdrop`
    let cornerRadius: CGFloat
    /// `PlacedBlock.visibleRect` in whole pixels, with the margin on the sides where nothing
    /// hides the block; nil = nothing hides a part of it
    let visible: PixelRect?
    /// the pixels of the frame that the block may change: `backdrop` within the frame and
    /// within `visible`
    let area: PixelRect

    /// longest side of a block and most pixels it may have; anything larger is not a paragraph
    /// on a screen but a mistake, and its text mask would need that many bytes
    static let largestSide = 8192
    static let mostPixels = 16_000_000

    /// nil when there is nothing to draw: the block lies outside the frame or outside its
    /// visible part, or its rectangle is no usable rectangle
    init?(rect: CGRect, visibleRect: CGRect?, lineCount: Int, frameWidth: Int, frameHeight: Int) {
        guard let size = Self.textSize(of: rect), let origin = Self.wholePixels(rect.minX, rect.minY) else { return nil }
        let text = PixelRect(minX: origin.x, minY: origin.y, maxX: origin.x + size.width, maxY: origin.y + size.height)
        let lineHeight = Self.lineHeight(height: size.height, lineCount: lineCount)
        let backdrop = text.grown(by: max(2, Int((lineHeight * 0.12).rounded())))
        var area = backdrop.intersection(PixelRect(minX: 0, minY: 0, maxX: frameWidth, maxY: frameHeight))
        var visible: PixelRect?
        if let visibleRect {
            // nothing may be drawn outside of it, so one that cannot be used hides everything
            guard let topLeft = Self.wholePixels(visibleRect.minX, visibleRect.minY),
                  let bottomRight = Self.wholePixels(visibleRect.maxX, visibleRect.maxY) else { return nil }
            var part = PixelRect(minX: topLeft.x, minY: topLeft.y, maxX: bottomRight.x, maxY: bottomRight.y)
            // The visible part is that of the text, which has no margin. A side that reaches the
            // edge of the text is not hidden: there the margin stays, as on a block that is all
            // visible, and the box does not jump inward when something covers another side.
            // (Half a pixel: the tracker's rectangles differ from each other by rounding only.)
            if visibleRect.minX <= rect.minX + 0.5 { part.minX = min(part.minX, backdrop.minX) }
            if visibleRect.minY <= rect.minY + 0.5 { part.minY = min(part.minY, backdrop.minY) }
            if visibleRect.maxX >= rect.maxX - 0.5 { part.maxX = max(part.maxX, backdrop.maxX) }
            if visibleRect.maxY >= rect.maxY - 0.5 { part.maxY = max(part.maxY, backdrop.maxY) }
            area = area.intersection(part)
            visible = part
        }
        guard !area.isEmpty else { return nil }
        self.text = text
        self.backdrop = backdrop
        // a corner cannot be rounder than half a side (the margin makes every side 5 pixels or more)
        let shortSide = CGFloat(min(backdrop.width, backdrop.height))
        cornerRadius = min(8, lineHeight * 0.2, shortSide / 2)
        self.visible = visible
        self.area = area
    }

    /// Size of the block in whole pixels: the size of its text mask and, with the text, what a
    /// drawn text is remembered by. nil for a rectangle that cannot be drawn.
    static func textSize(of rect: CGRect) -> (width: Int, height: Int)? {
        let width = rect.width.rounded(), height = rect.height.rounded()
        // (comparisons with NaN are false, so it does not pass either)
        guard width >= 1, height >= 1, width <= CGFloat(largestSide), height <= CGFloat(largestSide),
              width * height <= CGFloat(mostPixels) else { return nil }
        return (Int(width), Int(height))
    }

    /// Height of one line of the original text; the size of the font and of the margin follow from it
    static func lineHeight(height: Int, lineCount: Int) -> CGFloat {
        CGFloat(height) / CGFloat(max(1, lineCount))
    }

    /// nil for coordinates that are no numbers or lie absurdly far away (they would not fit an Int)
    private static func wholePixels(_ x: CGFloat, _ y: CGFloat) -> (x: Int, y: Int)? {
        let limit: CGFloat = 1_000_000
        guard abs(x) <= limit, abs(y) <= limit else { return nil }
        return (Int(x.rounded()), Int(y.rounded()))
    }
}
