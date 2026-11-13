// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Vision

/// Reads the text in a frame with Vision, on this Mac.
enum TextRecognizer {
    /// Lines of text in `region` (frame pixels, origin at the top left; nil = the whole frame).
    /// The rectangles of the result are in coordinates 0…1 of the whole frame, origin at the top
    /// left. Blocks while Vision works; call it off the main thread (or use `recognize`).
    /// An icon that Vision read as a character in front of a line is left out (`LeadingMark`).
    static func lines(in pixelBuffer: CVPixelBuffer, region: CGRect? = nil) throws -> [RecognizedLine] {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        guard width > 0, height > 0 else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // As a fraction of the picture's height; set explicitly because the documented default
        // (1/32) would skip ordinary text on a phone screen. Whether Vision measures it against
        // the region of interest or the whole picture, 0.004 lies below anything legible (on
        // macOS 26 the accurate recognizer drops no text by this value either way; see
        // TextRecognizerTests).
        request.minimumTextHeight = 0.004
        // Vision counts from the bottom left, in fractions of the picture
        var interest = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let region {
            let part = region.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !part.isNull, part.width >= 1, part.height >= 1 else { return [] }
            interest = CGRect(x: part.minX / width, y: 1 - part.maxY / height,
                              width: part.width / width, height: part.height / height)
            request.regionOfInterest = interest
        }
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        let frameSize = CGSize(width: width, height: height)
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let line = RecognizedLine(text: candidate.string,
                                      rect: frameRect(of: observation.boundingBox, in: interest),
                                      confidence: Double(candidate.confidence))
            return LeadingMark.removed(from: line, frameSize: frameSize, boxOf: { range in
                (try? candidate.boundingBox(for: range)).map { frameRect(of: $0.boundingBox, in: interest) }
            }, luma: { LumaRaster(of: pixelBuffer, in: $0) })
        }
    }

    /// A bounding box as Vision reports it (fractions of the region of interest, from its bottom
    /// left) in fractions of the whole frame, from the top left
    static func frameRect(of box: CGRect, in interest: CGRect) -> CGRect {
        let x = interest.minX + box.minX * interest.width
        let bottom = interest.minY + box.minY * interest.height
        let size = CGSize(width: box.width * interest.width, height: box.height * interest.height)
        return CGRect(x: x, y: 1 - bottom - size.height, width: size.width, height: size.height)
    }

    /// The same in the background; nil if Vision failed
    static func recognize(_ pixelBuffer: CVPixelBuffer, region: CGRect? = nil) async -> [RecognizedLine]? {
        await Task.detached(priority: .userInitiated) { () -> [RecognizedLine]? in
            do {
                return try lines(in: pixelBuffer, region: region)
            } catch {
                Log.error("Text recognition: \(error.localizedDescription)")
                return nil
            }
        }.value
    }
}

/// The brightness of the pixels of a rectangle of a frame, row by row from the top
struct LumaRaster {
    /// where the raster's first pixel lies in the frame
    var x: Int, y: Int
    var width: Int, height: Int
    var values: [UInt8]

    init(x: Int, y: Int, width: Int, height: Int, values: [UInt8]) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.values = values
    }

    /// nil for a rectangle outside the frame and for pixel formats other than bi-planar 4:2:0
    /// and BGRA
    init?(of pixelBuffer: CVPixelBuffer, in rect: CGRect) {
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer), frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        let area = rect.integral.intersection(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
        guard !area.isNull, area.width >= 1, area.height >= 1 else { return nil }
        let left = Int(area.minX), top = Int(area.minY), width = Int(area.width), height = Int(area.height)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard planar || format == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return nil }
        let bytesPerRow = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer)
        var values = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (base + (top + y) * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                if planar {
                    values[y * width + x] = row[left + x]
                } else {
                    // BGRA, weighted as in Rec. 601
                    let pixel = row + (left + x) * 4
                    let blue: Int = Int(pixel[0]) * 114, green: Int = Int(pixel[1]) * 587, red: Int = Int(pixel[2]) * 299
                    values[y * width + x] = UInt8((blue + green + red) / 1000)
                }
            }
        }
        self.init(x: left, y: top, width: width, height: height, values: values)
    }
}

