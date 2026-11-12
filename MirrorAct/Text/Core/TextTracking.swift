// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Values exchanged between the text recognition, the tracker that keeps translations on their
// text while the content moves (`OverlayTracker`) and the code that draws them into the frames.
// All rectangles are in pixels of the frame, origin at the top left, y pointing down.

/// A color, components 0…255 (sRGB)
struct RGBColor: Equatable, Hashable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    static let black = RGBColor(red: 0, green: 0, blue: 0)
    static let white = RGBColor(red: 255, green: 255, blue: 255)

    /// perceived brightness 0…255
    var luma: Int { (299 * Int(red) + 587 * Int(green) + 114 * Int(blue)) / 1000 }
}

/// Colors of a piece of text on the screen
struct BlockColors: Equatable {
    /// what lies behind the text
    var background: RGBColor
    /// the text itself
    var foreground: RGBColor

    static let blackOnWhite = BlockColors(background: .white, foreground: .black)

    /// From pixels sampled inside the rectangle of a text block (in any order): the color most
    /// of them share is the background; the text is the color farthest from it, or black or
    /// white when the block shows no clear second color.
    static func estimate(pixels: [RGBColor]) -> BlockColors {
        guard !pixels.isEmpty else { return .blackOnWhite }
        // most frequent color, counted in steps of 16 per channel
        var counts: [Int: Int] = [:]
        for pixel in pixels {
            counts[bin(pixel), default: 0] += 1
        }
        var bestBin = 0, bestCount = -1
        for (key, count) in counts where count > bestCount || (count == bestCount && key < bestBin) {
            bestBin = key
            bestCount = count
        }
        let background = mean(pixels.filter { bin($0) == bestBin })

        var farthest = 0
        for pixel in pixels {
            farthest = max(farthest, distance(pixel, background))
        }
        guard farthest >= 96 else {
            return BlockColors(background: background, foreground: background.luma < 128 ? .white : .black)
        }
        // the core of the strokes; pixels on their edges are mixtures with the background
        let strokes = pixels.filter { distance($0, background) * 10 >= farthest * 7 }
        return BlockColors(background: background, foreground: mean(strokes))
    }

    private static func bin(_ color: RGBColor) -> Int {
        (Int(color.red) >> 4) << 8 | (Int(color.green) >> 4) << 4 | Int(color.blue) >> 4
    }

    private static func distance(_ a: RGBColor, _ b: RGBColor) -> Int {
        abs(Int(a.red) - Int(b.red)) + abs(Int(a.green) - Int(b.green)) + abs(Int(a.blue) - Int(b.blue))
    }

    private static func mean(_ colors: [RGBColor]) -> RGBColor {
        guard !colors.isEmpty else { return .white }
        var red = 0, green = 0, blue = 0
        for color in colors {
            red += Int(color.red)
            green += Int(color.green)
            blue += Int(color.blue)
        }
        let count = colors.count
        return RGBColor(red: UInt8((red + count / 2) / count), green: UInt8((green + count / 2) / count),
                        blue: UInt8((blue + count / 2) / count))
    }
}

/// A paragraph found by text recognition, in pixels of the frame it was read from
struct RecognizedBlock: Equatable {
    var text: String
    var rect: CGRect
    var lineCount: Int
    var colors: BlockColors
    /// 0…1 where the recognizer says how sure it is, nil otherwise
    var confidence: Double?

    init(text: String, rect: CGRect, lineCount: Int = 1, colors: BlockColors = .blackOnWhite, confidence: Double? = nil) {
        self.text = text
        self.rect = rect
        self.lineCount = lineCount
        self.colors = colors
        self.confidence = confidence
    }
}

/// A paragraph the tracker follows from frame to frame
struct TrackedBlock: Equatable {
    let id: Int
    /// the text as recognized
    var text: String
    /// where it is in the current frame
    var rect: CGRect
    var lineCount: Int
    var colors: BlockColors
    /// nil = nothing to show: not translated yet, or the translation equals the text
    var translation: String?
    /// the translation shown belongs to an earlier reading of this place; a new one is on its way
    var isStale: Bool
}

/// A translation to draw into the current frame
struct PlacedBlock: Equatable {
    var id: Int
    /// the translated text
    var text: String
    /// rectangle of the original text in this frame; may lie between pixels
    var rect: CGRect
    /// the part of `rect` that is visible when something that does not scroll (a title bar, a
    /// tab bar) hides the rest; nil = all of it. Nothing may be drawn outside of it.
    var visibleRect: CGRect?
    var lineCount: Int
    var colors: BlockColors
}

/// What happened between the previous frame and this one
enum FrameChange: Equatable {
    /// first frame after a start or `reset`
    case first
    /// same picture
    case unchanged
    /// content moved (scrolled); the blocks moved with it
    case scrolled
    /// the picture changed in some other way
    case changed
    /// the frames have a new size: everything was forgotten
    case resized
}

/// Result of `OverlayTracker.advance` for one frame
struct FrameUpdate: Equatable {
    var change: FrameChange
    /// movement of the scrolled content since the previous frame in frame pixels, x to the right
    /// and y down; zero unless `change` is `.scrolled`
    var scrollX: Double
    var scrollY: Double
    /// translations to draw into this frame, in drawing order
    var placed: [PlacedBlock]
    /// When `OverlayTracker.beginRecognition` should be called (same clock as `advance`; a time
    /// in the past means now). nil = nothing to read, or a pass is running. A still picture
    /// produces no further frames, so the caller needs a timer for this.
    var recognitionDue: TimeInterval?
}

/// A part of the frame that the text recognition should read
struct RecognitionRequest: Equatable {
    let id: Int
    /// the part to read
    let region: CGRect
    /// `region` is the whole frame
    let isFullFrame: Bool
}
