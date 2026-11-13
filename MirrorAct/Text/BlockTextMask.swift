// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreText
import Foundation

/// The translation of a block as a picture of the size of the block: white where the text is,
/// black around it. The compositor fills the color of the text through it in every frame;
/// Core Text, which takes far longer than that, runs once per text.
///
/// The text is set in the system font, in the size of the original text as far as it fits
/// (see `originalFontSize`), broken into lines of the width of the block and placed in its
/// height where the letters of the original stood. Only a translation too long for the block
/// at that size is set smaller: it has to stay inside the place of the original.
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

    /// The font does not get smaller than this share of the height of a line of the original,
    /// nor smaller than `smallestFontSize` pixels (unless the original is that small): below
    /// that nobody can read it anyway.
    static let smallestFontShare: CGFloat = 0.28
    static let smallestFontSize: CGFloat = 9

    /// The rectangle of a line of text that the text recognition gives is as high as its
    /// letters reach above the baseline times `lineBoxPerTop`, plus as deep as they reach below
    /// it times `lineBoxPerBottom`, both in the size of the font (`originalFontSize`): "Aus" (a
    /// capital, nothing below the line) gets a box of 0.88 of its font size, "Displaysperre"
    /// 0.98, "aus" 0.66. Fitted to 673 lines of Android screens, whose font size was measured
    /// from the ink of their letters; it errs by 5 % of the size in the median and by 13 % or
    /// more in the worst tenth (that much do the boxes of the text recognition vary).
    static let lineBoxPerTop: CGFloat = 1.25
    static let lineBoxPerBottom: CGFloat = 0.6
    /// The letters of a text reach at least this high (a share of the font size, about the
    /// height of a small letter): a text of dots or dashes does not make the font huge.
    static let leastTop: CGFloat = 0.5
    /// From one line of a paragraph to the next, in the size of its font: 1.1 to 1.4 on the
    /// screens measured (Android summaries 1.1, large titles 1.23, web pages 1.31 and 1.38)
    static let linePitch: CGFloat = 1.3
    /// Rows at the top and bottom edge of the block that the letters of a translation keep clear
    static let clearance: CGFloat = 1
    /// How far the drawn letters reach beyond their outlines: the smoothing of their edges
    /// covers up to a pixel more (measured on kanji at 9 pixels, which reached a row above the
    /// top of their outlines)
    static let smoothing: CGFloat = 1

    /// `width`, `height`: size of the block in pixels; `lineCount`: lines of the original text;
    /// `original`: the original text, whose letters say how large its font is (see
    /// `originalFontSize`), nil = not known; `language`: BCP 47 identifier of the language of
    /// the text, which chooses the forms of characters that languages share (Japanese kanji are
    /// not drawn as Chinese hanzi); nil = as the languages of the Mac say. nil when there is
    /// nothing to draw or no picture could be made.
    init?(text: String, width: Int, height: Int, lineCount: Int, original: String? = nil, language: String? = nil) {
        // one paragraph: a line break inside a translation would cost a line the block does not have
        let text = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard width > 0, height > 0, !text.isEmpty else { return nil }
        let lineHeight = BlockPlacement.lineHeight(height: height, lineCount: lineCount)
        let box = CGSize(width: CGFloat(width), height: CGFloat(height))
        let letters = BlockTextMask.letters(of: original)
        let largest = max(1, BlockTextMask.originalFontSize(width: width, height: height, lineCount: lineCount,
                                                            letters: letters))
        let smallest = min(largest, max(lineHeight * BlockTextMask.smallestFontShare, BlockTextMask.smallestFontSize))
        let lineEnds = BlockTextMask.wordKeepingLineEnds(in: text, language: language)
        let rightToLeft = BlockTextMask.isRightToLeft(text)

        // The largest font that fits: usually the first one tried, the size of the original.
        // Otherwise halve the range between a size that fits and one that does not (see `largest`).
        // A word broken between two letters, or parted from its punctuation, does not count as
        // fitting. When even the smallest font has to break a word, the largest size is taken
        // at which the lines fit the block and no more words are broken than at the smallest
        // size: so that it is no smaller than it has to be, and breaks no word it need not.
        func set(_ fontSize: CGFloat) -> Layout {
            Layout(text, fontSize: fontSize, in: box, lineEnds: lineEnds, rightToLeft: rightToLeft, language: language)
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

        // (only a text that is too long needs them)
        let ellipsisStops = layout.fitsBox ? [] : BlockTextMask.ellipsisStops(in: text, language: language)
        guard let picture = BlockTextMask.draw(layout, width: width, height: height, letters: letters,
                                               ellipsisStops: ellipsisStops) else { return nil }
        self.width = width
        self.height = height
        pixels = picture.pixels
        image = picture.image
        fontSize = layout.fontSize
        self.lineCount = picture.lines.count
        lines = picture.lines
        fits = layout.fitsBox
    }

    /// How far the letters of a text reach above and below the baseline, and how wide they
    /// are, in the size of the font (glyph outlines, not the line height of the font)
    struct Letters: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        var width: CGFloat
    }

    /// The letters of a text set in the system font; nil for no text or one without letters.
    /// Core Text measures them, so every script is covered: capitals and ascenders, small
    /// letters only, letters below the line, marks above, the square characters of Chinese and
    /// Japanese, the stacked marks of Thai.
    static func letters(of text: String?) -> Letters? {
        guard let text, text.contains(where: { !$0.isWhitespace }) else { return nil }
        // measured large: outlines at a size of 1 come out rounded
        let size: CGFloat = 100
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
        ])
        let bounds = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(string as CFAttributedString),
                                                .useGlyphPathBounds)
        guard !bounds.isEmpty, bounds.height > 0 else { return nil }
        return Letters(top: bounds.maxY / size, bottom: -bounds.minY / size, width: bounds.width / size)
    }

    /// What is taken for the letters of an original that is not known: capitals or ascenders
    /// and letters below the line, the tallest box ordinary text gets, so that the font is not
    /// taken larger than the original's
    static let typicalLetters = letters(of: "Hg") ?? Letters(top: 0.71, bottom: 0.2, width: 1.2)

    /// The size of the font of the original text of a block, in pixels: the size its
    /// translation is set in, as far as it fits. `letters`: of the original text (see
    /// `letters(of:)`), nil = not known.
    ///
    /// The rule: the rectangle of the block holds `lineCount` lines, `linePitch` apart, and the
    /// box of the last one is as high as its letters reach (`lineBoxPerTop`, `lineBoxPerBottom`).
    /// The height alone gives a font size from the line spacing of the original when there are
    /// several lines, and from the letters of the original when there is one: "Aus" and "An"
    /// have a capital and nothing below the line, so their box is lower than that of a text with
    /// "p" or "g" in the same font, and their font is larger than the box suggests. A box of the
    /// text recognition is uncertain by a tenth or more of its height, its width by much less:
    /// a line of the original is as wide as its letters, and the system font sets them about as
    /// wide as the fonts of phones do. So the size is also taken from the width, the width of the
    /// block for one line or `lineCount` times it for the whole text (an upper bound, as lines
    /// end at different places), and the smaller of the two counts. When the original is not
    /// known, `typicalLetters` stand in for it and the width is not used.
    /// Several lines: the line spacing of the original dominates the height, and a guess of
    /// `linePitch` errs by up to a sixth of the size; the width bound and the fit (as long as
    /// the lines of the translation at that size do not fit, it is set smaller) keep it inside
    /// the block.
    /// All capitals: like a capital with small letters (the box is that of the capitals).
    /// Digits only: as high as capitals; the text recognition draws larger boxes around digits,
    /// and their width keeps the size from being taken too large.
    /// Chinese, Japanese, Korean: the characters reach 0.8 to 0.9 of the size above the baseline
    /// and a little below it, and each is about as wide as the font is large, which the width
    /// takes into account.
    static func originalFontSize(width: Int, height: Int, lineCount: Int, letters: Letters?) -> CGFloat {
        let lines = CGFloat(max(1, lineCount))
        let measured = letters ?? typicalLetters
        let box = lineBoxPerTop * max(leastTop, measured.top) + lineBoxPerBottom * max(0, measured.bottom)
        let byHeight = CGFloat(height) / ((lines - 1) * linePitch + box)
        guard let letters, letters.width > 0 else { return byHeight }
        return min(byHeight, CGFloat(width) * lines / letters.width)
    }

    /// The same for an original given as text
    static func originalFontSize(width: Int, height: Int, lineCount: Int, original: String?) -> CGFloat {
        originalFontSize(width: width, height: height, lineCount: lineCount, letters: letters(of: original))
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
        /// the lines, broken to the width of the block, and their origins (baselines), with y
        /// counted upwards from the bottom of a frame higher than the text
        let lines: [CTLine]
        let origins: [CGPoint]
        /// how far their letters reach up and down from each origin (glyph outlines)
        let extents: [(top: CGFloat, bottom: CGFloat)]
        /// highest and lowest point of the letters of all lines, in the same coordinates
        let inkTop: CGFloat
        let inkBottom: CGFloat
        /// all lines fit into the block
        let fitsBox: Bool
        /// line ends that break a word or part it from its punctuation (counted only when the lines fit)
        let brokenWords: Int
        /// all lines fit, and no word had to be broken for that
        var fits: Bool { fitsBox && brokenWords == 0 }

        /// `lineEnds`: where a line may end without breaking a word, in UTF-16 units as Core
        /// Text counts its ranges (see `wordKeepingLineEnds`); `rightToLeft`: the direction of the paragraph
        init(_ text: String, fontSize: CGFloat, in box: CGSize, lineEnds: Set<Int>, rightToLeft: Bool, language: String?) {
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
            self.text = text
            self.fontSize = fontSize
            self.string = string
            self.framesetter = framesetter
            self.lineEnds = lineEnds
            self.rightToLeft = rightToLeft
            self.size = size
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: box.width, height: size.height + box.height + 100),
                              transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)
            self.lines = lines
            self.origins = origins
            // What has to fit is the letters, not the lines of the font: a line of the system
            // font is 1.18 times its size high, with room above the tallest letters, while the
            // box of the original is about as high as its letters (`lineBoxPerTop`). A line of
            // only spaces has no letters.
            let smoothing = BlockTextMask.smoothing
            let extents = lines.map { line -> (top: CGFloat, bottom: CGFloat) in
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                return bounds.isEmpty || bounds.height <= 0 ? (0, 0) : (bounds.maxY + smoothing, smoothing - bounds.minY)
            }
            self.extents = extents
            var inkTop = -CGFloat.greatestFiniteMagnitude, inkBottom = CGFloat.greatestFiniteMagnitude
            for (origin, extent) in zip(origins, extents) where extent.top > 0 || extent.bottom > 0 {
                inkTop = max(inkTop, origin.y + extent.top)
                inkBottom = min(inkBottom, origin.y - extent.bottom)
            }
            if inkTop < inkBottom { (inkTop, inkBottom) = (0, 0) }
            self.inkTop = inkTop
            self.inkBottom = inkBottom
            fitsBox = inkTop - inkBottom <= box.height - 2 * BlockTextMask.clearance && size.width <= box.width + 0.5
            // A word wider than the block is broken by Core Text between two letters, without
            // a hyphen, and the size above still fits. Such a line end does not count as fitting.
            var brokenWords = 0
            if fitsBox {
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
        lineEnds(in: text, language: language, nextToEveryCharacterOf: scriptsWithoutSpaces)
    }

    /// The offsets (in UTF-16 units) after which the last line of a text that goes on may end
    /// with an ellipsis: where a line may end without breaking a word, as for
    /// `wordKeepingLineEnds`. But in the scripts whose letters are reordered or stacked (Thai,
    /// Lao, Khmer, Myanmar …) only where Core Text itself would end a line, after a word as its
    /// dictionaries find them: not after every character, which would part a letter from its
    /// marks or a vowel from the consonant it is written before. In the other scripts without
    /// spaces next to every character. (`endingWithEllipsis` also keeps every cluster of a
    /// character and its marks whole.)
    static func ellipsisStops(in text: String, language: String? = nil) -> Set<Int> {
        lineEnds(in: text, language: language, nextToEveryCharacterOf: scriptsBrokenAnywhere)
    }

    /// The line ends of `wordKeepingLineEnds`, with the places next to every character of these scripts
    private static func lineEnds(in text: String, language: String?,
                                 nextToEveryCharacterOf scripts: [ClosedRange<UInt32>]) -> Set<Int> {
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
            if scripts.contains(where: { $0.contains(scalar.value) }) {
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
    private static let scriptsWithoutSpaces = scriptsBrokenByWords + scriptsBrokenAnywhere

    /// Of these, the scripts whose letters are reordered or stacked: a line ends after a word,
    /// as the dictionaries of the line breaking find it
    private static let scriptsBrokenByWords: [ClosedRange<UInt32>] = [
        0x0E00...0x0EFF,   // Thai, Lao
        0x0F00...0x0FFF,   // Tibetan
        0x1000...0x109F,   // Myanmar
        0x1780...0x17FF,   // Khmer
        0x1950...0x19FF,   // Tai Le, New Tai Lue, Khmer symbols
        0x1A20...0x1AAF,   // Tai Tham
        0xA9E0...0xA9FF,   // Myanmar Extended-B
        0xAA60...0xAADF,   // Myanmar Extended-A, Tai Viet
    ]

    /// And those in which a line may end next to any character
    private static let scriptsBrokenAnywhere: [ClosedRange<UInt32>] = [
        0x1100...0x11FF,   // Hangul Jamo
        0x2E80...0x2FDF,   // CJK and Kangxi radicals
        0x3000...0x303F,   // CJK symbols and punctuation (々, 〆, 。, 「」)
        0x3040...0x30FF,   // Hiragana, Katakana with ー and the small kana
        0x3100...0x31FF,   // Bopomofo, Hangul compatibility Jamo, Kanbun, small Katakana extensions
        0x3400...0x4DBF,   // CJK Extension A
        0x4E00...0x9FFF,   // CJK Unified Ideographs
        0xA000...0xA4CF,   // Yi
        0xA960...0xA97F,   // Hangul Jamo Extended-A
        0xAC00...0xD7FF,   // Hangul syllables, Hangul Jamo Extended-B
        0xF900...0xFAFF,   // CJK Compatibility Ideographs
        0xFE30...0xFE4F,   // CJK Compatibility Forms
        0xFF00...0xFFEF,   // fullwidth digits, letters and punctuation, halfwidth Katakana and Hangul
        0x1B000...0x1B16F, // Kana Supplement and Extended-A, small kana extension
        0x20000...0x3FFFF, // CJK Extensions B and later
    ]

    /// Draws the coverage of the text, one byte per pixel: 0 where there is none, 255 where it covers fully
    /// `letters`: of the original (nil = not known); `ellipsisStops`: where the last line of a
    /// text that goes on may end (see `ellipsisStops(in:)`)
    private static func draw(_ layout: Layout, width: Int, height: Int, letters: Letters?,
                             ellipsisStops: Set<Int>) -> (pixels: [UInt8], image: CGImage, lines: [String])? {
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

        // How far the lines of the layout are moved up into the picture (whole pixels), and how
        // many of them are drawn
        let boxHeight = CGFloat(height), clearance = BlockTextMask.clearance
        let firstOrigin = layout.origins.first?.y ?? 0
        let firstExtent = layout.extents.first ?? (top: 0, bottom: 0)
        var shift: CGFloat
        var lineCount = layout.lines.count
        if layout.fitsBox {
            // Where the letters of the original stood. Its box is about as high as its letters
            // reach (`lineBoxPerTop`), and they stand in its middle: the lines are placed so that
            // letters like the original's, on their baselines, would fill the same height in the
            // middle of the block. A translation with other letters then stands on the baselines
            // of the original ("Off" where "Aus" was, an underscore at the foot of its line), and
            // is moved only as far as its own letters need to stay inside the block.
            let original = letters ?? BlockTextMask.typicalLetters
            let top = firstOrigin + max(BlockTextMask.leastTop, original.top) * layout.fontSize
            let bottom = (layout.origins.last?.y ?? 0) - max(0, original.bottom) * layout.fontSize
            shift = (boxHeight / 2 - (top + bottom) / 2).rounded()
            shift = min(shift, (boxHeight - clearance - layout.inkTop).rounded(.down))
            shift = max(shift, (clearance - layout.inkBottom).rounded(.up))
        } else {
            // Too long: only the lines whose letters fit as a whole are drawn, from the top
            shift = (boxHeight - clearance - (firstOrigin + firstExtent.top)).rounded(.down)
            lineCount = 0
            for (origin, extent) in zip(layout.origins, layout.extents) {
                guard origin.y + shift - extent.bottom >= clearance - 0.001 else { break }
                lineCount += 1
            }
            if lineCount == 0 {
                // Here not even one does; then rather a line that is cut off than an empty box
                // over the original. Only the first, in the middle: those below it would lie below
                // the picture, with the ellipsis.
                lineCount = min(1, layout.lines.count)
                shift = (boxHeight / 2 - (firstOrigin + (firstExtent.top - firstExtent.bottom) / 2)).rounded()
            }
        }
        let text = layout.text as NSString
        var lines = Array(layout.lines.prefix(lineCount))
        var origins = layout.origins.prefix(lineCount).map { CGPoint(x: $0.x, y: $0.y + shift) }
        var texts = lines.map { line -> String in
            let range = CTLineGetStringRange(line)
            return text.substring(with: NSRange(location: range.location, length: range.length))
        }
        // Too long: the last line drawn ends with an ellipsis, so that the text is seen to go on
        // instead of just stopping in the middle of a sentence
        if !layout.fitsBox, let last = lines.last,
           let ending = endingWithEllipsis(last, layout, stops: ellipsisStops, width: CGFloat(width)) {
            // A line of a paragraph written from the right stays aligned at the right
            if layout.rightToLeft {
                origins[lines.count - 1].x = CGFloat(CTLineGetPenOffsetForFlush(ending.line, 1, Double(width)))
            }
            lines[lines.count - 1] = ending.line
            texts[texts.count - 1] = ending.text
        }
        for (line, origin) in zip(lines, origins) {
            context.textPosition = origin
            CTLineDraw(line, context)
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
    /// clusters of characters. The ellipsis never follows a part of a cluster (a letter without
    /// its marks) or a vowel that is written before the consonant that follows it (Thai เ แ โ ใ
    /// ไ, the Lao and Tai Viet ones alike). nil when the line ends the text. `stops`: where the
    /// line may end (see `ellipsisStops(in:)`).
    private static func endingWithEllipsis(_ last: CTLine, _ layout: Layout, stops: Set<Int>,
                                           width: CGFloat) -> (line: CTLine, text: String)? {
        let range = CTLineGetStringRange(last)
        let start = range.location, end = range.location + range.length
        let string = layout.string, text = string.string as NSString
        guard start < end, end < text.length else { return nil }
        let ellipsis = NSAttributedString(string: "\u{2026}", attributes: string.attributes(at: start, effectiveRange: nil))
        // left out before the ellipsis; closing brackets and quotes stay
        let trimmed = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            .subtracting(CharacterSet(charactersIn: ")]}\u{BB}\u{203A}\u{201D}\u{2019}\"'\u{300D}\u{300F}\u{FF09}"))
        // Where the clusters of this line end, as Unicode's rules find them (those of NSString
        // differ: in Myanmar they join a consonant to the one before it)
        var clusterEnds: [Int] = []
        var offset = start
        for character in text.substring(from: start) {
            offset += character.utf16.count
            guard offset <= end else { break }
            clusterEnds.append(offset)
        }
        let wholeClusters = Set(clusterEnds)

        /// the line up to `stop` with the ellipsis, when it fits the width
        func ending(at stop: Int, trimming: Bool) -> (line: CTLine, text: String)? {
            var stop = stop
            while trimming, stop > start, let scalar = Unicode.Scalar(text.character(at: stop - 1)),
                  trimmed.contains(scalar) {
                stop -= 1
            }
            // (these vowels are all in the Basic Multilingual Plane; half of a surrogate pair is none of them)
            guard stop > start, wholeClusters.contains(stop),
                  Unicode.Scalar(text.character(at: stop - 1))?.properties.isLogicalOrderException != true else { return nil }
            let piece = NSMutableAttributedString(attributedString: string.attributedSubstring(
                from: NSRange(location: start, length: stop - start)))
            piece.append(ellipsis)
            let line = CTLineCreateWithAttributedString(piece as CFAttributedString)
            guard CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) <= width + 0.5 else { return nil }
            return (line, piece.string)
        }
        for stop in stops.filter({ $0 > start && $0 <= end }).sorted(by: >) {
            if let found = ending(at: stop, trimming: true) { return found }
        }
        // a single word wider than the line with the ellipsis: cut between two clusters (and
        // not after a vowel written before its consonant, which `ending` passes over)
        for stop in clusterEnds.reversed() where stop < end {
            if let found = ending(at: stop, trimming: false) { return found }
        }
        return nil
    }
}
