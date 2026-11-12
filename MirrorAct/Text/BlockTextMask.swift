// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation

/// The translation of a block as a picture of the size of the block: white where the text is,
/// black around it. The compositor fills the color of the text through it in every frame;
/// Core Text, which takes far longer than that, runs once per text.
///
/// The text is set in the system font, broken into lines of the width of the block and
/// centered in its height. The font is as large as fits: a translation is seldom as long as
/// its original, and it has to stay inside the place of the original.
struct BlockTextMask {
    /// size of the picture in pixels: that of the block
    let width: Int
    let height: Int
    /// 0 (no text) … 255 (text), row by row from the top, `width` bytes per row
    let pixels: [UInt8]
    /// the same picture for `CGContext.clip(to:mask:)`: gray, no alpha, the top row first
    let image: CGImage
    /// size of the font that was chosen, in pixels
    let fontSize: CGFloat
    /// lines the text was broken into
    let lineCount: Int
    /// the text of each drawn line, from the top (with the spaces it ends with)
    let lines: [String]
    /// false: too long for the block even in the smallest font; the end is cut off
    let fits: Bool

    /// The font starts at this share of the height of a line of the original. The system
    /// font is about 1.2 times its size high from ascender to descender, so a line of the
    /// translation then just fills a line of the original.
    static let largestFontShare: CGFloat = 0.82
    /// It does not get smaller than this share, nor smaller than `smallestFontSize` pixels
    /// (unless the original is that small): below that nobody can read it anyway.
    static let smallestFontShare: CGFloat = 0.28
    static let smallestFontSize: CGFloat = 9

    /// `width`, `height`: size of the block in pixels; `lineCount`: lines of the original text;
    /// `language`: BCP 47 identifier of the language of the text, which chooses the forms of
    /// characters that languages share (Japanese kanji are not drawn as Chinese hanzi); nil =
    /// as the languages of the Mac say. nil when there is nothing to draw or no picture could be made.
    init?(text: String, width: Int, height: Int, lineCount: Int, language: String? = nil) {
        // one paragraph: a line break inside a translation would cost a line the block does not have
        let text = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard width > 0, height > 0, !text.isEmpty else { return nil }
        let lineHeight = BlockPlacement.lineHeight(height: height, lineCount: lineCount)
        let box = CGSize(width: CGFloat(width), height: CGFloat(height))
        let largest = max(1, lineHeight * BlockTextMask.largestFontShare)
        let smallest = min(largest, max(lineHeight * BlockTextMask.smallestFontShare, BlockTextMask.smallestFontSize))
        let units = Array(text.utf16)

        // The largest font that fits: usually the first one tried. Otherwise halve the range
        // between a size that fits and one that does not until they are half a pixel apart.
        // A word broken between two letters does not count as fitting. When even the smallest
        // font has to break one, the word is broken at any size: then the largest size at
        // which the lines fit the block is taken, so that it is no smaller than it has to be.
        func set(_ fontSize: CGFloat) -> Layout {
            Layout(text, fontSize: fontSize, in: box, lineHeight: lineHeight, units: units, language: language)
        }
        var layout = set(largest)
        if !layout.fits, smallest < largest {
            layout = set(smallest)
            if layout.fits {
                layout = BlockTextMask.largest(from: layout, below: largest, set, fitting: \.fits)
            } else if layout.fitsBox {
                layout = BlockTextMask.largest(from: layout, below: largest, set, fitting: \.fitsBox)
            }
        }

        guard let picture = BlockTextMask.draw(layout, width: width, height: height, lineHeight: lineHeight) else { return nil }
        self.width = width
        self.height = height
        pixels = picture.pixels
        image = picture.image
        fontSize = layout.fontSize
        self.lineCount = picture.lines.count
        lines = picture.lines
        fits = layout.fitsBox
    }

    /// Halves the range between `fitting`, whose layout passes `test`, and `tooLarge` until
    /// they are half a pixel apart (six steps at most), and returns the largest layout that passed
    private static func largest(from fitting: Layout, below tooLarge: CGFloat, _ layout: (CGFloat) -> Layout,
                                fitting test: (Layout) -> Bool) -> Layout {
        var best = fitting, tooLarge = tooLarge
        var steps = 0
        while tooLarge - best.fontSize > 0.5, steps < 6 {
            let candidate = layout((best.fontSize + tooLarge) / 2)
            if test(candidate) {
                best = candidate
            } else {
                tooLarge = candidate.fontSize
            }
            steps += 1
        }
        return best
    }