/// An icon in front of a line's text that Vision read as one more character of the line, as on
/// the rows of a settings screen: "E Display & Touchbedienung", "= Speicher", "• System". The
/// line's box then spans icon and text and can be much higher than the text; the character
/// would go to the translator and the translation would be drawn over the icon.
///
/// Vision's boxes of the parts of a string (`boundingBox(for:)`) do not show the gap: they are
/// spread over the line's box as if the character were followed by an ordinary space (on macOS
/// 26 the title's box often begins 0.5 of the text's size left of its ink), and each is as high
/// as the line. The gap is therefore measured in the pixels of the line's box (`parts`), and
/// Vision's boxes only tell on which side the character lies and about where the rest begins.
///
/// A character is left out when, in the pixels, it stands clearly apart (`standsApart`). On
/// rows drawn with AppKit at 2x, 2.625x and 3x (SF Symbols bare, in a circle or on a rounded
/// square, 24 to 40 pt, a gap of 12 to 20 pt, titles of 16 to 20 pt, German, English and
/// Arabic) the gap between icon and title was at least 0.61 of the text's size; in running
/// text, after a bullet, a list number, a currency sign, a one-letter word or an initial, at
/// most 0.45, and a bullet's ink is at most 0.3 of the text's size. Only the end where the
/// text begins is looked at: Vision read chevrons and switches at the end of a row as lines of
/// their own, and a short word at the end of a line is mostly a value ("Pixel 8", "Version
/// 14 A").
///
/// The gap alone does not tell a word from an icon: lists, agendas and receipts set a quantity,
/// a weekday or a day number apart from their text ("5   Kaffee", "Mo   Zahnarzt", "24
/// Geburtstag"), and justified text widens the gap after a short first word ("Im   Gegensatz").
/// A character with a letter or a digit therefore stays when it sits on the rest's line like
/// text (`sitsLikeText`): its ink is no higher than `textHeight` and ends on the rest's
/// baseline, or a share `onBaseline` of its inked columns does (a descender or the tail of a Q
/// ends lower: "by", "go", "Qi"). An icon is centred on its row and ends below the baseline.
/// Measured with Vision on the rows above and on such columns (SF and Helvetica, 15 to 20 pt,
/// gaps of 0.6 to 1.4 of the text's size, 2x and 3x, light and dark; 1742 words that the gap
/// alone would have cut): the words' ink was at most 1.0 of the text's size high, and either
/// ended within 0.058 of the baseline or had at least 0.30 of its columns end there; of the
/// icons read as a letter or digit (85 of 234), those no higher than 1.1 ended at least 0.087
/// below the baseline, with at most 0.24 of their columns on it. Signs and symbols ("•", "→",
/// "©", "€") keep the rule of the gap: a sign set apart from a word is mostly an icon, and
/// leaving it out loses no word.
///
/// A "Q" sits like text only by its columns: the tail of a Q ends below the baseline and its
/// bowl on it, while the magnifier of a search field, which Vision reads as "Q", ends with the
/// tip of its handle on the baseline like a word and with few columns there. Measured with
/// Vision on Android (Roboto, font scales 1 and 1.3, light and dark): 60 Qs before a word
/// ended 0.10 to 0.13 of the text's size below the baseline with 0.54 to 0.65 of their columns
/// on it; the magnifier before "In Einstellungen suchen" and "Search settings" (56 readings)
/// ended from 0.03 above to 0.04 below it, with 0.07 to 0.22 of its columns there.
enum LeadingMark {
    /// The least gap between the character's ink and the rest's, in units of the size of the
    /// rest's text (`TextLayout.textSize` of its ink width)
    static let gap = 0.55
    /// and the least share of the widest gap between the rest's words
    static let gapOverWordGap = 1.5
    /// The least width or height of the character's ink, in the same units: a bullet, a dash or
    /// a full stop stays (TextLayout recognises list items by their bullet)
    static let markSize = 0.45
    /// How far the new box reaches above and below the rest's ink, in the same units
    static let margin = 0.2
    /// The greatest height of the ink of a character that sits like text, in the same units
    static let textHeight = 1.1
    /// How near to the rest's baseline the character's ink must end, in the same units
    static let baselineTolerance = 0.06
    /// or the least share of its inked columns that must end that near to it
    static let onBaseline = 0.25

