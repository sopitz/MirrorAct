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
    /// the text of each drawn line, from the top (with the spaces it ends with, and the ellipsis)
    let lines: [String]
    /// false: too long for the block even in the smallest font; the last line drawn ends with an ellipsis
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
        let lineEnds = BlockTextMask.wordKeepingLineEnds(in: text, language: language)
        let rightToLeft = BlockTextMask.isRightToLeft(text)

        // The largest font that fits: usually the first one tried. Otherwise halve the range
        // between a size that fits and one that does not (see `largest`).
        // A word broken between two letters, or parted from its punctuation, does not count as
        // fitting. When even the smallest font has to break a word, the largest size is taken
        // at which the lines fit the block and no more words are broken than at the smallest
        // size: so that it is no smaller than it has to be, and breaks no word it need not.
        func set(_ fontSize: CGFloat) -> Layout {
            Layout(text, fontSize: fontSize, in: box, lineHeight: lineHeight, lineEnds: lineEnds,
                   rightToLeft: rightToLeft, language: language)
        }
        let first = set(largest)
        var layout = first
        if !first.fits, smallest < largest {
            let small = set(smallest)
            layout = small
            if small.fits {
                layout = BlockTextMask.largest(from: small, below: largest, set, fitting: \.fits)
            } else if small.fitsBox {
                let mostBroken = small.brokenWords
                let fitting = { (layout: Layout) in layout.fitsBox && layout.brokenWords <= mostBroken }
                layout = fitting(first) ? first : BlockTextMask.largest(from: small, below: largest, set, fitting: fitting)
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

    /// The largest layout that passes `test`, of the sizes from `fitting` (which passed) up to
    /// below `tooLarge`. Only sizes on a grid above `fitting` are tried, half a pixel apart or
    /// a 64th of the range when that is wider, so that the range is halved six or seven times
    /// at most. The grid depends on the height of the block alone: a wider block is set from the
    /// same sizes as a narrower one and so never comes out smaller only because the halving
    /// happened to try other sizes.
    private static func largest(from fitting: Layout, below tooLarge: CGFloat, _ layout: (CGFloat) -> Layout,
                                fitting test: (Layout) -> Bool) -> Layout {
        let step = max(0.5, (tooLarge - fitting.fontSize) / 64)
        var best = fitting
        // grid points known to pass and known (or taken) to be too large
        var low = 0, high = Int(((tooLarge - fitting.fontSize) / step).rounded(.up))
        while high - low > 1 {
            let middle = (low + high) / 2
            let candidate = layout(fitting.fontSize + CGFloat(middle) * step)
            if test(candidate) {
                best = candidate
                low = middle
            } else {
                high = middle
            }
        }
        return best
    }

    /// The text set in one font size
    private struct Layout {
        let text: String
        let fontSize: CGFloat
        /// the text with its font, as Core Text sets it
        let string: NSAttributedString
        let framesetter: CTFramesetter
        /// where a line may end without breaking a word (see `wordKeepingLineEnds`)
        let lineEnds: Set<Int>
        /// the direction of the paragraph (see `isRightToLeft`)
        let rightToLeft: Bool
        /// what the text needs when it is broken into lines of the width of the block
        let size: CGSize
        /// all lines fit into the block
        let fitsBox: Bool
        /// line ends that break a word or part it from its punctuation (counted only when the lines fit)
        let brokenWords: Int
        /// all lines fit, and no word had to be broken for that
        var fits: Bool { fitsBox && brokenWords == 0 }

        /// `lineEnds`: where a line may end without breaking a word, in UTF-16 units as Core
        /// Text counts its ranges (see `wordKeepingLineEnds`); `rightToLeft`: the direction of the paragraph
        init(_ text: String, fontSize: CGFloat, in box: CGSize, lineHeight: CGFloat, lineEnds: Set<Int>,
             rightToLeft: Bool, language: String?) {
            // The language picks the fonts for the characters the system font does not have
            // (Hiragino for Japanese, PingFang SC or TC for Chinese) and their local forms.
            let font = CTFontCreateUIFontForLanguage(.system, fontSize, language as CFString?)
                ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            // The direction of the paragraph is given, not left to Core Text: a line set on its
            // own (the one that ends with an ellipsis) would otherwise take the direction of its
            // own first letter, and an Arabic line that starts with "iPhone" would be set from
            // the left. Otherwise the defaults: lines broken between words and aligned at the
            // side the paragraph starts from.
            let direction = rightToLeft ? CTWritingDirection.rightToLeft : .leftToRight
            let paragraph = withUnsafePointer(to: direction) { value in
                var setting = CTParagraphStyleSetting(spec: .baseWritingDirection,
                                                      valueSize: MemoryLayout<CTWritingDirection>.size, value: value)
                return CTParagraphStyleCreate(&setting, 1)
            }
            // white, because the picture is a mask
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
                NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): paragraph,
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
            self.string = string
            self.framesetter = framesetter
            self.lineEnds = lineEnds
            self.rightToLeft = rightToLeft
            self.size = size
            fitsBox = size.height <= box.height + slack && size.width <= box.width + 0.5
            // A word wider than the block is broken by Core Text between two letters, without
            // a hyphen, and the size above still fits. Such a line end does not count as fitting.
            var brokenWords = 0
            if fitsBox {
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: size.height + box.height + 100),
                                  transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
                let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
                for line in lines.dropLast() {
                    let range = CTLineGetStringRange(line)
                    if !lineEnds.contains(range.location + range.length) {
                        brokenWords += 1
                    }
                }
            }
            self.brokenWords = brokenWords
        }
    }

    /// The offsets (in UTF-16 units) at which a line may end without breaking a word or parting
    /// it from its punctuation. These are the places Unicode's rules of line breaking allow:
    /// after a space or a hyphen, not before a comma or a closing bracket, not after an opening
    /// one. In addition, a line may end next to any character of a script written without spaces
    /// between words (Han, kana, Hangul, the fullwidth forms, Thai and the like): there Core Text
    /// breaks the way the language of the text wants, also before ー and the small kana, where
    /// Unicode's rules alone are stricter.
    ///
    /// The rules are applied in the language of the text, which decides which way a quote
    /// faces (“ closes a German quote and opens an English one), and never in the region or
    /// language of the Mac. Without a language, and for Chinese, Japanese and Korean, whose
    /// locales make the tokenizer tell words apart instead (also in Latin text, where it would
    /// allow "don'|t"), they are Unicode's own.
    static func wordKeepingLineEnds(in text: String, language: String? = nil) -> Set<Int> {
        let string = text as CFString
        let length = CFStringGetLength(string)
        var ends: Set<Int> = [0, length]
        let code = language.map { $0.prefix { $0 != "-" && $0 != "_" }.lowercased() }
        let rules = code.flatMap { ["ja", "ko", "zh", "yue"].contains($0) ? nil : language } ?? "root"
        let locale = CFLocaleCreate(nil, CFLocaleIdentifier(rawValue: rules as CFString))
        if let tokenizer = CFStringTokenizerCreate(nil, string, CFRange(location: 0, length: length),
                                                   kCFStringTokenizerUnitLineBreak, locale) {
            while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                ends.insert(range.location + range.length)
            }
        }
        var offset = 0
        for scalar in text.unicodeScalars {
            let next = offset + UTF16.width(scalar)
            if scriptsWithoutSpaces.contains(where: { $0.contains(scalar.value) }) {
                ends.insert(offset)
                ends.insert(next)
            }
            offset = next
        }
        return ends
    }

    /// Whether a paragraph is written from the right: its first letter of a definite direction
    /// is one of a script written from the right (Arabic, Hebrew and the like). Digits, marks,
    /// spaces and punctuation have no direction of their own and are passed over; a text
    /// without any letter is written from the left. This is the rule by which Core Text finds
    /// the direction of a paragraph itself (Unicode's bidirectional algorithm, P2 and P3).
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200E: return false // left-to-right mark
            case 0x200F: return true // right-to-left mark
            default: break
            }
            let letter: Bool
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: letter = true
            default: letter = false
            }
            guard letter else { continue }
            return scriptsFromTheRight.contains { $0.contains(scalar.value) }
        }
        return false
    }

    /// The blocks of the scripts that are written from the right
    private static let scriptsFromTheRight: [ClosedRange<UInt32>] = [
        0x0590...0x08FF,   // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic and Arabic extensions
        0xFB1D...0xFDFF,   // Hebrew and Arabic presentation forms
        0xFE70...0xFEFF,   // Arabic presentation forms B
        0x10800...0x10FFF, // Phoenician, Aramaic, Kharoshthi, Avestan, Old Turkic, Hanifi Rohingya, Yezidi …
        0x1E800...0x1EFFF, // Mende Kikakui, Adlam, Arabic mathematical letters
    ]

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
        0x3000...0x303F,   // CJK symbols and punctuation (々, 〆, 。, 「」)
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
        0xFE30...0xFE4F,   // CJK Compatibility Forms
        0xFF00...0xFFEF,   // fullwidth digits, letters and punctuation, halfwidth Katakana and Hangul
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
        var bottom = layout.fitsBox ? below : 0
        var frame = textFrame(layout.framesetter, width: CGFloat(width), from: top, to: bottom)
        if !layout.fitsBox, CFArrayGetCount(CTFrameGetLines(frame)) == 0 {
            // Too long: only the lines that fit as a whole are drawn. Here not even one does;
            // then rather a line that is cut off than an empty box over the original.
            bottom = below
            frame = textFrame(layout.framesetter, width: CGFloat(width), from: top, to: bottom)
        }
        let text = layout.text as NSString
        var lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var texts = lines.map { line -> String in
            let range = CTLineGetStringRange(line)
            return text.substring(with: NSRange(location: range.location, length: range.length))
        }
        if !layout.fitsBox, let last = lines.last, let ending = endingWithEllipsis(last, layout, width: CGFloat(width)) {
            // Too long: the last line that fits ends with an ellipsis, so that the text is seen
            // to go on instead of just stopping in the middle of a sentence
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            // A line of a paragraph written from the right stays aligned at the right
            if layout.rightToLeft {
                origins[lines.count - 1].x = CGFloat(CTLineGetPenOffsetForFlush(ending.line, 1, Double(width)))
            }
            lines[lines.count - 1] = ending.line
            texts[texts.count - 1] = ending.text
            for (line, origin) in zip(lines, origins) {
                // the origins are counted from the corner of the frame's rectangle
                context.textPosition = CGPoint(x: origin.x, y: origin.y + bottom)
                CTLineDraw(line, context)
            }
        } else {
            CTFrameDraw(frame, context)
        }
        let pixels = Array(UnsafeBufferPointer(start: memory, count: count))
        // `clip(to:mask:)` takes gray without alpha: the coverage becomes the gray level
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return (pixels, image, texts)
    }

    /// The last line drawn of a text that goes on after it, ending with an ellipsis: its
    /// words, as many as fit next to the ellipsis, without the spaces, commas or full stops they
    /// end with. Only when not even its first word fits, that word is cut off between two
    /// characters. nil when the line ends the text.
    private static func endingWithEllipsis(_ last: CTLine, _ layout: Layout,
                                           width: CGFloat) -> (line: CTLine, text: String)? {
        let range = CTLineGetStringRange(last)
        let start = range.location, end = range.location + range.length
        let string = layout.string, text = string.string as NSString
        guard start < end, end < text.length else { return nil }
        let ellipsis = NSAttributedString(string: "\u{2026}", attributes: string.attributes(at: start, effectiveRange: nil))
        // left out before the ellipsis; closing brackets and quotes stay
        let trimmed = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            .subtracting(CharacterSet(charactersIn: ")]}\u{BB}\u{203A}\u{201D}\u{2019}\"'\u{300D}\u{300F}\u{FF09}"))

        /// the line up to `stop` with the ellipsis, when it fits the width
        func ending(at stop: Int, trimming: Bool) -> (line: CTLine, text: String)? {
            var stop = stop
            while trimming, stop > start, let scalar = Unicode.Scalar(text.character(at: stop - 1)),
                  trimmed.contains(scalar) {
                stop -= 1
            }
            guard stop > start else { return nil }
            let piece = NSMutableAttributedString(attributedString: string.attributedSubstring(
                from: NSRange(location: start, length: stop - start)))
            piece.append(ellipsis)
            let line = CTLineCreateWithAttributedString(piece as CFAttributedString)
            guard CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) <= width + 0.5 else { return nil }
            return (line, piece.string)
        }
        for stop in layout.lineEnds.filter({ $0 > start && $0 <= end }).sorted(by: >) {
            if let found = ending(at: stop, trimming: true) { return found }
        }
        // a single word wider than the line with the ellipsis: cut between two characters
        var stop = end
        while stop > start {
            stop = text.rangeOfComposedCharacterSequence(at: stop - 1).location
            if let found = ending(at: stop, trimming: false) { return found }
        }
        return nil
    }

    /// A frame as wide as the block between two heights (y counted upwards from the bottom of the picture)
    private static func textFrame(_ framesetter: CTFramesetter, width: CGFloat, from top: CGFloat,
                                  to bottom: CGFloat) -> CTFrame {
        let path = CGPath(rect: CGRect(x: 0, y: bottom, width: width, height: top - bottom), transform: nil)
        return CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    }
}
