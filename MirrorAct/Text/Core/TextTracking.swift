// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
// CGRect is a Foundation type on Linux; on Apple platforms its members come with CoreGraphics
#if canImport(CoreGraphics)
import CoreGraphics
#endif

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
    var background: RGBColor {
        didSet { backgroundInVideo = nil }
    }
    /// the text itself
    var foreground: RGBColor {
        didSet { foregroundInVideo = nil }
    }
    /// The same colors as the 4:2:0 frame they were read from stores them (see
    /// `estimate(samples:fullRange:)`), so that they can be written back exactly; nil when they
    /// were not read from such a frame, or were changed since. Converting RGB back would not
    /// do: the frame's own matrix may differ from the one `YCbCrColor` uses, and saturated
    /// colors then lie outside of RGB.
    var backgroundInVideo: VideoColor?
    var foregroundInVideo: VideoColor?

    static let blackOnWhite = BlockColors(background: .white, foreground: .black)

    /// From pixels sampled inside the rectangle of a text block (in any order): the color most
    /// of them share is the background; the text is the color farthest from it, or black or
    /// white when the block shows no clear second color.
    static func estimate(pixels: [RGBColor]) -> BlockColors {
        guard let choice = choose(pixels) else { return .blackOnWhite }
        return colors(of: pixels, choice)
    }

    /// The same from samples of a 4:2:0 frame: the colors are chosen as RGB, exactly as by
    /// `estimate(pixels:)`, and also kept as the frame stores them, as the mean of the same samples.
    static func estimate(samples: [YCbCrColor], fullRange: Bool) -> BlockColors {
        let pixels = samples.map { $0.rgb(fullRange: fullRange) }
        guard let choice = choose(pixels) else { return .blackOnWhite }
        var result = colors(of: pixels, choice)
        result.backgroundInVideo = VideoColor(color: mean(choice.background.map { samples[$0] }), fullRange: fullRange)
        if let strokes = choice.strokes {
            result.foregroundInVideo = VideoColor(color: mean(strokes.map { samples[$0] }), fullRange: fullRange)
        }
        return result
    }

    private static func colors(of pixels: [RGBColor], _ choice: (background: [Int], strokes: [Int]?)) -> BlockColors {
        let background = mean(choice.background.map { pixels[$0] })
        guard let strokes = choice.strokes else {
            return BlockColors(background: background, foreground: background.luma < 128 ? .white : .black)
        }
        return BlockColors(background: background, foreground: mean(strokes.map { pixels[$0] }))
    }

    /// Which of the pixels make up the background and which the core of the strokes; strokes
    /// nil when the block shows no clear second color. nil for no pixels.
    private static func choose(_ pixels: [RGBColor]) -> (background: [Int], strokes: [Int]?)? {
        guard !pixels.isEmpty else { return nil }
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
        let backgroundIndices = pixels.indices.filter { bin(pixels[$0]) == bestBin }
        let background = mean(backgroundIndices.map { pixels[$0] })

        var farthest = 0
        for pixel in pixels {
            farthest = max(farthest, distance(pixel, background))
        }
        guard farthest >= 96 else { return (backgroundIndices, nil) }
        // the core of the strokes; pixels on their edges are mixtures with the background
        return (backgroundIndices, pixels.indices.filter { distance(pixels[$0], background) * 10 >= farthest * 7 })
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

    private static func mean(_ colors: [YCbCrColor]) -> YCbCrColor {
        guard !colors.isEmpty else { return YCbCrColor(y: 128, cb: 128, cr: 128) }
        var y = 0, cb = 0, cr = 0
        for color in colors {
            y += Int(color.y)
            cb += Int(color.cb)
            cr += Int(color.cr)
        }
        let count = colors.count
        return YCbCrColor(y: UInt8((y + count / 2) / count), cb: UInt8((cb + count / 2) / count),
                          cr: UInt8((cr + count / 2) / count))
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
    /// The edges (`FrameMotion.top`, `.bottom`) beyond which the paragraph may go on, hidden: a
    /// line there may have been read only in part (`TextBlock.cutOffEdges`). It is taken once the
    /// picture rests and the place was read again.
    var cutOffEdges: Int
    /// A line of which only a part shows, read as garbage beyond doubt (`TextBlock.isGarbled`):
    /// it is never taken
    var isGarbled: Bool

    init(text: String, rect: CGRect, lineCount: Int = 1, colors: BlockColors = .blackOnWhite, confidence: Double? = nil,
         cutOffEdges: Int = 0, isGarbled: Bool = false) {
        self.text = text
        self.rect = rect
        self.lineCount = lineCount
        self.colors = colors
        self.confidence = confidence
        self.cutOffEdges = cutOffEdges
        self.isGarbled = isGarbled
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
