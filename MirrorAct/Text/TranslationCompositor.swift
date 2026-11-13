// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import CoreVideo
import Foundation

/// Draws the translations of the text on the screen into video frames, so that the mirror
/// window, screenshots and recordings all show them.
///
/// A frame keeps its pixel format and its colors. The translations are drawn straight into
/// the planes of a copy: for 4:2:0 video into the brightness and, separately, into the color;
/// for BGRA (tests, render test) into the one plane there is. Converting a frame to RGB and
/// back would not reliably look the same in the display layer.
///
/// Rows are counted from the top everywhere here, like in the block rectangles and like the
/// rows of a pixel buffer lie in memory. Core Graphics counts from the bottom; `draw` and
/// `BlockTextMask` say where that matters.
final class TranslationCompositor: @unchecked Sendable {
    /// the texts of the blocks as they were drawn (internal for the tests)
    let texts = BlockTextCache()

    /// protects the pool and the language: `reset` and `language` may come from another thread than the frames
    private let poolLock = NSLock()
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    /// the pixel format of the frames; `prepare` goes by it before the first frame was drawn
    private var poolFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    /// BCP 47 identifier of the language the translations are in; it chooses the forms of the
    /// characters that languages share (see `BlockTextMask`). nil = as the languages of the Mac say.
    var language: String? {
        get {
            poolLock.lock()
            defer { poolLock.unlock() }
            return currentLanguage
        }
        set {
            poolLock.lock()
            currentLanguage = newValue
            poolLock.unlock()
        }
    }
    private var currentLanguage: String?

    // "Device" color spaces: the bytes get the values given here, nothing is color matched
    private let gray = CGColorSpaceCreateDeviceGray()
    private let rgb = CGColorSpaceCreateDeviceRGB()

    init() {}

    /// A copy of the frame with the translations drawn in; nil when the pixel format is not
    /// supported or no buffer could be had (the caller then shows the frame as it is).
    /// One call at a time, any thread.
    func compose(_ source: CVPixelBuffer, blocks: [PlacedBlock]) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let biPlanar = fullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard biPlanar || format == kCVPixelFormatType_32BGRA else { return nil }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0, let copy = pooledBuffer(width: width, height: height, format: format) else { return nil }