    /// The ink of a line's parts, in frame pixels: the lone character, the rest (the band of
    /// its text: rows of another line that the box reaches into are left out) and the widest
    /// gap between the rest's words (nil for a single word)
    struct Parts: Equatable {
        var mark: CGRect
        var rest: CGRect
        var widestGapInRest: CGFloat?
        /// The rest's baseline: the bottom of the row in which most of its inked columns end
        /// (a descender ends lower, but in fewer columns); nil when not measured
        var restBaseline: CGFloat? = nil
        /// Where each inked column of the character ends (the bottom of its lowest ink)
        var markColumnEnds: [CGFloat] = []
    }

    /// `line` without a character in front of its text that stands apart. `boxOf` gives
    /// Vision's box of a part of the text, `luma` the pixels of a rectangle of the frame (both
    /// in the line's coordinates: 0…1 of the frame, frame pixels).
    static func removed(from line: RecognizedLine, frameSize: CGSize,
                        boxOf: (Range<String.Index>) -> CGRect?,
                        luma: (CGRect) -> LumaRaster?) -> RecognizedLine {
        guard let split = split(line.text), let markBox = boxOf(split.mark), let restBox = boxOf(split.rest)
        else { return line }
        // the character must lie on the side where the rest's reading begins
        let markOnLeft = markBox.midX < restBox.midX
        guard markOnLeft != BlockTextMask.isRightToLeft(String(line.text[split.rest])) else { return line }
        let scale = CGAffineTransform(scaleX: frameSize.width, y: frameSize.height)
        let box = line.rect.applying(scale), rest = restBox.applying(scale)
        guard let raster = luma(box) else { return line }
        // the gap lies before about where Vision has the rest begin (it puts it too far
        // towards the character, by at most about half the line's height)
        let hint = markOnLeft ? rest.minX + box.height / 2 : rest.maxX - box.height / 2
        let restText = String(line.text[split.rest])
        guard let parts = parts(of: raster, markOnLeft: markOnLeft, hint: hint),
              standsApart(parts, restText: restText, markOnLeft: markOnLeft),
              !sitsLikeText(parts, markText: String(line.text[split.mark]), restText: restText),
              let rect = rect(of: parts, line: box, restText: restText, markOnLeft: markOnLeft) else { return line }
        let unit = CGRect(x: rect.minX / frameSize.width, y: rect.minY / frameSize.height,
                          width: rect.width / frameSize.width, height: rect.height / frameSize.height)
        return RecognizedLine(text: restText, rect: unit, confidence: line.confidence)
    }

    /// The lone character and the rest, when the text's first or last word is a single
    /// character or two (Vision reads some icons as "Aa", "88" or "-Ó"), but not a list number
    /// such as "1." or "a)", and the rest has at least two letters. Which of the two ends lies
    /// in front of the text tells its direction (`removed`).
    static func split(_ text: String) -> (mark: Range<String.Index>, rest: Range<String.Index>)? {
        let words = wordRanges(text)
        guard words.count >= 2 else { return nil }
        let rest: Range<String.Index>, mark: Range<String.Index>
        if isMark(text[words[0]]) {
            mark = words[0]
            rest = words[1].lowerBound..<words[words.count - 1].upperBound
        } else if isMark(text[words[words.count - 1]]) {
            // Vision may give an icon on the right of a line written from the right last
            mark = words[words.count - 1]
            rest = words[0].lowerBound..<words[words.count - 2].upperBound
        } else {
            return nil
        }
        guard TextLayout.isTranslatable(String(text[rest])) else { return nil }
        return (mark, rest)
    }

    private static func isMark(_ word: Substring) -> Bool {
        switch word.count {
        case 1: return true
        case 2:
            let first = word[word.startIndex], second = word[word.index(after: word.startIndex)]
            return !((first.isLetter || first.isNumber) && (second == "." || second == ")"))
        default: return false
        }
    }