    /// The text set in one font size
    private struct Layout {
        let text: String
        let fontSize: CGFloat
        let framesetter: CTFramesetter
        /// what the text needs when it is broken into lines of the width of the block
        let size: CGSize
        /// all lines fit into the block
        let fitsBox: Bool
        /// and no word had to be broken between two letters for that
        let fits: Bool

        /// `units`: the text in UTF-16 units, as Core Text counts its ranges
        init(_ text: String, fontSize: CGFloat, in box: CGSize, lineHeight: CGFloat, units: [UInt16],
             language: String?) {
            // The language picks the fonts for the characters the system font does not have
            // (Hiragino for Japanese, PingFang SC or TC for Chinese) and their local forms.
            let font = CTFontCreateUIFontForLanguage(.system, fontSize, language as CFString?)
                ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            // White, because the picture is a mask. No paragraph style: the defaults are what
            // is wanted, lines broken between words and aligned at the side the script starts from.
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
            ]
            if let language {
                attributes[NSAttributedString.Key(rawValue: kCTLanguageAttributeName as String)] = language
            }
            let string = NSAttributedString(string: text, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(string as CFAttributedString)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: 0), nil,
                CGSize(width: box.width, height: CGFloat.greatestFiniteMagnitude), nil)
            // The height of a line gets rounded to whole pixels. A line that is higher than
            // the block by that little still shows all of its letters: they do not reach the
            // upper and lower edge of their line.
            let slack = max(1, lineHeight * 0.04)
            self.text = text
            self.fontSize = fontSize
            self.framesetter = framesetter
            self.size = size
            fitsBox = size.height <= box.height + slack && size.width <= box.width + 0.5
            // A word wider than the block is broken by Core Text between two letters, without
            // a hyphen, and the size above still fits. Such a line end does not count as fitting.
            var keepsWords = true
            if fitsBox {
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: size.height + box.height + 100),
                                  transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
                let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
                for line in lines.dropLast() {
                    let range = CTLineGetStringRange(line)
                    if BlockTextMask.breaksWord(units, at: range.location + range.length) {
                        keepsWords = false
                        break
                    }
                }
            }
            fits = fitsBox && keepsWords
        }
    }

    /// Whether a line that ends at `offset` (in UTF-16 units) breaks a word: only when it ends
    /// between two letters or digits of scripts written with spaces between words. Japanese,
    /// Chinese, Korean, Thai and the like may be broken between any two characters, where Core
    /// Text chooses to for the language of the text; the rules of Unicode alone are stricter
    /// there (no break before ー or a small kana) and would count those lines as broken words.
    /// The decision depends only on the characters, not on the region or language of the Mac.
    static func breaksWord(_ units: [UInt16], at offset: Int) -> Bool {
        guard offset > 0, offset < units.count,
              let before = scalar(in: units, endingAt: offset),
              let after = scalar(in: units, startingAt: offset) else { return false }
        return isLetterOrDigitOfSpacedScript(before) && isLetterOrDigitOfSpacedScript(after)
    }

    private static func scalar(in units: [UInt16], endingAt offset: Int) -> Unicode.Scalar? {
        let last = units[offset - 1]
        if UTF16.isTrailSurrogate(last), offset >= 2, UTF16.isLeadSurrogate(units[offset - 2]) {
            return Unicode.Scalar(UInt32(0x10000) + (UInt32(units[offset - 2] - 0xD800) << 10) + UInt32(last - 0xDC00))
        }
        return Unicode.Scalar(last)
    }

    private static func scalar(in units: [UInt16], startingAt offset: Int) -> Unicode.Scalar? {
        let first = units[offset]
        if UTF16.isLeadSurrogate(first), offset + 1 < units.count, UTF16.isTrailSurrogate(units[offset + 1]) {
            return Unicode.Scalar(UInt32(0x10000) + (UInt32(first - 0xD800) << 10) + UInt32(units[offset + 1] - 0xDC00))
        }
        return Unicode.Scalar(first)
    }

    /// Letters, combining marks and digits, except those of the scripts written without spaces
    private static func isLetterOrDigitOfSpacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber:
            break
        default:
            return false
        }
        return !scriptsWithoutSpaces.contains { $0.contains(scalar.value) }
    }

    /// The blocks of the scripts that are written without spaces between words, or (Korean)
    /// that may be broken between any two syllables
    private static let scriptsWithoutSpaces: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF,   // Thai, Lao
        0x0F00...0x0FFF,   // Tibetan
        0x1000...0x109F,   // Myanmar
        0x1100...0x11FF,   // Hangul Jamo
        0x1780...0x17FF,   // Khmer
        0x1950...0x19FF,   // Tai Le, New Tai Lue, Khmer symbols
        0x1A20...0x1AAF,   // Tai Tham
        0x2E80...0x2FDF,   // CJK and Kangxi radicals
        0x3000...0x303F,   // CJK symbols (々, 〆, the iteration marks)
        0x3040...0x30FF,   // Hiragana, Katakana with ー and the small kana
        0x3100...0x31FF,   // Bopomofo, Hangul compatibility Jamo, Kanbun, small Katakana extensions
        0x3400...0x4DBF,   // CJK Extension A
        0x4E00...0x9FFF,   // CJK Unified Ideographs
        0xA000...0xA4CF,   // Yi
        0xA960...0xA97F,   // Hangul Jamo Extended-A
        0xA9E0...0xA9FF,   // Myanmar Extended-B
        0xAA60...0xAADF,   // Myanmar Extended-A, Tai Viet
        0xAC00...0xD7FF,   // Hangul syllables, Hangul Jamo Extended-B
        0xF900...0xFAFF,   // CJK Compatibility Ideographs
        0xFF66...0xFFDC,   // halfwidth Katakana and Hangul
        0x1B000...0x1B16F, // Kana Supplement and Extended-A, small kana extension
        0x20000...0x3FFFF, // CJK Extensions B and later
    ]

    /// Draws the coverage of the text, one byte per pixel: 0 where there is none, 255 where it covers fully
    private static func draw(_ layout: Layout, width: Int, height: Int,
                             lineHeight: CGFloat) -> (pixels: [UInt8], image: CGImage, lines: [String])? {
        // The first row in memory is the top row of the picture, as in a frame. Core Graphics
        // and Core Text count y from the bottom row upwards, and nothing is flipped here: text
        // drawn the ordinary way stands upright in the picture, with its first line in the
        // first rows of the memory.
        let count = width * height
        let memory = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { memory.deallocate() }
        memory.initialize(repeating: 0, count: count)
        // Only the coverage is drawn, not the color: an emoji, which comes in its own colors,
        // would otherwise leave the brightness of those colors instead of its shape.
        guard let context = CGContext(data: memory, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.setShouldAntialias(true)
        // gray levels as they are; "font smoothing" would thicken the strokes as for an LCD
        context.setShouldSmoothFonts(false)
        // letters where the layout puts them, not moved to whole pixels: small print keeps its even spacing
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.textMatrix = .identity

        // Core Text fills a frame from its top edge (the largest y) downwards. To center the
        // lines, the top edge lies half of the space that is left over below the top of the
        // picture. The frame reaches below the picture, so that the last line is not left out
        // when the measured height was a fraction too small.
        let boxHeight = CGFloat(height)
        let used = layout.size.height.rounded(.up)
        let top = layout.fitsBox ? ((boxHeight + used) / 2).rounded() : boxHeight
        let below = -(lineHeight + 16)
        var frame = textFrame(layout.framesetter, width: CGFloat(width), from: top, to: layout.fitsBox ? below : 0)
        if !layout.fitsBox, CFArrayGetCount(CTFrameGetLines(frame)) == 0 {
            // Too long: only the lines that fit as a whole are drawn. Here not even one does;
            // then rather a line that is cut off than an empty box over the original.
            frame = textFrame(layout.framesetter, width: CGFloat(width), from: top, to: below)
        }
        CTFrameDraw(frame, context)
        let pixels = Array(UnsafeBufferPointer(start: memory, count: count))
        // `clip(to:mask:)` takes gray without alpha: the coverage becomes the gray level
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        let text = layout.text as NSString
        let lines = (CTFrameGetLines(frame) as? [CTLine] ?? []).map { line -> String in
            let range = CTLineGetStringRange(line)
            return text.substring(with: NSRange(location: range.location, length: range.length))
        }
        return (pixels, image, lines)
    }

    /// A frame as wide as the block between two heights (y counted upwards from the bottom of the picture)
    private static func textFrame(_ framesetter: CTFramesetter, width: CGFloat, from top: CGFloat,
                                  to bottom: CGFloat) -> CTFrame {
        let path = CGPath(rect: CGRect(x: 0, y: bottom, width: width, height: top - bottom), transform: nil)
        return CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    }
}