        // The source is only read: the decoder may still predict other frames from it, and
        // the text recognition reads it.
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(copy, []) }

        guard Self.copyPixels(from: source, to: copy, biPlanar: biPlanar) else { return nil }
        // Color primaries, transfer function, matrix …: a buffer from a pool has none, and the
        // display and the recorder would take the copy for another kind of video
        CVBufferPropagateAttachments(source, copy)

        let language = self.language
        let blocks = Self.drawnBlocks(blocks, frameWidth: width, frameHeight: height)
        let drawn = biPlanar
            ? drawVideo(blocks, into: copy, width: width, height: height, fullRange: fullRange, language: language)
            : drawBGRA(blocks, into: copy, width: width, height: height, language: language)
        return drawn ? copy : nil
    }

    /// Draws the text of these blocks ahead of time, off the thread that delivers the frames
    /// (blocks without translation are skipped)
    func prepare(_ blocks: [TrackedBlock]) {
        poolLock.lock()
        let format = poolFormat, language = currentLanguage
        poolLock.unlock()
        let fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        for block in blocks {
            guard let translation = block.translation, let size = BlockPlacement.textSize(of: block.rect),
                  let text = texts.entry(id: block.id, text: translation, width: size.width, height: size.height,
                                         lineCount: block.lineCount, language: language) else { continue }
            // Text in a color of its own on 4:2:0 video also needs its masks for the color
            // plane: all four, because scrolling moves a block between odd and even positions
            guard format != kCVPixelFormatType_32BGRA else { continue }
            let colors = Self.videoColors(of: block.colors, fullRange: fullRange)
            guard Self.differInColor(colors.foreground, colors.background) else { continue }
            for oddY in [false, true] {
                for oddX in [false, true] {
                    _ = texts.chromaMask(of: text, oddX: oddX, oddY: oddY)
                }
            }
        }
    }

    /// Forget cached texts and buffers
    func reset() {
        texts.removeAll()
        poolLock.lock()
        pool = nil
        poolLock.unlock()
    }

    // MARK: The copy

    /// A buffer of the pool; the pool is made anew when the frames change their size or format.
    private func pooledBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        poolLock.lock()
        defer { poolLock.unlock() }
        if pool == nil || width != poolWidth || height != poolHeight || format != poolFormat {
            // backed by an IOSurface, which the display layer needs
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolWidth = width
            poolHeight = height
            poolFormat = format
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    /// Copies the pixels of every plane. Both buffers are locked and have the same size and format.
    private static func copyPixels(from source: CVPixelBuffer, to copy: CVPixelBuffer, biPlanar: Bool) -> Bool {
        guard biPlanar else {
            guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(copy) else { return false }
            return copyRows(from: from, bytesPerRow: CVPixelBufferGetBytesPerRow(source),
                            to: to, bytesPerRow: CVPixelBufferGetBytesPerRow(copy),
                            rows: CVPixelBufferGetHeight(source), rowBytes: CVPixelBufferGetWidth(source) * 4)
        }
        guard CVPixelBufferGetPlaneCount(source) == 2, CVPixelBufferGetPlaneCount(copy) == 2 else { return false }
        for plane in 0..<2 {
            guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                  let to = CVPixelBufferGetBaseAddressOfPlane(copy, plane),
                  CVPixelBufferGetWidthOfPlane(copy, plane) == CVPixelBufferGetWidthOfPlane(source, plane),
                  CVPixelBufferGetHeightOfPlane(copy, plane) == CVPixelBufferGetHeightOfPlane(source, plane) else { return false }
            // the color plane has two bytes, Cb and Cr, for each of its pixels
            let rowBytes = CVPixelBufferGetWidthOfPlane(source, plane) * (plane == 0 ? 1 : 2)
            guard copyRows(from: from, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(source, plane),
                           to: to, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(copy, plane),
                           rows: CVPixelBufferGetHeightOfPlane(source, plane), rowBytes: rowBytes) else { return false }
        }
        return true
    }

    /// `rowBytes`: the bytes of a row that are pixels. A row may be longer in memory
    /// (`bytesPerRow`), and the pool does not have to pad its rows like the maker of the frame.
    private static func copyRows(from source: UnsafeRawPointer, bytesPerRow sourceBytesPerRow: Int,
                                 to copy: UnsafeMutableRawPointer, bytesPerRow copyBytesPerRow: Int,
                                 rows: Int, rowBytes: Int) -> Bool {
        guard rows > 0, rowBytes > 0, rowBytes <= sourceBytesPerRow, rowBytes <= copyBytesPerRow else { return false }
        if sourceBytesPerRow == copyBytesPerRow {
            // in one piece; of the last row only the pixels, its padding need not exist
            memcpy(copy, source, (rows - 1) * sourceBytesPerRow + rowBytes)
        } else {
            for row in 0..<rows {
                memcpy(copy + row * copyBytesPerRow, source + row * sourceBytesPerRow, rowBytes)
            }
        }
        return true
    }

    // MARK: Drawing

    /// The blocks that get drawn, in their order, with their places in the frame. Left out are
    /// those that draw nothing, and those of which three quarters or more of what they would
    /// paint is painted over by a larger block that is drawn (or by one of the same size that
    /// comes later). Such a block is a piece of a paragraph that is also known whole, for
    /// example when the text recognition read it once in pieces and once whole: its box would
    /// cover lines of the paragraph's translation, and its text is part of that translation.
    ///
    /// What counts is what a block paints, not its whole rectangle: a paragraph that scrolled
    /// half under a title bar is drawn only below the bar, and a label on the bar that lies
    /// within the paragraph's rectangle stays.
    static func drawnBlocks(_ blocks: [PlacedBlock], frameWidth: Int,
                            frameHeight: Int) -> [(block: PlacedBlock, placement: BlockPlacement)] {
        var placed: [(index: Int, size: Int, placement: BlockPlacement)] = []
        placed.reserveCapacity(blocks.count)
        for (index, block) in blocks.enumerated() {
            // (a translation of nothing but spaces has no text mask, and so no box either)
            guard block.text.contains(where: { !$0.isWhitespace }),
                  let placement = BlockPlacement(rect: block.rect, visibleRect: block.visibleRect,
                                                 lineCount: block.lineCount, frameWidth: frameWidth,
                                                 frameHeight: frameHeight) else { continue }
            placed.append((index, placement.text.width * placement.text.height, placement))
        }
        // Larger blocks first, of the same size the later one first: a block is only compared
        // with the blocks that are drawn, so that none is left out for one that is left out
        // itself. (Sorted by the whole rectangle, which says which block is the paragraph and
        // which its piece; what they paint is compared below.)
        let order = placed.indices.sorted { a, b in
            placed[a].size != placed[b].size ? placed[a].size > placed[b].size : placed[a].index > placed[b].index
        }
        var drawn = [Bool](repeating: false, count: placed.count)
        var kept: [Int] = []
        kept.reserveCapacity(placed.count)
        for candidate in order {
            let area = placed[candidate].placement.area
            let pixels = area.width * area.height
            let covered = kept.contains { larger in
                let shared = placed[larger].placement.area.intersection(area)
                return !shared.isEmpty && shared.width * shared.height * 4 >= pixels * 3
            }
            if !covered {
                drawn[candidate] = true
                kept.append(candidate)
            }
        }
        return placed.indices.filter { drawn[$0] }.map { (blocks[placed[$0].index], placed[$0].placement) }
    }

    /// 4:2:0 video: the first plane is the brightness of every pixel, the second the color of
    /// every 2 × 2 pixels
    private func drawVideo(_ blocks: [(block: PlacedBlock, placement: BlockPlacement)], into frame: CVPixelBuffer, width: Int, height: Int,
                           fullRange: Bool, language: String?) -> Bool {
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(frame, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(frame, 1),
              let context = CGContext(data: luma, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(frame, 0), space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
        Self.flip(context, height: height)
        let chroma = ChromaPlane(base: chromaBase, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(frame, 1),
                                 width: CVPixelBufferGetWidthOfPlane(frame, 1),
                                 height: CVPixelBufferGetHeightOfPlane(frame, 1))
        for (block, placement) in blocks {
            guard let text = texts.entry(id: block.id, text: block.text, width: placement.text.width,
                                         height: placement.text.height, lineCount: block.lineCount,
                                         language: language) else { continue }
            // the values the frame had there, so a box has exactly the brightness and color of what surrounds it
            let (background, foreground) = Self.videoColors(of: block.colors, fullRange: fullRange)
            Self.draw(text.mask, at: placement, background: .gray(background.y), foreground: .gray(foreground.y),
                      in: context)

            // The same in the color plane, with square corners. A frame of odd width or height
            // has a last cell with a single column or row; a box that reaches the edge owns all of it.
            var area = placement.area
            if area.maxX == width { area.maxX = 2 * chroma.width }
            if area.maxY == height { area.maxY = 2 * chroma.height }
            chroma.fill(area, cb: background.cb, cr: background.cr)
            // black, white and gray text on any background needs no more than that
            guard Self.differInColor(foreground, background) else { continue }
            let textArea = area.intersection(placement.text)
            guard !textArea.isEmpty else { continue }
            let mask = texts.chromaMask(of: text, oddX: placement.text.minX & 1 == 1, oddY: placement.text.minY & 1 == 1)
            chroma.blend(mask, x: placement.text.minX, y: placement.text.minY, within: textArea,
                         cb: foreground.cb, cr: foreground.cr)
        }
        return true
    }

    private func drawBGRA(_ blocks: [(block: PlacedBlock, placement: BlockPlacement)], into frame: CVPixelBuffer, width: Int, height: Int,
                          language: String?) -> Bool {
        guard let base = CVPixelBufferGetBaseAddress(frame),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: rgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
        Self.flip(context, height: height)
        for (block, placement) in blocks {
            guard let text = texts.entry(id: block.id, text: block.text, width: placement.text.width,
                                         height: placement.text.height, lineCount: block.lineCount,
                                         language: language) else { continue }
            Self.draw(text.mask, at: placement, background: .rgb(block.colors.background),
                      foreground: .rgb(block.colors.foreground), in: context)
        }
        return true
    }

    /// A color as the plane that is drawn into stores it
    private enum Paint {
        /// one byte: the brightness plane of video
        case gray(UInt8)
        case rgb(RGBColor)

        func setFill(in context: CGContext) {
            switch self {
            case let .gray(value):
                context.setFillColor(gray: CGFloat(value) / 255, alpha: 1)
            case let .rgb(color):
                context.setFillColor(red: CGFloat(color.red) / 255, green: CGFloat(color.green) / 255,
                                     blue: CGFloat(color.blue) / 255, alpha: 1)
            }
        }
    }

    /// Core Graphics puts y = 0 at the bottom row of a bitmap, which is the last row in memory.
    /// Turned over, y = 0 is the first row in memory and y points down: the coordinates of the
    /// block rectangles can be used as they are.
    private static func flip(_ context: CGContext, height: Int) {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        // the text masks are drawn pixel for pixel, never scaled
        context.interpolationQuality = .none
    }

    /// Draws one block into the brightness plane or into a BGRA picture: the box that covers
    /// the original text, then the translation. `context` is flipped (see `flip`).
    private static func draw(_ mask: BlockTextMask, at placement: BlockPlacement, background: Paint,
                             foreground: Paint, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if let visible = placement.visible { context.clip(to: visible.cgRect) }
        // The edges lie on whole pixels, so only the round corners get blended with the frame
        context.addPath(CGPath(roundedRect: placement.backdrop.cgRect, cornerWidth: placement.cornerRadius,
                               cornerHeight: placement.cornerRadius, transform: nil))
        background.setFill(in: context)
        context.fillPath()

        // The mask is a picture, and Core Graphics maps the bottom row of a picture to the
        // smallest y of the rectangle it is given. In this context the smallest y is the top:
        // the text would stand on its head. So turn y back up for the rectangle of the text,
        // with y = 0 at its bottom edge (the largest y on the frame); flipped twice, the top
        // row of the mask ends up in the top row of the rectangle.
        let text = placement.text
        context.translateBy(x: CGFloat(text.minX), y: CGFloat(text.maxY))
        context.scaleBy(x: 1, y: -1)
        let box = CGRect(x: 0, y: 0, width: CGFloat(text.width), height: CGFloat(text.height))
        // white in the mask lets the color through, black keeps what is there
        context.clip(to: box, mask: mask.image)
        foreground.setFill(in: context)
        context.fill(box)
    }

    /// The colors of a block as a 4:2:0 frame stores them: as they were read from such a frame,
    /// or converted from RGB when they were not (or were read with the other range)
    private static func videoColors(of colors: BlockColors, fullRange: Bool) -> (background: YCbCrColor, foreground: YCbCrColor) {
        func sampled(_ color: VideoColor?) -> YCbCrColor? {
            guard let color, color.fullRange == fullRange else { return nil }
            return color.color
        }
        return (sampled(colors.backgroundInVideo) ?? YCbCrColor(colors.background, fullRange: fullRange),
                sampled(colors.foregroundInVideo) ?? YCbCrColor(colors.foreground, fullRange: fullRange))
    }

    /// Text and background differ in more than their brightness
    private static func differInColor(_ a: YCbCrColor, _ b: YCbCrColor) -> Bool {
        let blue = abs(Int(a.cb) - Int(b.cb)), red = abs(Int(a.cr) - Int(b.cr))
        return blue + red > 6
    }
}

/// The drawn texts of the blocks, so that Core Text runs once per text and not once per frame.
/// `prepare` fills it on the thread that translates, `compose` reads it on the thread that
/// delivers the frames (and draws what it does not find).
final class BlockTextCache: @unchecked Sendable {
    /// One text, drawn for one size of its block
    final class Entry {
        let mask: BlockTextMask
        fileprivate let key: Key
        /// the masks for the color plane, made when a frame needs them: even / odd column, then the same for odd rows
        fileprivate var chroma: [ChromaMask?] = [nil, nil, nil, nil]
        fileprivate var lastUse: UInt64 = 0
        fileprivate var bytes: Int

        fileprivate init(mask: BlockTextMask, key: Key) {
            self.mask = mask
            self.key = key
            // the mask is kept twice: as bytes and as the picture Core Graphics clips with
            bytes = 2 * mask.width * mask.height
        }
    }

    /// What a drawn text depends on
    fileprivate struct Key: Hashable {
        let id: Int
        let text: String
        let width: Int
        let height: Int
        let lineCount: Int
        let language: String?

        // The text is compared but not hashed: every block of every frame is looked up, and
        // hashing a paragraph costs more than drawing its box. Blocks rarely share the rest.
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
            hasher.combine(width)
            hasher.combine(height)
            hasher.combine(lineCount)
        }
    }

    /// most texts and most bytes kept; beyond that the ones not used for longest go
    let limit: Int
    let byteLimit: Int

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    /// counts the lookups: the "time" of `Entry.lastUse`
    private var uses: UInt64 = 0
    private var drawn = 0

    init(limit: Int = 300, byteLimit: Int = 64 << 20) {
        self.limit = limit
        self.byteLimit = byteLimit
    }

    /// texts kept at the moment
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// texts drawn with Core Text so far
    var drawCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return drawn
    }

    /// The text of a block, drawn now if it is not there yet. `id`: of the block; `text`: its
    /// translation; `width`, `height`: size of the block in whole pixels; `lineCount`: lines
    /// of the original; `language`: of the translation. nil when it cannot be drawn.
    func entry(id: Int, text: String, width: Int, height: Int, lineCount: Int, language: String? = nil) -> Entry? {
        let key = Key(id: id, text: text, width: width, height: height, lineCount: lineCount, language: language)
        lock.lock()
        uses += 1
        if let entry = entries[key] {
            entry.lastUse = uses
            lock.unlock()
            return entry
        }
        lock.unlock()

        // Core Text works outside the lock: a frame must not wait for a text that `prepare` is drawing
        guard let mask = BlockTextMask(text: text, width: width, height: height, lineCount: lineCount,
                                       language: language) else { return nil }
        let entry = Entry(mask: mask, key: key)
        lock.lock()
        defer { lock.unlock() }
        drawn += 1
        if let earlier = entries[key] {
            // the other thread drew the same text in the meantime
            earlier.lastUse = uses
            return earlier
        }
        entry.lastUse = uses
        entries[key] = entry
        bytes += entry.bytes
        dropOldest()
        return entry
    }

    /// The mask of an entry for the color plane of 4:2:0 video, for a block at an odd or even
    /// column and row of the frame (see `ChromaMask`)
    func chromaMask(of entry: Entry, oddX: Bool, oddY: Bool) -> ChromaMask {
        let index = (oddX ? 1 : 0) + (oddY ? 2 : 0)
        lock.lock()
        if let mask = entry.chroma[index] {
            lock.unlock()
            return mask
        }
        lock.unlock()

        let mask = ChromaMask(mask: entry.mask.pixels, width: entry.mask.width, height: entry.mask.height,
                              oddX: oddX, oddY: oddY)
        lock.lock()
        defer { lock.unlock() }
        if let earlier = entry.chroma[index] { return earlier }
        entry.chroma[index] = mask
        let size = mask.pixels.count + mask.runs.count * MemoryLayout<ChromaMask.Run>.stride
        entry.bytes += size
        // (an entry that was dropped in the meantime no longer counts)
        if entries[entry.key] === entry { bytes += size }
        return mask
    }

    func removeAll() {
        lock.lock()
        entries = [:]
        bytes = 0
        lock.unlock()
    }

    /// Called with the lock held. Drops a quarter more than necessary, so that this does not
    /// run again for every text that follows.
    private func dropOldest() {
        guard entries.count > limit || bytes > byteLimit else { return }
        let oldestFirst = entries.values.sorted { $0.lastUse < $1.lastUse }
        for entry in oldestFirst {
            // the last one is the text that was just asked for
            if entries.count <= 1 || (entries.count <= limit * 3 / 4 && bytes <= byteLimit / 4 * 3) { break }
            entries[entry.key] = nil
            bytes -= entry.bytes
        }
    }
}