    private static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let begin = start { ranges.append(begin..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let begin = start { ranges.append(begin..<text.endIndex) }
        return ranges
    }

    /// Measures the parts in the pixels of a line's box. The background is the most common
    /// brightness; ink differs from it by more than 28. The character is the ink from the side
    /// of `markOnLeft` up to the widest empty stretch of columns that begins before `hint` (an
    /// x in frame pixels); the rest is the ink after that stretch. nil when there is no such
    /// stretch.
    static func parts(of raster: LumaRaster, markOnLeft: Bool, hint: CGFloat) -> Parts? {
        let width = raster.width, height = raster.height
        guard width > 2, height > 2, raster.values.count == width * height else { return nil }
        // plain loops over the values: this runs in builds without optimization too
        return raster.values.withUnsafeBufferPointer { values -> Parts? in
            var histogram = [Int](repeating: 0, count: 64)
            var index = 0
            while index < values.count {
                histogram[Int(values[index]) >> 2] += 1
                index += 1
            }
            var mode = 0
            for bin in 1..<64 where histogram[bin] > histogram[mode] { mode = bin }
            let background = mode * 4 + 2
            var ink = [Bool](repeating: false, count: values.count)
            var inked = [Bool](repeating: false, count: width)
            index = 0
            while index < values.count {
                let difference = Int(values[index]) - background
                if difference > 28 || difference < -28 {
                    ink[index] = true
                    inked[index % width] = true
                }
                index += 1
            }
            // positions counted from the character's side; `column` turns them into x
            func column(_ position: Int) -> Int { markOnLeft ? position : width - 1 - position }
            var first = 0
            while first < width, !inked[column(first)] { first += 1 }
            guard first < width else { return nil }
            let limit = markOnLeft ? Int(hint.rounded()) - raster.x : raster.x + width - 1 - Int(hint.rounded())
            var split: Range<Int>?
            var position = first
            while position < width {
                if inked[column(position)] { position += 1; continue }
                let start = position
                while position < width, !inked[column(position)] { position += 1 }
                if position < width, start <= limit, position - start > (split?.count ?? 0) { split = start..<position }
            }
            guard let split else { return nil }
            // the columns of the character and of the rest, as ranges of x
            let markColumns = markOnLeft ? first..<split.lowerBound : (width - split.lowerBound)..<(width - first)
            let restColumns = markOnLeft ? split.upperBound..<width : 0..<(width - split.upperBound)
            func rowHasInk(_ y: Int, _ columns: Range<Int>) -> Bool {
                var x = columns.lowerBound
                while x < columns.upperBound {
                    if ink[y * width + x] { return true }
                    x += 1
                }
                return false
            }
            // the band of the rest's text: the highest run of rows with ink in its columns
            var band = 0..<0, row = 0
            while row < height {
                if !rowHasInk(row, restColumns) { row += 1; continue }
                let start = row
                while row < height, rowHasInk(row, restColumns) { row += 1 }
                if row - start > band.count { band = start..<row }
            }
            func box(_ columns: Range<Int>, _ rows: Range<Int>) -> CGRect? {
                var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
                var y = rows.lowerBound
                while y < rows.upperBound {
                    var x = columns.lowerBound
                    while x < columns.upperBound {
                        if ink[y * width + x] {
                            if x < minX { minX = x }
                            if x > maxX { maxX = x }
                            if y < minY { minY = y }
                            if y > maxY { maxY = y }
                        }
                        x += 1
                    }
                    y += 1
                }
                guard maxX >= 0 else { return nil }
                return CGRect(x: raster.x + minX, y: raster.y + minY, width: maxX - minX + 1, height: maxY - minY + 1)
            }
            guard let mark = box(markColumns, 0..<height), let rest = box(restColumns, band) else { return nil }
            // where the inked columns end: the bottom of their lowest ink in `rows`
            func ends(_ columns: Range<Int>, _ rows: Range<Int>) -> [Int] {
                var result: [Int] = []
                var x = columns.lowerBound
                while x < columns.upperBound {
                    var y = rows.upperBound - 1
                    while y >= rows.lowerBound, !ink[y * width + x] { y -= 1 }
                    if y >= rows.lowerBound { result.append(y + 1) }
                    x += 1
                }
                return result
            }
            var counts = [Int](repeating: 0, count: height + 1)
            for end in ends(restColumns, band) { counts[end] += 1 }
            var baseline = band.upperBound
            for end in (band.lowerBound + 1)...band.upperBound where counts[end] > counts[baseline] { baseline = end }
            // the widest gap between the rest's words, within its band
            var widest: Int?, run = 0, seen = false
            var x = restColumns.lowerBound
            while x < restColumns.upperBound {
                var columnHasInk = false
                var y = band.lowerBound
                while y < band.upperBound, !columnHasInk {
                    columnHasInk = ink[y * width + x]
                    y += 1
                }
                if columnHasInk {
                    if seen, run > 0 { widest = max(widest ?? 0, run) }
                    seen = true
                    run = 0
                } else if seen {
                    run += 1
                }
                x += 1
            }
            return Parts(mark: mark, rest: rest, widestGapInRest: widest.map { CGFloat($0) },
                         restBaseline: CGFloat(raster.y + baseline),
                         markColumnEnds: ends(markColumns, 0..<height).map { CGFloat(raster.y + $0) })
        }
    }

    /// Whether the character stands clearly apart from the rest: its ink is not small, and the
    /// gap is wide against the size of the rest's text and against the gaps between its words
    static func standsApart(_ parts: Parts, restText: String, markOnLeft: Bool) -> Bool {
        guard let size = TextLayout.textSize(of: restText, width: Double(parts.rest.width)), size > 0 else { return false }
        let gap = Double(markOnLeft ? parts.rest.minX - parts.mark.maxX : parts.mark.minX - parts.rest.maxX)
        let markSize = Double(max(parts.mark.width, parts.mark.height))
        return markSize >= Self.markSize * size && gap >= Self.gap * size
            && gap >= gapOverWordGap * Double(parts.widestGapInRest ?? 0)
    }

    /// Whether the character is a word set on the rest's line: it has a letter or a digit, its
    /// ink is no higher than text, and it ends on the rest's baseline (or enough of its columns
    /// do; for a "Q" only its columns, see above). False when the baseline was not measured.
    static func sitsLikeText(_ parts: Parts, markText: String, restText: String) -> Bool {
        guard markText.contains(where: { $0.isLetter || $0.isNumber }), let baseline = parts.restBaseline,
              let size = TextLayout.textSize(of: restText, width: Double(parts.rest.width)), size > 0,
              Double(parts.mark.height) <= textHeight * size else { return false }
        let tolerance = baselineTolerance * size
        func onLine(_ y: CGFloat) -> Bool { abs(Double(y - baseline)) <= tolerance }
        // (the tail of a Q ends below the baseline: a "Q" whose lowest ink ends on it is a magnifier)
        if markText != "Q", onLine(parts.mark.maxY) { return true }
        let ends = parts.markColumnEnds
        return !ends.isEmpty && Double(ends.filter(onLine).count) >= onBaseline * Double(ends.count)
    }

    /// The box of the rest (frame pixels): from its ink on the character's side, with the
    /// margin Vision left there before the character, to the line's other end; above and below
    /// the rest's ink by `margin`, within the line's box
    static func rect(of parts: Parts, line: CGRect, restText: String, markOnLeft: Bool) -> CGRect? {
        guard let size = TextLayout.textSize(of: restText, width: Double(parts.rest.width)) else { return nil }
        let reach = CGFloat(margin * size)
        let side = min(reach, max(0, markOnLeft ? parts.mark.minX - line.minX : line.maxX - parts.mark.maxX))
        let left = markOnLeft ? parts.rest.minX - side : line.minX
        let right = markOnLeft ? line.maxX : parts.rest.maxX + side
        let top = max(line.minY, parts.rest.minY - reach), bottom = min(line.maxY, parts.rest.maxY + reach)
        guard right > left, bottom > top else { return nil }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}
