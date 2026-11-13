// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
// CGRect is a Foundation type on Linux; on Apple platforms its members come with CoreGraphics
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A part of the frame whose content moves as one (a page that scrolls between bars that stay)
struct ScrollingArea: Equatable {
    /// in frame pixels, origin at the top left
    var rect: CGRect
    /// the edges found to the pixel (`FrameMotion.top` …); the others are only known roughly
    var knownEdges: Int
}

/// Keeps the translations of a screen on their text from frame to frame and decides which parts
/// of the picture have to be read (again).
///
/// Use: for every frame, in order, `advance` with the thumbnail of the frame, then draw
/// `FrameUpdate.placed` into that frame. Independently of the frames: `beginRecognition` → read
/// that region of the frame given to the last `advance` → `finishRecognition`;
/// `textsAwaitingTranslation` → translate → `setTranslation`.
///
/// Not thread safe: the caller makes sure that calls never overlap. It has no clock and no
/// randomness: the same calls give the same results. Times are seconds of any steady clock.
///
/// How it works:
/// - Every block keeps the pixels of the thumbnail it was read from (`BlockPatch`, its anchor).
///   In every frame it is looked for near where the movement of the picture says it went, and
///   its position is measured against these pixels to a fraction of a pixel – never added up
///   from frame to frame. Rows and columns of it that no longer look like the text (a bar it
///   slid under, a dialog over it) are cut off; when the text cannot be confirmed it is not
///   drawn, and it is forgotten after a while.
/// - `MotionEstimator` tells for each frame which parts of the picture stayed, moved (and how
///   far) or changed otherwise. Parts that moved are remembered as scrolling areas: blocks are
///   never drawn outside of the one they move with.
/// - `ReadingPlan` keeps what has to be read: what scrolled into view (at once), what changed
///   (once it rests), places where a block was cut off (once all of it can be seen), and what
///   was read while it moved fast (once more when it rests).
/// - A pass reads the thumbnail it started on; points on a grid over its region move with the
///   picture meanwhile and carry its blocks over to the current frame, where each one is
///   checked against the picture before it is taken.
final class OverlayTracker {
    struct Configuration: Equatable {
        /// two pixels differ when their brightness differs by more than this (kept for callers;
        /// the tiles below decide)
        var pixelThreshold = 24
        /// share of differing pixels below which two frames show the same picture (kept for callers)
        var unchangedShare = 0.0002
        /// seconds without a change after which the picture counts as settled; also how long a
        /// changed part of the picture must rest before it is read
        var settleTime: TimeInterval = 0.12
        /// seconds until a failed translation is offered again
        var retryDelay: TimeInterval = 5
        /// translations remembered for text that comes back into view
        var cacheLimit = 2000

        // MARK: Comparing frames (MotionEstimator); brightness in grey levels 0…255

        /// side of the square tiles frames are compared in, thumbnail pixels: about the size of a
        /// letter, and of the blocks a video codec works in
        var tileSize = 8
        /// a tile has changed when its pixels differ by more than this on average. The noise of
        /// a link is about ±2 per pixel (a mean difference of 1.6, 2.3 at ±3).
        var tileChangeDifference = 4.0
        /// … or when its mean brightness moved by more than this (a plain area changed shade)
        var tileChangeShift = 2.5
        /// a tile whose brightness spans no more than this is plain: it may as well have moved
        var plainRange = 10
        /// inside a scrolling area that moves, a group of fewer changed tiles than this is taken
        /// for damage of the codec, not for something new to read
        var minChangedTilesWhileMoving = 6
        /// a tile whose mean brightness drifted by more than this since it was last accepted as it
        /// is (moved in, changed, first seen) has changed: a slow fade changes every frame by less
        /// than `tileChangeDifference`
        var tileDriftLimit = 8.0
        /// a tile fits a movement when the mean difference to where it came from is at most this
        /// plus `matchTexture` × the mean step between its pixels (a movement measured to a
        /// fraction of a pixel still leaves some of the edges)
        var matchBase = 6.0
        var matchTexture = 0.35
        /// differences of single pixels or tiles above this count as this much: damage by the
        /// codec or something on top must not outweigh everything else
        var matchCostCap = 48.0
        /// at most this many parts of the picture that move differently (a page, a row of cards
        /// in it, a keyboard)
        var maxMotions = 3
        /// a movement must explain at least this many tiles; another one after the first is looked
        /// for only in a group of at least `minSecondMotionTiles` changed tiles that touch
        var minMotionTiles = 6
        var minSecondMotionTiles = 16
        /// … at least this share of the tiles it can be checked on (the others may be damaged)
        var minMatchedShare = 0.65
        /// … and at least this share of all tiles that changed (not a coincidence of two pictures)
        var minExplainedShare = 0.3
        /// … and inside the changed part, the tiles that show something and stayed as they were
        /// but do not fit it must not outnumber the tiles it explains. Moving content changes
        /// nearly every tile; what stays and contradicts the movement is a bar or a button over
        /// it, or a tile whose source the codec damaged in the frame before (up to half as many
        /// as it explains in a fast glide over rows that look alike) – or the movement is not
        /// real: rows that look alike, a row apart, while the codec repairs a picture that has
        /// come to rest (four times as many).
        var maxContradictingShare = 1.0
        /// at least this share of what changed must stay in view for a movement to be measured
        /// (content that moves farther than that in a frame cannot be followed)
        var minOverlapShare = 0.25
        /// tiles a movement is checked on, at most (evenly spread), and measured to a fraction of
        /// a pixel on
        var motionSampleTiles = 200
        var refineTiles = 120
        /// bands the row and column sums are taken in (a narrow change shows in one of them)
        var profileBands = 4
        /// candidates taken from each profile comparison; shifts up to `fineProfileReach` pixels
        /// are compared at full resolution, longer ones at a quarter of it first
        var profileCandidates = 4
        var fineProfileReach = 16
        /// a movement of the frame before that explains this share of the tiles is taken without
        /// searching (almost always the case while scrolling)
        var priorShortcutShare = 0.75
        /// a movement of the frame before wins against another one whose cost is lower by less
        /// than `priorPreference` among candidates of the same search, and against the best
        /// other movement unless that one is cheaper by more than `priorAdvantage`
        var priorPreference = 0.05
        var priorAdvantage = 0.3
        /// an edge row (column) of tiles belongs to a moving part only when the movement explains
        /// more than two of its tiles or at least this share of those that show something
        var minEdgeShare = 0.25
        /// a second (third) moving part must explain at least this share of the tiles that show
        /// something in its box
        var minMotionDensity = 0.4
        /// parts of a pixel below this are taken as none (no sideways movement from noise)
        var subpixelSnap = 0.08
        /// a row is where something that does not move begins when it differs from the frame
        /// before by at most `matchBase` and by `edgeMargin` less than from where it would have
        /// come from, and differs from the row inside of it by `edgeContrast` (a separator, a
        /// bar of another shade: plain margins of the page are not where it ends)
        var edgeMargin = 3.0
        var edgeContrast = 4.0
        /// a refined edge of a scrolling area that moves by more than this (thumbnail pixels)
        /// replaces the known one only when two frames in a row find it
        var edgeJitter = 2

        // MARK: Following blocks (PatchMatcher)

        /// pixels around a block that its patch also keeps
        var patchMargin = 1
        /// a patch is compared on about this many pixels (every second or third pixel of a big
        /// paragraph: enough to place it to a fraction of a pixel)
        var patchSamples = 1000
        /// a row or column of a block no longer shows its text when its brightness moved by more
        /// than this plus `foreignShiftTexture` × the steps in it on average. (A thumbnail moved by
        /// a fraction of a pixel is not quite the interpolation of the one before: fine strokes
        /// leave up to a quarter of the steps; a plain bar over text moves the mean by more than
        /// half of them.) …
        var foreignShift = 5.0
        var foreignShiftTexture = 0.3
        /// … or its pixels differ by more than this plus `foreignTexture` × the steps in it (a
        /// misalignment of up to half a pixel, a little damage of the codec)
        var foreignDifference = 8.0
        var foreignTexture = 0.6
        /// a block of which more than one in so many rows (or column chunks) inside does not show
        /// its text is not drawn: something covers its middle, or it changed
        var interiorForeignDivisor = 5
        /// columns are checked in chunks of this many pixels
        var columnChunk = 4
        /// a chunk whose patch and frame both vary by more than this (variance, grey levels²:
        /// a standard deviation of 12) must correlate by at least `minDetailCorrelation`
        var detailVariance = 144.0
        var minDetailCorrelation = 0.5
        /// pixels by which the part of a block that is cut off may grow in a frame beyond what the
        /// movements in it explain
        var cutSlack = 2.0
        /// a block of which less than this share can be seen is not drawn, nor one whose visible
        /// rows hold less than `minVisibleTexture` of its detail (only plain rows left: they
        /// would fit any plain place)
        var minVisibleShare = 0.5
        var minVisibleTexture = 0.5
        /// the whole block must fit its patch at least this well: mean difference at most
        /// `fitBase` + `fitTexture` × the mean step between its pixels (a fade, a zoom)
        var fitBase = 4.0
        var fitTexture = 0.3
        /// a block found elsewhere than its area took it, or found again after it was lost, must
        /// fit at most this much worse than it did before (a line that looks alike fits worse)
        var refitTolerance = 3.0
        /// a block found less than this far from where it was (thumbnail pixels) stayed in place
        var restingShift = 0.08
        /// a block that showed completely is taken as it is, without checking it row by row, when
        /// it fits its patch by at most `sureFitBase` + `sureFitTexture` × its mean step between
        /// pixels and lies at least `sureRoom` pixels inside its area and the frame
        var sureFitBase = 3.0
        var sureFitTexture = 0.12
        var sureRoom = 4.0
        /// a tile that stayed while the content around it moved in so many frames (of those that
        /// moved) lies over the content: a floating button, a header that sticks. Nothing is drawn
        /// over it or the tiles next to it. (One frame may be a tile whose source the codec damaged.)
        var overlayFrames = 3
        /// … a block of which at least this share lies where it shows belongs to it
        var overlayOwnShare = 0.5
        /// … a pixel of it stays: it differs from the frame before by at most `stayDifference`,
        /// and from where the movement would have brought content by at least `stayContrast`
        var stayDifference = 8
        var stayContrast = 24
        /// seconds a block that cannot be found is kept, out of sight, in case it comes back
        var lostLifetime: TimeInterval = 1.5
        /// a block read again at nearly the same place is the same block when they share this
        /// share of the larger one's area
        var sameBlockOverlap = 0.6
        /// the rectangle of a block stays as it was unless an edge of a new reading differs by
        /// more than this (frame pixels): the text drawn for it can be kept
        var sizeTolerance = 3.0

        // MARK: Reading (ReadingPlan)

        /// thumbnail pixels read around what has to be read, so that text at its edges is read
        /// completely (about two lines)
        var readMargin = 24.0
        /// a strip that scrolled in is read at once when it is at least this thick (a line);
        /// thinner ones once the content has stopped for `thinStripDelay`
        var minStripThickness = 12.0
        var thinStripDelay: TimeInterval = 0.04
        /// what was read while moving fast is read again this long after it stopped
        var confirmDelay: TimeInterval = 0.25
        /// the picture rests this long after it last moved: what is read then stays as it is.
        /// Places that could not be seen completely while it moved are read once it rests, and
        /// text at an edge of the view is taken as far as it shows.
        var restDelay: TimeInterval = 0.3
        /// moving fast: more than this share of the scrolling area per frame (the link starts
        /// losing detail then)
        var fastMotionShare = 0.005
        /// a region of at least this share of the frame is read as a whole frame
        var wholeFrameShare = 0.5
        /// areas to read are merged when their union is at most this much larger than both
        var mergeSlack = 1.3
        /// due areas join the region of a pass when the union is at most this much larger
        var regionSlack = 1.5
        /// more areas to read than this are merged
        var maxUnreadAreas = 48
        /// a block that reaches within this many thumbnail pixels of the edge of what was read
        /// (or of its scrolling area) may be cut off there: it is not taken, and read again once
        /// all of it can be seen
        var cutEdge = 2.0
        /// a place is read again at most this many times for being cut off
        var maxRereads = 2
        /// A paragraph read while the picture moves may go on beyond the edge of the view (the
        /// frame, its scrolling area) when that edge lies above or below it within this many of
        /// its lines (the gap before a line and most of that line, enough to read it): its next
        /// line may be about to come in. Its text is translated once that band has come into view
        /// without a line that continues it, …
        var continuationReach = 1.3
        /// … or the frame shows nothing in the rows from a quarter of a line to this many lines
        /// beyond it, where such a line would show its letters, or once the picture rests
        var inkReach = 1.0
        /// points that carry a pass over to the current frame lie this far apart
        var probeSpacing = 16
        /// a pass started within this many seconds after a fast movement may lack lines
        var fastMotionWindow: TimeInterval = 0.1
        /// a block not confirmed where its area carried it is tried where the tiles under it went
        /// when that differs by more than this (thumbnail pixels: a header that sticks)
        var tileShiftDifference = 0.5
        /// a block read again where it may be cut off: what is read again reaches this share of a
        /// line plus `rereadAir` beyond each cut edge, and `rereadAir` beyond the others
        var rereadReach = 0.7
        var rereadAir = 4.0
        /// two blocks may be lines of one paragraph, and are read again together, when the gap
        /// between them is less than this share of a line and their lines differ in height by less
        /// than `sameLineHeight` (a rough test on the boxes; `TextLayout.blocks` then decides by the
        /// size of the text)
        var paragraphGap = 0.7
        var sameLineHeight = 0.25
        /// a new reading takes the place of a known block it covers this much of, when their
        /// texts are related (`TextSimilarity.isRelated`)
        var containedShare = 0.8
        /// a block a pass found found within this many thumbnail pixels of where the probes say
        /// it went
        var carryRadius = 2
        /// two blocks whose visible parts share more than this share of the smaller one are
        /// readings of the same text: only one of them is kept, unless one pass read them apart
        var overlapLimit = 0.2
    }

    let configuration: Configuration

    /// The paragraphs known on the current frame
    var blocks: [TrackedBlock] {
        var result: [TrackedBlock] = []
        for block in tracked {
            let rect = frameRect(of: block)
            let shown = shownTranslation(of: block)
            result.append(TrackedBlock(id: block.id, text: block.text, rect: rect, lineCount: block.lineCount,
                                       colors: block.colors, translation: shown,
                                       isStale: shown != nil && shownTranslation(for: block.text) == nil))
        }
        return result
    }

    /// The scrolling areas found so far, in frame pixels: text on both sides of an edge of one
    /// belongs to different things (content and a bar that stays), and text that reaches an edge
    /// that is known to the pixel may be cut off there
    var scrollingAreas: [ScrollingArea] {
        let factor = Double(scale)
        return areas.map { area in
            ScrollingArea(rect: CGRect(x: Double(area.rect.x) * factor, y: Double(area.rect.y) * factor,
                                       width: Double(area.rect.width) * factor, height: Double(area.rect.height) * factor),
                          knownEdges: area.refinedEdges)
        }
    }

    /// How many things the tracker holds that could pile up while it runs: blocks, scrolling
    /// areas, areas to read and what it remembers of texts. Only for checks that this stays
    /// bounded; tracking does not depend on it.
    var heldItemCount: Int {
        tracked.count + areas.count + plan.areas.count + plan.inFlight.count + translations.count + requested.count
            + failedAt.count
    }

    /// A paragraph followed from frame to frame
    private struct Block {
        var id: Int
        var text: String
        var lineCount: Int
        var colors: BlockColors
        /// size in frame pixels as recognized; kept while the block lives, so that the text drawn
        /// for it stays valid
        var width: Double
        var height: Double
        var patch: BlockPatch
        /// where the top left pixel of the patch lies in the current thumbnail
        var x: Double
        var y: Double
        /// the block's top left corner relative to that of the patch, thumbnail pixels
        var insetX: Double
        var insetY: Double
        /// the patch pixels that belong to the block
        var inner: ThumbnailRect
        /// what of `inner` shows in the current frame; nil = nothing (covered, gone, not found)
        var seen: ThumbnailRect?
        /// the scrolling area it moves with, -1 = none
        var areaID: Int
        /// since when it could not be found, nil = it is where it should be
        var lostSince: TimeInterval?
        /// the translation of an earlier reading of this place, shown until this one's is there
        var earlier: String?
        /// when its text was read (last confirmed by a reading of its place)
        var readAt: TimeInterval
        /// the edges (`FrameMotion.top`, `.bottom`) beyond which it may go on unseen: its text is
        /// not final yet (`Configuration.continuationReach`) …
        var openEdges: Int
        /// mean difference to its patch where it was found last
        var fit: Double
        /// the mean step between neighbouring pixels of its patch inside the block
        var texture: Double
    }

    /// A part of the screen whose content was seen to move as one (the view of a page between
    /// its bars), thumbnail pixels
    private struct ScrollArea {
        var id: Int
        var rect: ThumbnailRect
        /// the edges that were found to the pixel (`FrameMotion.top` …)
        var refinedEdges: Int
        var lastMoved: TimeInterval
        /// a refined top (bottom) edge that differs from the known one, seen in one frame only:
        /// it replaces the known edge when the next frame finds it again (rows that look alike
        /// can pass for the edge of a bar in a single frame)
        var pendingTop: Int?
        var pendingBottom: Int?
    }

    /// Points on a grid over the region of a pass that move with the picture until it ends
    private struct ProbeGrid {
        let originX: Double
        let originY: Double
        let spacing: Double
        let columns: Int
        let rows: Int
        /// where each point went with the scrolling area it lies in (content of an area moves as one)
        var x: [Double]
        var y: [Double]
        var valid: [Bool]
        /// … and where it went by what the tiles under it did (it may lie on something that stays)
        var tileX: [Double]
        var tileY: [Double]
        /// the scrolling area each point lay in when the pass started, -1 = none: it moves with it
        /// even where a rough edge of the area leaves it out for a frame
        var areaIDs: [Int]

        init(region: ThumbnailRect, spacing: Int) {
            columns = max(1, (region.width + spacing - 1) / spacing)
            rows = max(1, (region.height + spacing - 1) / spacing)
            self.spacing = Double(spacing)
            originX = Double(region.x) + min(Double(spacing), Double(region.width)) / 2
            originY = Double(region.y) + min(Double(spacing), Double(region.height)) / 2
            x = []
            y = []
            for row in 0..<rows {
                for column in 0..<columns {
                    x.append(originX + Double(column * spacing))
                    y.append(originY + Double(row * spacing))
                }
            }
            valid = [Bool](repeating: true, count: rows * columns)
            tileX = x
            tileY = y
            areaIDs = [Int](repeating: -1, count: rows * columns)
        }

        /// How far the picture moved since the start at a point of the frame the pass read: as the
        /// nearest valid probe says, with its area and by its tiles
        func displacement(atX pointX: Double, y pointY: Double) -> (dx: Double, dy: Double, tileDX: Double, tileDY: Double)? {
            let column = (pointX - originX) / spacing, row = (pointY - originY) / spacing
            var best: Int?
            var bestDistance = Double.infinity
            for candidateRow in [Int(floor(row)), Int(floor(row)) + 1] where candidateRow >= 0 && candidateRow < rows {
                for candidateColumn in [Int(floor(column)), Int(floor(column)) + 1]
                where candidateColumn >= 0 && candidateColumn < columns {
                    let index = candidateRow * columns + candidateColumn
                    guard valid[index] else { continue }
                    let distance = abs(Double(candidateRow) - row) + abs(Double(candidateColumn) - column)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = index
                    }
                }
            }
            guard let index = best else { return nil }
            let column0 = index % columns, row0 = index / columns
            let startX = originX + Double(column0) * spacing, startY = originY + Double(row0) * spacing
            return (x[index] - startX, y[index] - startY, tileX[index] - startX, tileY[index] - startY)
        }

        /// Around what the region shows now (thumbnail pixels), nil when nothing of it is left
        var currentBounds: CGRect? {
            var result: CGRect?
            for index in valid.indices where valid[index] {
                let point = CGRect(x: x[index] - spacing / 2, y: y[index] - spacing / 2, width: spacing, height: spacing)
                result = result.map { $0.union(point) } ?? point
            }
            return result
        }
    }

    /// A recognition pass that is running
    private struct Pass {
        var request: RecognitionRequest
        /// thumbnail pixels of the frame it reads
        var region: ThumbnailRect
        /// the thumbnail of that frame
        var picture: LumaImage
        var probes: ProbeGrid
        /// where the blocks were in that frame
        var startRects: [Int: CGRect]
        /// the picture moved fast when it started: its results may lack lines
        var whileMovingFast: Bool
        /// it reads only places that were cut off before: how often they have been read already
        var rereadAttempts: Int?
        /// when it started, and whether the picture rested then (`Configuration.restDelay`)
        var startTime: TimeInterval
        var startedAtRest: Bool
        /// the frames have a new size since: nothing of it fits
        var isObsolete = false
    }

    private var previous: LumaImage?
    private var scale = 1
    private let estimator: MotionEstimator
    private let matcher: PatchMatcher
    private let plan: ReadingPlan
    private var tracked: [Block] = []
    private var areas: [ScrollArea] = []
    /// for each motion of the current frame: the id of its scrolling area
    private var motionAreaIDs: [Int] = []
    /// the movements of the frame before: candidates for the next one
    private var priors: [FrameMotion] = []
    private var running: Pass?
    private var lastChange: TimeInterval = 0
    private var lastMotion: TimeInterval = -1000
    /// the largest movement of the last frame that moved, as a share of its area
    private var lastSpeedShare = 0.0
    private var nextBlockID = 1
    private var nextRequestID = 1
    private var nextAreaID = 1
    /// source text → translation (equal to the text: nothing to show)
    private var translations: [String: String] = [:]
    private var requested: Set<String> = []
    private var failedAt: [String: TimeInterval] = [:]
    /// per tile of the estimator: in how many frames in a row that moved it stayed while the
    /// content around it moved (see `Configuration.overlayFrames`)
    private var overlayHits: [UInt8] = []
    /// … and for each overlay tile the pixels where it shows (`MotionEstimator.stayBoxes`)
    private var overlayBoxes: [ThumbnailRect] = []
    // scratch for the changed parts of a frame
    private var visited: [Bool] = []
    private var stack: [Int] = []

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        estimator = MotionEstimator(configuration: configuration)
        matcher = PatchMatcher(configuration: configuration)
        plan = ReadingPlan(configuration: configuration)
    }

    // MARK: Frames

    /// Call once for every frame, in order. `thumbnail` is the frame reduced by `scale`
    /// (`LumaImage.downsampled`), `time` when it arrived. Moves the blocks with the content and
    /// returns the translations to draw into this very frame. Calling it again with the same
    /// picture is fine (a still picture is drawn again after a translation arrived).
    func advance(_ thumbnail: LumaImage, scale: Int, time: TimeInterval) -> FrameUpdate {
        precondition(scale >= 1, "OverlayTracker: scale must be at least 1")
        var change = FrameChange.unchanged
        var scrollX = 0.0, scrollY = 0.0
        if let previous {
            if previous.width != thumbnail.width || previous.height != thumbnail.height || self.scale != scale {
                forgetPicture()
                self.scale = scale
                startOver(thumbnail, time: time)
                change = .resized
            } else if previous.pixels == thumbnail.pixels {
                change = .unchanged
            } else if estimator.analyze(previous: previous, current: thumbnail, priors: priors) {
                let followed = follow(thumbnail, time: time)
                change = followed.change
                scrollX = followed.dx * Double(scale)
                scrollY = followed.dy * Double(scale)
            }
        } else {
            self.scale = scale
            startOver(thumbnail, time: time)
            change = .first
        }
        previous = thumbnail
        return FrameUpdate(change: change, scrollX: scrollX, scrollY: scrollY, placed: placed(),
                           recognitionDue: recognitionDue)
    }

    /// The picture has not changed for a moment (see `Configuration.settleTime`)
    func isSettled(at time: TimeInterval) -> Bool {
        previous != nil && time - lastChange >= configuration.settleTime
    }

    /// A first picture, or one of a new size: all of it has to be read
    private func startOver(_ thumbnail: LumaImage, time: TimeInterval) {
        lastChange = time
        plan.reset()
        plan.add(UnreadArea(rect: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height), kind: .changed,
                            since: time))
    }

    /// Follows what happened between the frame before and `current` (the estimator has compared
    /// them): moves blocks, areas to read and the probes of a running pass
    private func follow(_ current: LumaImage, time: TimeInterval) -> (change: FrameChange, dx: Double, dy: Double) {
        lastChange = time
        let motions = estimator.motions
        updateOverlays()
        updateScrollAreas(motions, in: current, time: time)
        moveBlocks(in: current, motions: motions, time: time)
        if running != nil { moveProbes(motions) }

        var regions: [CGRect] = [], shifts: [(dx: Double, dy: Double)] = []
        for (index, motion) in motions.enumerated() {
            let rect = scrollArea(id: motionAreaIDs[index])?.rect ?? motion.area
            regions.append(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            shifts.append((motion.dx, motion.dy))
        }
        plan.move(regions: regions, shifts: shifts,
                  bounds: CGRect(x: 0, y: 0, width: current.width, height: current.height))
        addEnteredStrips(motions, time: time)
        addChangedAreas(time: time)

        priors = motions
        guard let dominant = motions.max(by: { $0.tiles < $1.tiles }) else { return (.changed, 0, 0) }
        lastMotion = time
        var speed = 0.0
        for motion in motions {
            speed = max(speed, abs(motion.dy) / Double(max(1, motion.area.height)),
                        abs(motion.dx) / Double(max(1, motion.area.width)))
        }
        lastSpeedShare = speed
        return (.scrolled, dominant.dx, dominant.dy)
    }

    // MARK: What lies over the content

    /// Counts for every tile how often in a row it stayed while the content around it moved
    private func updateOverlays() {
        let count = estimator.kinds.count
        if overlayHits.count != count {
            overlayHits = [UInt8](repeating: 0, count: count)
            overlayBoxes = [ThumbnailRect](repeating: .empty, count: count)
        }
        for tile in 0..<count {
            switch estimator.kinds[tile] {
            case .moved, .entered, .changed, .drifted:
                overlayHits[tile] = 0
            case .still, .plain:
                let verdict = estimator.stillVerdicts[tile]
                if verdict == MotionEstimator.stillAgainstMotion {
                    overlayHits[tile] = min(200, overlayHits[tile] + 1)
                    let box = estimator.stayBoxes[tile]
                    overlayBoxes[tile] = overlayHits[tile] == 1 ? box : overlayBoxes[tile].union(box)
                } else if verdict == MotionEstimator.stillFits {
                    overlayHits[tile] = 0
                }
            }
        }
    }

    /// `rect` (thumbnail pixels) without what lies over the content there: cut off from the side
    /// that keeps most of it, as often as needed; nil when too little is left
    private func avoidingOverlays(_ rect: CGRect) -> CGRect? {
        guard !overlayHits.isEmpty, overlayHits.count == estimator.kinds.count else { return rect }
        let size = Double(configuration.tileSize)
        // A block that lies for the most part where something stays belongs to it (the title of
        // a bar the content slides under, a label of a tab bar): nothing to avoid.
        let own = estimator.tileRange(of: rect)
        var staying = ThumbnailRect.empty
        for row in own.rows {
            for column in own.columns {
                let tile = row * estimator.columns + column
                if Int(overlayHits[tile]) >= configuration.overlayFrames { staying = staying.union(overlayBoxes[tile]) }
            }
        }
        let common = rect.intersection(CGRect(x: staying.x, y: staying.y, width: staying.width, height: staying.height))
        if !staying.isEmpty, !common.isNull,
           common.width * common.height >= configuration.overlayOwnShare * rect.width * rect.height { return rect }
        var result = rect
        // (each pass removes one tile and the tiles next to it; a few overlays at most)
        for _ in 0..<8 {
            let range = estimator.tileRange(of: result.insetBy(dx: -size, dy: -size))
            var hit: CGRect?
            search: for row in range.rows {
                for column in range.columns where Int(overlayHits[row * estimator.columns + column])
                    >= configuration.overlayFrames {
                    // where it showed (a pixel more), else the tile and its neighbours
                    let tile = row * estimator.columns + column
                    let stays = overlayBoxes[tile]
                    let box = stays.isEmpty
                        ? CGRect(x: Double(column - 1) * size, y: Double(row - 1) * size, width: 3 * size, height: 3 * size)
                        : CGRect(x: stays.x - 1, y: stays.y - 1, width: stays.width + 2, height: stays.height + 2)
                    let common = box.intersection(result)
                    if !common.isNull, common.width > 0, common.height > 0 {
                        hit = box
                        break search
                    }
                }
            }
            guard let box = hit else { return result }
            // above, below, left of and right of it (sizes checked before a rectangle is made of
            // them: CGRect takes a negative size for one that extends the other way)
            let left = [result.minX, result.minX, result.minX, box.maxX]
            let top = [result.minY, box.maxY, result.minY, result.minY]
            let right = [result.maxX, result.maxX, box.minX, result.maxX]
            let bottom = [box.minY, result.maxY, result.maxY, result.maxY]
            var best: CGRect?
            var bestArea = 0.0
            for side in 0..<4 where right[side] > left[side] && bottom[side] > top[side] {
                let area = Double((right[side] - left[side]) * (bottom[side] - top[side]))
                if area > bestArea {
                    bestArea = area
                    best = CGRect(x: left[side], y: top[side], width: right[side] - left[side],
                                  height: bottom[side] - top[side])
                }
            }
            guard let kept = best else { return nil }
            result = kept
        }
        return result
    }

    // MARK: Scrolling areas

    private func scrollArea(id: Int) -> ScrollArea? {
        areas.first { $0.id == id }
    }

    /// Every movement belongs to the scrolling area it overlaps most, or to a new one; areas that
    /// changed for the most part (another screen) are forgotten
    private func updateScrollAreas(_ motions: [FrameMotion], in current: LumaImage, time: TimeInterval) {
        // forget what is gone
        areas.removeAll { area in
            var changed = 0, total = 0
            let range = estimator.tileRange(of: CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width,
                                                       height: area.rect.height))
            for row in range.rows {
                for column in range.columns {
                    total += 1
                    if estimator.kinds[row * estimator.columns + column] == .changed { changed += 1 }
                }
            }
            return total > 0 && changed * 2 >= total
        }
        let known = Set(areas.map(\.id))
        for index in tracked.indices where tracked[index].areaID >= 0 && !known.contains(tracked[index].areaID) {
            tracked[index].areaID = -1
        }

        motionAreaIDs = []
        for motion in motions {
            var found: Int?
            var bestOverlap = 0
            for (index, area) in areas.enumerated() {
                let overlap = area.rect.intersection(motion.area).area
                if overlap * 2 >= min(area.rect.area, motion.area.area), overlap > bestOverlap,
                   !motionAreaIDs.contains(area.id) {
                    bestOverlap = overlap
                    found = index
                }
            }
            if let index = found {
                var motion = motion
                motion.refinedEdges &= ~OverlayTracker.plainShrink(of: areas[index].rect, edges: areas[index].refinedEdges,
                                                                    to: motion, in: current,
                                                                    plainRange: configuration.plainRange)
                let seen = confirmedEdges(of: motion, in: &areas[index])
                areas[index].rect = OverlayTracker.merged(areas[index].rect, refinedEdges: areas[index].refinedEdges,
                                                          with: seen.area, refined: seen.refined)
                areas[index].refinedEdges |= motion.refinedEdges
                areas[index].lastMoved = time
                motionAreaIDs.append(areas[index].id)
            } else {
                areas.append(ScrollArea(id: nextAreaID, rect: motion.area, refinedEdges: motion.refinedEdges,
                                        lastMoved: time))
                motionAreaIDs.append(nextAreaID)
                nextAreaID += 1
            }
        }
    }

    /// The refined top and bottom edges of a movement that lie inside the known refined edges of
    /// its area with nothing but plain rows between them: the end of a page whose ground shows no
    /// movement (it stops there while it springs back), not a bar. They do not move the edge.
    static func plainShrink(of known: ThumbnailRect, edges: Int, to motion: FrameMotion, in image: LumaImage,
                            plainRange: Int) -> Int {
        let left = max(0, motion.area.x), right = min(image.width, motion.area.maxX)
        guard right > left else { return 0 }
        func isPlain(_ rows: Range<Int>) -> Bool {
            for y in rows where y >= 0 && y < image.height {
                var low = UInt8.max, high = UInt8.min
                for x in left..<right {
                    let value = image[x, y]
                    low = min(low, value)
                    high = max(high, value)
                }
                if Int(high) - Int(low) > plainRange { return false }
            }
            return true
        }
        var result = 0
        if motion.refinedEdges & FrameMotion.top != 0, edges & FrameMotion.top != 0,
           motion.area.y > known.y, isPlain(known.y..<motion.area.y) {
            result |= FrameMotion.top
        }
        if motion.refinedEdges & FrameMotion.bottom != 0, edges & FrameMotion.bottom != 0,
           motion.area.maxY < known.maxY, isPlain(motion.area.maxY..<known.maxY) {
            result |= FrameMotion.bottom
        }
        return result
    }

    /// The movement's area with a refined top or bottom edge left out (as not refined) when it
    /// moved by more than `edgeJitter` from the known refined edge and was not seen there in the
    /// frame before as well
    private func confirmedEdges(of motion: FrameMotion, in area: inout ScrollArea) -> (area: ThumbnailRect, refined: Int) {
        var refined = motion.refinedEdges
        let jitter = configuration.edgeJitter
        if refined & FrameMotion.top != 0, area.refinedEdges & FrameMotion.top != 0,
           abs(motion.area.y - area.rect.y) > jitter {
            if let pending = area.pendingTop, abs(pending - motion.area.y) <= jitter {
                area.pendingTop = nil
            } else {
                area.pendingTop = motion.area.y
                refined &= ~FrameMotion.top
            }
        } else if refined & FrameMotion.top != 0 {
            area.pendingTop = nil
        }
        if refined & FrameMotion.bottom != 0, area.refinedEdges & FrameMotion.bottom != 0,
           abs(motion.area.maxY - area.rect.maxY) > jitter {
            if let pending = area.pendingBottom, abs(pending - motion.area.maxY) <= jitter {
                area.pendingBottom = nil
            } else {
                area.pendingBottom = motion.area.maxY
                refined &= ~FrameMotion.bottom
            }
        } else if refined & FrameMotion.bottom != 0 {
            area.pendingBottom = nil
        }
        guard refined != motion.refinedEdges else { return (motion.area, refined) }
        // (an edge not taken leaves the known one as it is, and may only make the area grow)
        var top = motion.area.y, bottom = motion.area.maxY
        if refined & FrameMotion.top == 0, motion.refinedEdges & FrameMotion.top != 0 { top = max(top, area.rect.y) }
        if refined & FrameMotion.bottom == 0, motion.refinedEdges & FrameMotion.bottom != 0 {
            bottom = min(bottom, area.rect.maxY)
        }
        guard bottom > top else { return (area.rect, refined) }
        return (ThumbnailRect(x: motion.area.x, y: top, width: motion.area.width, height: bottom - top), refined)
    }

    /// The area seen in this frame added to what was known: an edge found to the pixel replaces
    /// the one known, other edges only grow
    private static func merged(_ known: ThumbnailRect, refinedEdges: Int, with seen: ThumbnailRect, refined: Int) -> ThumbnailRect {
        let grown = known.union(seen)
        var left = grown.x, top = grown.y, right = grown.maxX, bottom = grown.maxY
        if refined & FrameMotion.left != 0 { left = seen.x }
        if refined & FrameMotion.top != 0 { top = seen.y }
        if refined & FrameMotion.right != 0 { right = seen.maxX }
        if refined & FrameMotion.bottom != 0 { bottom = seen.maxY }
        // (a known edge found to the pixel is not given up for a rough one)
        if refined & FrameMotion.left == 0, refinedEdges & FrameMotion.left != 0 { left = known.x }
        if refined & FrameMotion.top == 0, refinedEdges & FrameMotion.top != 0 { top = known.y }
        if refined & FrameMotion.right == 0, refinedEdges & FrameMotion.right != 0 { right = known.maxX }
        if refined & FrameMotion.bottom == 0, refinedEdges & FrameMotion.bottom != 0 { bottom = known.maxY }
        guard right > left, bottom > top else { return grown }
        return ThumbnailRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The index of the motion of this frame that moves a scrolling area, nil if it did not move
    private func motionIndex(ofArea id: Int) -> Int? {
        guard id >= 0 else { return nil }
        return motionAreaIDs.firstIndex(of: id)
    }

    // MARK: Blocks

    private func thumbnailRect(of block: Block) -> CGRect {
        let factor = Double(scale)
        return CGRect(x: block.x + block.insetX, y: block.y + block.insetY, width: block.width / factor,
                      height: block.height / factor)
    }

    private func frameRect(of block: Block) -> CGRect {
        let factor = Double(scale)
        return CGRect(x: (block.x + block.insetX) * factor, y: (block.y + block.insetY) * factor, width: block.width,
                      height: block.height)
    }

    /// Moves every block whose part of the picture changed: to where its patch fits best near
    /// one of the movements of this frame, and checks what of it can still be seen
    private func moveBlocks(in current: LumaImage, motions: [FrameMotion], time: TimeInterval) {
        for index in tracked.indices {
            var block = tracked[index]
            let rect = thumbnailRect(of: block)
            guard isActive(under: rect) || block.seen == nil else { continue }
            let own = motionIndex(ofArea: block.areaID)
            var found = false
            let likely = candidates(for: block, rect: rect, own: own, motions: motions, in: current)
            var ordered: [Int] = []
            if let primary = likely.primary { ordered.append(primary) }
            ordered += likely.others
            for candidate in ordered {
                let dx = candidate >= 0 ? motions[candidate].dx : 0, dy = candidate >= 0 ? motions[candidate].dy : 0
                let isPrimary = likely.primary == nil || candidate == likely.primary
                if !isPrimary, let primary = likely.primary,
                   !isInView(rect.offsetBy(dx: motions[primary].dx, dy: motions[primary].dy), motion: primary) {
                    // its area carried it out of view: it is gone, not elsewhere
                    break
                }
                let part = block.seen ?? block.inner
                var x = block.x + dx, y = block.y + dy
                // (a block at the edge of its area is placed by the movement: the rows that are left of
                // it would place it worse, and they are about to be covered as well)
                if part == block.inner || block.seen == nil,
                   isWellInside(rect.offsetBy(dx: dx, dy: dy), motion: candidate),
                   let located = matcher.locate(block.patch, in: current, x: x, y: y, part: part, radius: 1),
                   // (what did not move stays exactly where it was: no jitter at rest)
                   candidate >= 0 || abs(located.x - x) >= configuration.restingShift
                    || abs(located.y - y) >= configuration.restingShift {
                    x = located.x
                    y = located.y
                }
                // the common case: all of it showed, it fits very well, and nothing can cover it from an edge
                let placed = rect.offsetBy(dx: x - block.x, dy: y - block.y)
                if candidate == likely.primary || likely.primary == nil, block.seen == block.inner,
                   isWellInside(placed, motion: candidate), !isReached(placed, exceptMotion: candidate, motions: motions),
                   let fit = matcher.difference(block.patch, in: current, x: x, y: y, part: block.inner, squared: false),
                   fit <= configuration.sureFitBase + configuration.sureFitTexture * block.texture,
                   !(abs(x - block.x) < configuration.restingShift && abs(y - block.y) < configuration.restingShift
                     && fit > block.fit + configuration.refitTolerance) {
                    if abs(x - block.x) >= configuration.restingShift || abs(y - block.y) >= configuration.restingShift
                        || fit < block.fit {
                        block.fit = fit
                    }
                    block.x = x
                    block.y = y
                    block.lostSince = nil
                    if candidate >= 0 { block.areaID = motionAreaIDs[candidate] }
                    found = true
                    break
                }
                guard let (seen, fit) = check(block, in: current, x: x, y: y),
                      isPossible(seen, after: block.seen, moving: (dx, dy), motions: motions) else {
                    continue
                }
                // One that was lost, or that does not move with its area, must show as a whole and fit
                // about as well as before: a part of it, or a line that looks alike, may fit elsewhere.
                if block.seen == nil || !isPrimary {
                    guard seen == block.inner, fit <= block.fit + configuration.refitTolerance else { continue }
                }
                // One that stayed where it was has no misalignment to allow for: fitting worse than when
                // it was confirmed is its text fading away (into another screen, under a veil).
                let stayed = abs(x - block.x) < configuration.restingShift && abs(y - block.y) < configuration.restingShift
                if stayed, fit > block.fit + configuration.refitTolerance { continue }
                block.x = x
                block.y = y
                block.seen = seen
                if !stayed || fit < block.fit { block.fit = fit }
                block.lostSince = nil
                if candidate >= 0 { block.areaID = motionAreaIDs[candidate] }
                found = true
                break
            }
            if !found {
                // out of sight: it goes on moving with its area (or what moved under it), it may come back
                if let moving = likely.primary {
                    block.x += motions[moving].dx
                    block.y += motions[moving].dy
                    block.areaID = motionAreaIDs[moving]
                }
                if block.seen != nil, !isActive(under: rect, kind: .changed) {
                    // gone without anything changing there (a slow fade): read the place again
                    plan.add(UnreadArea(rect: rect, kind: .changed, since: time))
                }
                block.seen = nil
                block.lostSince = block.lostSince ?? time
            }
            tracked[index] = block
        }
        tracked.removeAll { block in
            guard let lost = block.lostSince else { return false }
            return time - lost > configuration.lostLifetime
        }
        // (a block found again where a later reading lies)
        dropOverlaps(attempts: 0, time: time)
    }

    /// Where a block may have gone, the likeliest first: with the scrolling area it moves with,
    /// or else the one it lies in (content of an area moves as one, also where rows look alike);
    /// then nowhere and with the other movements nearby, the one that fits best first
    private func candidates(for block: Block, rect: CGRect, own: Int?, motions: [FrameMotion],
                            in current: LumaImage) -> (primary: Int?, others: [Int]) {
        let primary = own ?? movingArea(atX: rect.midX, y: rect.midY)
        var rest: [Int] = [-1]
        for (motionIndex, motion) in motions.enumerated() where motionIndex != primary {
            let reach = rect.insetBy(dx: -abs(motion.dx) - 1, dy: -abs(motion.dy) - 1)
            let area = scrollArea(id: motionAreaIDs[motionIndex])?.rect ?? motion.area
            if reach.intersects(CGRect(x: area.x, y: area.y, width: area.width, height: area.height)) {
                rest.append(motionIndex)
            }
        }
        let part = block.seen ?? block.inner
        var costs: [Double] = []
        for candidate in rest {
            let dx = candidate >= 0 ? motions[candidate].dx : 0, dy = candidate >= 0 ? motions[candidate].dy : 0
            costs.append(matcher.difference(block.patch, in: current, x: block.x + dx, y: block.y + dy, part: part,
                                            squared: false) ?? .infinity)
        }
        var others: [Int] = []
        for index in rest.indices.sorted(by: { costs[$0] < costs[$1] }) where costs[index].isFinite {
            others.append(rest[index])
        }
        return (primary, others)
    }

    /// Something can only cover a block from an edge as fast as it moves against the block: a
    /// cut that grew faster is the block in the wrong place (text that looks alike in part)
    private func isPossible(_ seen: ThumbnailRect, after before: ThumbnailRect?, moving: (dx: Double, dy: Double),
                            motions: [FrameMotion]) -> Bool {
        guard let before else { return true }
        var acrossX = abs(moving.dx), acrossY = abs(moving.dy)
        for motion in motions {
            acrossX = max(acrossX, abs(motion.dx - moving.dx))
            acrossY = max(acrossY, abs(motion.dy - moving.dy))
        }
        let slackY = acrossY + configuration.cutSlack
        let slackX = acrossX + configuration.cutSlack + Double(configuration.columnChunk)
        return Double(seen.y - before.y) <= slackY && Double(before.maxY - seen.maxY) <= slackY
            && Double(seen.x - before.x) <= slackX && Double(before.maxX - seen.maxX) <= slackX
    }

    /// Whether any tile under `rect` moved or changed (or changed in a way no motion explains)
    private func isActive(under rect: CGRect, kind wanted: TileKind? = nil) -> Bool {
        let range = estimator.tileRange(of: rect)
        for row in range.rows {
            for column in range.columns {
                let kind = estimator.kinds[row * estimator.columns + column]
                if let wanted {
                    if kind == wanted { return true }
                } else if kind == .moved || kind == .entered || kind == .changed || kind == .drifted {
                    return true
                }
            }
        }
        return false
    }

    /// What of a block shows with its patch at (x, y), and how well it fits there (mean
    /// difference); nil when it does not fit the picture
    private func check(_ block: Block, in current: LumaImage, x: Double, y: Double) -> (ThumbnailRect, Double)? {
        guard let seen = matcher.visiblePart(block.patch, in: current, x: x, y: y, inner: block.inner),
              let fit = matcher.difference(block.patch, in: current, x: x, y: y, part: seen, squared: false)
        else { return nil }
        var texture = 0.0
        for row in seen.y..<seen.maxY {
            texture += block.patch.rowTexture[row]
        }
        texture /= Double(seen.height)
        return fit <= configuration.fitBase + configuration.fitTexture * texture ? (seen, fit) : nil
    }

    /// A place lies inside the frame and inside its scrolling area with room to spare: nothing
    /// that does not move with it can reach it in this frame
    private func isWellInside(_ rect: CGRect, motion: Int) -> Bool {
        guard let previous else { return false }
        let room = configuration.sureRoom
        var view = CGRect(x: 0, y: 0, width: previous.width, height: previous.height)
        if motion >= 0, let area = scrollArea(id: motionAreaIDs[motion]) {
            view = view.intersection(CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width,
                                            height: area.rect.height))
        }
        view = view.insetBy(dx: room, dy: room)
        return !view.isNull && rect.minX >= view.minX && rect.minY >= view.minY && rect.maxX <= view.maxX
            && rect.maxY <= view.maxY
    }

    /// Something else moves or changes at or near a place in this frame: another moving part
    /// (a keyboard, a sheet) or a change no movement explains (a dialog appearing)
    private func isReached(_ rect: CGRect, exceptMotion own: Int, motions: [FrameMotion]) -> Bool {
        for (index, motion) in motions.enumerated() where index != own {
            let reach = rect.insetBy(dx: -abs(motion.dx) - configuration.sureRoom,
                                     dy: -abs(motion.dy) - configuration.sureRoom)
            let area = motion.area
            if reach.intersects(CGRect(x: area.x, y: area.y, width: area.width, height: area.height)) { return true }
        }
        let near = rect.insetBy(dx: -Double(configuration.tileSize), dy: -Double(configuration.tileSize))
        return isActive(under: near, kind: .changed)
    }

    /// A place lies inside the frame and inside the scrolling area of a motion of this frame
    private func isInView(_ rect: CGRect, motion: Int) -> Bool {
        guard let previous else { return false }
        var view = CGRect(x: 0, y: 0, width: previous.width, height: previous.height)
        if let area = scrollArea(id: motionAreaIDs[motion]) {
            view = view.intersection(CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width,
                                            height: area.rect.height))
        }
        return rect.minX >= view.minX && rect.minY >= view.minY && rect.maxX <= view.maxX && rect.maxY <= view.maxY
    }

    // MARK: Drawing

    private func placed() -> [PlacedBlock] {
        guard let previous else { return [] }
        var result: [PlacedBlock] = []
        let factor = Double(scale)
        let bounds = CGRect(x: 0, y: 0, width: previous.width, height: previous.height)
        for block in tracked {
            guard let seen = block.seen, let text = shownTranslation(of: block) else { continue }
            let rect = thumbnailRect(of: block)
            var visible = rect
            if seen != block.inner {
                visible = visible.intersection(CGRect(x: block.x + Double(seen.x), y: block.y + Double(seen.y),
                                                      width: Double(seen.width), height: Double(seen.height)))
            }
            if let area = scrollArea(id: block.areaID) {
                visible = visible.intersection(CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width,
                                                      height: area.rect.height))
            }
            visible = visible.intersection(bounds)
            guard !visible.isNull, let clear = avoidingOverlays(visible),
                  // (what an overlay leaves of it must be a good part of it)
                  clear == visible || clear.width * clear.height >= configuration.minVisibleShare * visible.width
                    * visible.height else { continue }
            visible = clear
            // (a sliver shows nothing)
            guard visible.width > 1, visible.height > 1 else { continue }
            let isWhole = abs(visible.minX - rect.minX) < 1e-6 && abs(visible.minY - rect.minY) < 1e-6
                && abs(visible.maxX - rect.maxX) < 1e-6 && abs(visible.maxY - rect.maxY) < 1e-6
            let visibleRect = isWhole ? nil : CGRect(x: visible.minX * factor, y: visible.minY * factor,
                                                     width: visible.width * factor, height: visible.height * factor)
            result.append(PlacedBlock(id: block.id, text: text, rect: frameRect(of: block), visibleRect: visibleRect,
                                      lineCount: block.lineCount, colors: block.colors))
        }
        return result
    }

    // MARK: Reading

    /// When `beginRecognition` should be called (same clock as `advance`; a time in the past
    /// means now). nil = nothing to read, or a pass is running.
    var recognitionDue: TimeInterval? {
        guard previous != nil, running == nil else { return nil }
        return plan.due(lastMotion: lastMotion, isFullyVisible: isFullyVisible)
    }

    /// A place can be seen completely: inside the frame and inside the scrolling area it lies in,
    /// away from their edges
    private func isFullyVisible(_ rect: CGRect) -> Bool {
        guard let previous else { return false }
        let edge = configuration.cutEdge
        guard rect.minX >= edge, rect.minY >= edge, rect.maxX <= Double(previous.width) - edge,
              rect.maxY <= Double(previous.height) - edge else { return false }
        for area in areas where area.rect.contains(x: rect.midX, y: rect.midY) {
            let inner = CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width, height: area.rect.height)
                .insetBy(dx: edge, dy: edge)
            if rect.minX < inner.minX || rect.minY < inner.minY || rect.maxX > inner.maxX || rect.maxY > inner.maxY {
                return false
            }
        }
        return true
    }

    /// Starts reading the frame given to the last `advance`. nil = nothing to read yet, or a
    /// pass is already running (one at a time).
    func beginRecognition(time: TimeInterval) -> RecognitionRequest? {
        guard let previous, let due = recognitionDue, time >= due else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: previous.width, height: previous.height)
        guard let region = plan.takeRegion(at: time, lastMotion: lastMotion, bounds: bounds,
                                           isFullyVisible: isFullyVisible) else { return nil }
        let pixels = ThumbnailRect(x: Int(region.minX), y: Int(region.minY), width: Int(region.width),
                               height: Int(region.height))
        let isFullFrame = pixels == ThumbnailRect(x: 0, y: 0, width: previous.width, height: previous.height)
        let factor = CGFloat(scale)
        let request = RecognitionRequest(id: nextRequestID, region: CGRect(x: region.minX * factor, y: region.minY * factor,
                                                                           width: region.width * factor,
                                                                           height: region.height * factor),
                                         isFullFrame: isFullFrame)
        nextRequestID += 1
        var startRects: [Int: CGRect] = [:]
        for block in tracked {
            startRects[block.id] = thumbnailRect(of: block)
        }
        let isFast = time - lastMotion <= configuration.fastMotionWindow && lastSpeedShare > configuration.fastMotionShare
        var probes = ProbeGrid(region: pixels, spacing: configuration.probeSpacing)
        for index in probes.areaIDs.indices {
            var smallest = Int.max
            for area in areas where area.rect.contains(x: probes.x[index], y: probes.y[index]) && area.rect.area < smallest {
                probes.areaIDs[index] = area.id
                smallest = area.rect.area
            }
        }
        running = Pass(request: request, region: pixels, picture: previous,
                       probes: probes, startRects: startRects,
                       whileMovingFast: isFast, rereadAttempts: plan.rereadAttemptsInFlight, startTime: time,
                       startedAtRest: time - lastMotion >= configuration.restDelay)
        return request
    }

    /// Moves the probes of the running pass with the picture: with the scrolling area they lie
    /// in, and (separately) as the tiles under them did
    private func moveProbes(_ motions: [FrameMotion]) {
        guard var pass = running else { return }
        for index in pass.probes.valid.indices where pass.probes.valid[index] {
            let x = pass.probes.x[index], y = pass.probes.y[index]
            guard let tile = estimator.tile(atX: x, y: y) else {
                pass.probes.valid[index] = false
                continue
            }
            let kind = estimator.kinds[tile]
            let area = motionIndex(ofArea: pass.probes.areaIDs[index]) ?? movingArea(atX: x, y: y)
            var motion: Int?
            if kind == .moved || kind == .entered {
                motion = Int(estimator.motionIndex[tile])
            }
            if let area {
                pass.probes.x[index] += motions[area].dx
                pass.probes.y[index] += motions[area].dy
            } else if let motion {
                pass.probes.x[index] += motions[motion].dx
                pass.probes.y[index] += motions[motion].dy
            } else if kind == .changed {
                // changed where nothing moves: what was read there is gone
                pass.probes.valid[index] = false
                continue
            }
            let tileX = pass.probes.tileX[index], tileY = pass.probes.tileY[index]
            if let tileHere = estimator.tile(atX: tileX, y: tileY) {
                let tileKind = estimator.kinds[tileHere]
                if tileKind == .moved || tileKind == .entered {
                    let byTile = Int(estimator.motionIndex[tileHere])
                    pass.probes.tileX[index] += motions[byTile].dx
                    pass.probes.tileY[index] += motions[byTile].dy
                }
            }
        }
        running = pass
    }

    /// The motion of this frame whose scrolling area holds a point (the smallest of them)
    private func movingArea(atX x: Double, y: Double) -> Int? {
        var best: Int?
        var smallest = Int.max
        for (index, id) in motionAreaIDs.enumerated() {
            guard let area = scrollArea(id: id), area.rect.contains(x: x, y: y), area.rect.area < smallest else { continue }
            smallest = area.rect.area
            best = index
        }
        return best
    }

    /// The result of a pass: every paragraph found inside `request.region` of the frame the pass
    /// started on, in the pixels of that frame. Blocks that are known already keep their
    /// translation; blocks of the region that were not found again are removed.
    func finishRecognition(_ request: RecognitionRequest, blocks recognized: [RecognizedBlock], time: TimeInterval) {
        guard let pass = running, pass.request == request else { return }
        running = nil
        guard !pass.isObsolete, let current = previous else {
            plan.finishPass(succeeded: false)
            return
        }
        plan.finishPass(succeeded: true)
        let factor = Double(scale)
        var taken: Set<Int> = []
        // the blocks that took a reading of this pass (their edges are as that reading says)
        var readNow: Set<Int> = []
        // (the picture rested all the while: what is cut off by an edge of the view stays so)
        let atRest = pass.startedAtRest && lastMotion < pass.startTime
        // (a place this pass asks to read again counts one more attempt when the pass itself read
        // only places to read again)
        let rereadAttempt = (pass.rereadAttempts ?? -1) + 1
        // (what reaches beyond the frame by more than its size is no paragraph of it)
        let reach = CGRect(x: -Double(current.width), y: -Double(current.height), width: 3 * Double(current.width),
                           height: 3 * Double(current.height))
        for found in recognized {
            let given = found.rect
            guard given.minX.isFinite, given.minY.isFinite, given.width.isFinite, given.height.isFinite,
                  given.width > 0, given.height > 0 else { continue }
            let rect = CGRect(x: given.minX / factor, y: given.minY / factor, width: given.width / factor,
                              height: given.height / factor).intersection(reach)
            guard !rect.isNull, rect.width > 0, rect.height > 0,
                  rect.intersects(CGRect(x: 0, y: 0, width: current.width, height: current.height)) else { continue }
            guard let shift = pass.probes.displacement(atX: rect.midX, y: rect.midY) else { continue }
            // (a line of it read only in part: something hides it there that is not known as an
            // edge, such as a bar the content shows through)
            let edges = cutEdges(of: rect, in: pass.region)
            let cut = edges | found.cutOffEdges
            // (but a bar may stay: read again at rest, a paragraph is taken as far as it shows,
            // and so is a line that may be cut off – not one that is garbage beyond doubt)
            let settles = edges == 0 && !found.isGarbled
            if cut != 0, !(settles && atRest && pass.rereadAttempts != nil) {
                // (the blocks it lies over stay until their place is read completely)
                let now = rect.offsetBy(dx: shift.dx, dy: shift.dy)
                for block in tracked where block.seen != nil && thumbnailRect(of: block).intersects(now) {
                    taken.insert(block.id)
                }
                askToReread(found.text, rect, cut: cut, lineCount: found.lineCount, shift: (shift.dx, shift.dy), pass: pass,
                            settles: settles, isGarbled: found.isGarbled, time: time)
                continue
            }
            var made = makeBlock(found, rect: rect, picture: pass.picture, shift: (shift.dx, shift.dy), in: current,
                                 mustShowWhole: false, keepsUnseen: false, time: time)
            if made == nil, abs(shift.tileDX - shift.dx) > configuration.tileShiftDifference
                || abs(shift.tileDY - shift.dy) > configuration.tileShiftDifference {
                // (it may lie on something that stays while its area moves: a header that sticks)
                made = makeBlock(found, rect: rect, picture: pass.picture, shift: (shift.tileDX, shift.tileDY),
                                 in: current, mustShowWhole: true, keepsUnseen: false, time: time)
            }
            if made == nil, pass.whileMovingFast {
                // Read while the picture moved fast: the frame now may be too damaged to confirm it.
                // It is kept out of sight where its area took it, and shows once all of it is seen.
                made = makeBlock(found, rect: rect, picture: pass.picture, shift: (shift.dx, shift.dy), in: current,
                                 mustShowWhole: false, keepsUnseen: true, time: time)
            }
            guard var block = made else { continue }
            closeEdgesInView(&block, rect: rect, atRest: atRest)
            let index: Int
            if let known = absorb(&block, attempts: rereadAttempt, time: time) {
                index = known
            } else {
                tracked.append(block)
                index = tracked.count - 1
            }
            taken.insert(tracked[index].id)
            readNow.insert(tracked[index].id)
        }
        closeEdges(read: pass, found: recognized, atRest: atRest, except: readNow, time: time)
        for index in tracked.indices where tracked[index].openEdges != 0 {
            closeBlankEdges(&tracked[index])
            askToReadBeyond(tracked[index], time: time)
        }
        // what was read and not found again is gone
        let inner = CGRect(x: pass.region.x, y: pass.region.y, width: pass.region.width, height: pass.region.height)
            .insetBy(dx: configuration.cutEdge, dy: configuration.cutEdge)
        let bounds = CGRect(x: 0, y: 0, width: current.width, height: current.height)
        tracked.removeAll { block in
            guard !taken.contains(block.id), let start = pass.startRects[block.id] else { return false }
            let gone = start.minX >= inner.minX && start.minY >= inner.minY && start.maxX <= inner.maxX
                && start.maxY <= inner.maxY
            if gone, !atRest {
                // (read while the picture moved, a line may have been missed: its place is read
                // again once it rests)
                plan.add(UnreadArea(rect: thumbnailRect(of: block).intersection(bounds), kind: .confirm, since: time))
            }
            return gone
        }
        dropOverlaps(attempts: rereadAttempt, time: time)
        askToReadParagraphsTogether(taken, time: time)
        if pass.whileMovingFast, let bounds = pass.probes.currentBounds {
            plan.add(UnreadArea(rect: bounds.intersection(CGRect(x: 0, y: 0, width: current.width, height: current.height)),
                                kind: .confirm, since: time))
        }
    }

    /// The pass failed: its region still has to be read.
    func abandonRecognition(_ request: RecognitionRequest) {
        guard let pass = running, pass.request == request else { return }
        running = nil
        plan.finishPass(succeeded: false)
    }

    /// The edges (`FrameMotion.top` …) at which a block may have been cut off: it reaches the
    /// edge of the region that was read, of the frame, or of the scrolling area it lies in
    private func cutEdges(of rect: CGRect, in region: ThumbnailRect) -> Int {
        let edge = configuration.cutEdge
        var cut = 0
        if rect.minX <= Double(region.x) + edge { cut |= FrameMotion.left }
        if rect.minY <= Double(region.y) + edge { cut |= FrameMotion.top }
        if rect.maxX >= Double(region.maxX) - edge { cut |= FrameMotion.right }
        if rect.maxY >= Double(region.maxY) - edge { cut |= FrameMotion.bottom }
        for area in areas where area.rect.contains(x: rect.midX, y: rect.midY) {
            let edges = area.refinedEdges
            if edges & FrameMotion.left != 0, rect.minX <= Double(area.rect.x) + edge { cut |= FrameMotion.left }
            if edges & FrameMotion.top != 0, rect.minY <= Double(area.rect.y) + edge { cut |= FrameMotion.top }
            if edges & FrameMotion.right != 0, rect.maxX >= Double(area.rect.maxX) - edge { cut |= FrameMotion.right }
            if edges & FrameMotion.bottom != 0, rect.maxY >= Double(area.rect.maxY) - edge { cut |= FrameMotion.bottom }
        }
        return cut
    }

    /// The band beyond the top or bottom edge of a paragraph (thumbnail pixels) in which a line
    /// that continues it would begin, and enough of that line to read it
    private func band(beyond edge: Int, of rect: CGRect, lineCount: Int) -> CGRect {
        let reach = configuration.continuationReach * rect.height / Double(max(1, lineCount))
        let y = edge == FrameMotion.top ? rect.minY - reach : rect.maxY
        return CGRect(x: rect.minX, y: y, width: rect.width, height: reach)
    }

    /// What can be seen around a place (thumbnail pixels): the frame and the scrolling areas
    /// it lies in
    private func view(around rect: CGRect) -> CGRect {
        guard let previous else { return .null }
        var view = CGRect(x: 0, y: 0, width: previous.width, height: previous.height)
        for area in areas where area.rect.contains(x: rect.midX, y: rect.midY) {
            view = view.intersection(CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width,
                                            height: area.rect.height))
        }
        return view
    }

    /// Closes the open edges of a block (its place in the frame a pass read: `rect`) whose band
    /// lies in view, or all of them once the picture rests: a line that continues it would have
    /// come into view there, and been read with what came in
    private func closeEdgesInView(_ block: inout Block, rect: CGRect, atRest: Bool) {
        guard block.openEdges != 0 else { return }
        if atRest {
            block.openEdges = 0
            return
        }
        let view = self.view(around: rect)
        guard !view.isNull else { return }
        for edge in [FrameMotion.top, FrameMotion.bottom] where block.openEdges & edge != 0 {
            let band = self.band(beyond: edge, of: rect, lineCount: block.lineCount)
            if edge == FrameMotion.top ? band.minY >= view.minY : band.maxY <= view.maxY { block.openEdges &= ~edge }
        }
    }

    /// The bands beyond the open edges of a block are read once the picture rests (a pass then
    /// takes what it shows as it is, and the translation is asked for after it)
    private func askToReadBeyond(_ block: Block, time: TimeInterval) {
        guard let previous, block.openEdges != 0, block.seen != nil else { return }
        let rect = thumbnailRect(of: block)
        let bounds = CGRect(x: 0, y: 0, width: previous.width, height: previous.height)
        for edge in [FrameMotion.top, FrameMotion.bottom] where block.openEdges & edge != 0 {
            // (in the frame: a pass reads the block with what it shows of the band)
            let place = band(beyond: edge, of: rect, lineCount: block.lineCount).union(rect).intersection(bounds)
            guard !place.isNull, place.width >= 1, place.height >= 1 else { continue }
            plan.add(UnreadArea(rect: place, kind: .rest, since: time))
        }
    }

    /// Edges of a block beyond which the current frame shows nothing where a line that continues
    /// it would show its letters: rows from a quarter of a line to `inkReach` lines beyond it are
    /// plain, in view
    private func closeBlankEdges(_ block: inout Block) {
        guard let previous, block.seen != nil, block.lostSince == nil else { return }
        let rect = thumbnailRect(of: block)
        let view = self.view(around: rect)
        guard !view.isNull else { return }
        let lineHeight = rect.height / Double(max(1, block.lineCount))
        let left = max(0, Int(floor(rect.minX))), right = min(previous.width, Int(ceil(rect.maxX)))
        guard right > left else { return }
        for edge in [FrameMotion.top, FrameMotion.bottom] where block.openEdges & edge != 0 {
            let near = 0.25 * lineHeight, far = configuration.inkReach * lineHeight
            let from = edge == FrameMotion.top ? rect.minY - far : rect.maxY + near
            let to = edge == FrameMotion.top ? rect.minY - near : rect.maxY + far
            guard from >= view.minY, to <= view.maxY else { continue }
            var blank = true
            rows: for y in Int(floor(from))...Int(ceil(to)) where y >= 0 && y < previous.height {
                var low = UInt8.max, high = UInt8.min
                for x in left..<right {
                    let value = previous[x, y]
                    low = min(low, value)
                    high = max(high, value)
                }
                if Int(high) - Int(low) > configuration.plainRange {
                    blank = false
                    break rows
                }
            }
            if blank { block.openEdges &= ~edge }
        }
    }

    /// Open edges of the known blocks a pass did not read themselves close when their band is in
    /// view now and the pass found no line that continues them; a block with such a line is
    /// read again together with it (one paragraph, read in two parts)
    private func closeEdges(read pass: Pass, found: [RecognizedBlock], atRest: Bool, except taken: Set<Int>,
                            time: TimeInterval) {
        let factor = Double(scale)
        let readings = found.map { CGRect(x: $0.rect.minX / factor, y: $0.rect.minY / factor, width: $0.rect.width / factor,
                                          height: $0.rect.height / factor) }
        let lineCounts = found.map(\.lineCount)
        for index in tracked.indices where tracked[index].openEdges != 0 && !taken.contains(tracked[index].id) {
            guard let start = pass.startRects[tracked[index].id] else { continue }
            let lineHeight = start.height / Double(max(1, tracked[index].lineCount))
            let goesOn = readings.indices.first { other in
                let reading = readings[other]
                guard !(start.contains(reading) || reading.contains(start)) else { return false }
                return mayContinue(start, lineHeight: lineHeight, reading,
                                   otherLineHeight: reading.height / Double(max(1, lineCounts[other])))
            }
            if let other = goesOn {
                let reading = readings[other]
                if let shift = pass.probes.displacement(atX: reading.midX, y: reading.midY) {
                    let air = configuration.rereadAir
                    let both = thumbnailRect(of: tracked[index]).union(reading.offsetBy(dx: shift.dx, dy: shift.dy))
                    plan.add(UnreadArea(rect: both.insetBy(dx: -air, dy: -air), kind: .reread, since: time))
                }
                continue
            }
            closeEdgesInView(&tracked[index], rect: start, atRest: atRest)
        }
    }

    /// A block that may be cut off is read again once all of it can be seen, or once the picture
    /// rests – unless it is a part of a paragraph that is known, or that paragraph once more (it
    /// was complete when it was taken), or the place was read often enough. A bar that stays never
    /// lets all of it be seen: a block that `settles` (held back only for what `TextLayout` saw,
    /// not garbage beyond doubt) is taken as it shows when it is read again at rest
    /// (`finishRecognition`). So such a place read at rest is read again at once, as far as it can
    /// be seen, and one read often enough while the picture moved is read again once it rests.
    /// Garbage beyond doubt (`RecognizedBlock.isGarbled`) read at rest is not read again: it
    /// stays what it is.
    private func askToReread(_ text: String, _ rect: CGRect, cut: Int, lineCount: Int,
                             shift: (dx: Double, dy: Double), pass: Pass, settles: Bool, isGarbled: Bool,
                             time: TimeInterval) {
        guard let previous else { return }
        let atRest = pass.startedAtRest && lastMotion < pass.startTime
        if isGarbled, atRest { return }
        let attempts = (pass.rereadAttempts ?? -1) + 1
        let now = rect.offsetBy(dx: shift.dx, dy: shift.dy)
        guard attempts < configuration.maxRereads else {
            if settles, !atRest {
                let place = now.insetBy(dx: -configuration.rereadAir, dy: -configuration.rereadAir)
                    .intersection(CGRect(x: 0, y: 0, width: previous.width, height: previous.height))
                if !place.isNull, place.width >= 1, place.height >= 1 {
                    plan.add(UnreadArea(rect: place, kind: .rest, since: time))
                }
            }
            return
        }
        if knownBlock(at: now, text: text) != nil { return }
        let lineHeight = rect.height / Double(max(1, lineCount))
        let air = configuration.rereadAir, reach = lineHeight * configuration.rereadReach + air
        let left = cut & FrameMotion.left != 0 ? reach : air, right = cut & FrameMotion.right != 0 ? reach : air
        let top = cut & FrameMotion.top != 0 ? reach : air, bottom = cut & FrameMotion.bottom != 0 ? reach : air
        var place = CGRect(x: now.minX - left, y: now.minY - top, width: now.width + left + right,
                           height: now.height + top + bottom)
        // the lines of the same paragraph that are known already are read with it
        for block in tracked where block.seen != nil {
            let other = thumbnailRect(of: block)
            if mayContinue(now, lineHeight: lineHeight, other, otherLineHeight: other.height
                                          / Double(max(1, block.lineCount))) {
                place = place.union(other.insetBy(dx: -air, dy: -air))
            }
        }
        if settles, atRest {
            // (what can be seen of it: a reread that cannot be seen completely waits for the next
            // movement)
            let edge = configuration.cutEdge
            var view = CGRect(x: 0, y: 0, width: previous.width, height: previous.height).insetBy(dx: edge, dy: edge)
            for area in areas where area.rect.contains(x: now.midX, y: now.midY) {
                view = view.intersection(CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width,
                                                height: area.rect.height).insetBy(dx: edge, dy: edge))
            }
            place = place.intersection(view)
            guard !place.isNull, place.width >= 1, place.height >= 1 else { return }
        }
        plan.add(UnreadArea(rect: place, kind: .reread, since: time, attempts: attempts))
    }

    /// A reading at `rect` (thumbnail pixels of the current frame) is a part of a paragraph that
    /// is known and can be seen: it lies inside it and its words are a run of the paragraph's
    /// words (a line or a word of it read alone, `TextSimilarity.isRun`). The index of that
    /// paragraph, nil if there is none.
    private func knownWhole(of rect: CGRect, text: String) -> Int? {
        knownContainer(of: rect) { TextSimilarity.isRun(text, of: $0.text) }
    }

    /// The first known block that can be seen, is larger than a reading at `rect` and holds it
    /// (`Configuration.containedShare` of it), and for which `accepts` holds
    private func knownContainer(of rect: CGRect, where accepts: (Block) -> Bool) -> Int? {
        let area = rect.width * rect.height
        guard area > 0 else { return nil }
        for (index, block) in tracked.enumerated() where block.seen != nil && block.lostSince == nil {
            let known = thumbnailRect(of: block)
            let common = known.intersection(rect)
            guard !common.isNull, common.width * common.height >= configuration.containedShare * area,
                  known.width * known.height > area, accepts(block) else { continue }
            return index
        }
        return nil
    }

    /// … or the paragraph known at its place read once more (nearly the same text): it was
    /// complete when it was taken
    private func knownBlock(at rect: CGRect, text: String) -> Int? {
        if let whole = knownWhole(of: rect, text: text) { return whole }
        for (index, block) in tracked.enumerated() where block.seen != nil && block.lostSince == nil {
            let known = thumbnailRect(of: block)
            let common = known.intersection(rect)
            guard !common.isNull else { continue }
            let overlap = common.width * common.height / max(known.width * known.height, rect.width * rect.height)
            if overlap >= configuration.sameBlockOverlap, TextSimilarity.isNearlySame(block.text, text) { return index }
        }
        return nil
    }

    /// What of a block can be seen in the current frame (thumbnail pixels): inside its patch's
    /// visible part, its scrolling area and the frame; nil when nothing
    private func visibleRect(of block: Block) -> CGRect? {
        guard let previous, let seen = block.seen else { return nil }
        let rect = thumbnailRect(of: block)
        var visible = rect
        if seen != block.inner {
            visible = visible.intersection(CGRect(x: block.x + Double(seen.x), y: block.y + Double(seen.y),
                                                  width: Double(seen.width), height: Double(seen.height)))
        }
        if let area = scrollArea(id: block.areaID) {
            visible = visible.intersection(CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width,
                                                  height: area.rect.height))
        }
        visible = visible.intersection(CGRect(x: 0, y: 0, width: previous.width, height: previous.height))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return visible
    }

    /// One block per text: of two blocks that can be seen and lie over each other, a part of a
    /// paragraph read alone gives way to the paragraph, otherwise the earlier reading gives way
    /// to the later one (the place shows something else now). Two texts one pass found apart
    /// both stay (their boxes overlap: a label in a paragraph's box, a tall line over the one
    /// below it); `TranslationCompositor.drawnBlocks` decides what is drawn. The one that stays
    /// shows the translation of the other until it has its own, when their texts are related.
    /// A later reading that lies inside a larger block gives way to it (one word of a paragraph,
    /// read while its place was not read whole), and a block that gives way to a reading that
    /// covers only a part of it: in both cases the larger place is read again
    /// (`askToReadPlace`, `attempts`).
    private func dropOverlaps(attempts: Int, time: TimeInterval) {
        var visible: [CGRect?] = tracked.map { $0.lostSince == nil ? visibleRect(of: $0) : nil }
        var dropped = Set<Int>()
        var places: [CGRect] = []
        for first in tracked.indices {
            for second in tracked.indices where second > first {
                guard !dropped.contains(first), !dropped.contains(second),
                      let a = visible[first], let b = visible[second] else { continue }
                let common = a.intersection(b)
                guard !common.isNull else { continue }
                let shared = common.width * common.height
                let smaller = min(a.width * a.height, b.width * b.height)
                guard smaller > 0, shared > configuration.overlapLimit * smaller else { continue }
                let related = TextSimilarity.isRelated(tracked[first].text, tracked[second].text)
                let loser: Int
                if related, shared >= configuration.containedShare * smaller {
                    // (a part read alone inside its paragraph)
                    let firstRect = thumbnailRect(of: tracked[first]), secondRect = thumbnailRect(of: tracked[second])
                    loser = firstRect.width * firstRect.height < secondRect.width * secondRect.height ? first : second
                } else if tracked[first].readAt == tracked[second].readAt {
                    // (read apart in one pass: two texts)
                    continue
                } else {
                    let older = tracked[first].readAt < tracked[second].readAt ? first : second
                    let newer = older == first ? second : first
                    let olderArea = older == first ? a.width * a.height : b.width * b.height
                    let newerArea = older == first ? b.width * b.height : a.width * a.height
                    if shared >= configuration.containedShare * newerArea, newerArea < olderArea {
                        // (a small reading inside a larger block does not stand in for it)
                        loser = newer
                        places.append(thumbnailRect(of: tracked[older]))
                    } else {
                        loser = older
                        if shared < configuration.containedShare * olderArea {
                            // (the rest of it was not read: what is there now is read whole)
                            places.append(thumbnailRect(of: tracked[older]).union(thumbnailRect(of: tracked[newer])))
                        }
                    }
                }
                let winner = loser == first ? second : first
                if related, shownTranslation(of: tracked[winner]) == nil {
                    tracked[winner].earlier = shownTranslation(of: tracked[loser])
                }
                dropped.insert(loser)
                visible[loser] = nil
            }
        }
        for place in places {
            askToReadPlace(place, attempts: attempts, time: time)
        }
        guard !dropped.isEmpty else { return }
        tracked = tracked.indices.filter { !dropped.contains($0) }.map { tracked[$0] }
    }

    /// The place of a block that a reading took over without reading all of it is read again
    /// whole, as a reread (`Configuration.maxRereads` times at most for a place): no translated
    /// block is lost for good to a reading of a part of its place
    private func askToReadPlace(_ rect: CGRect, attempts: Int, time: TimeInterval) {
        guard attempts < configuration.maxRereads, let previous else { return }
        let air = configuration.rereadAir
        let place = rect.insetBy(dx: -air, dy: -air)
            .intersection(CGRect(x: 0, y: 0, width: previous.width, height: previous.height))
        guard !place.isNull, place.width >= 1, place.height >= 1 else { return }
        plan.add(UnreadArea(rect: place, kind: .reread, since: time, attempts: attempts))
    }

    /// Two pieces of text may be lines of one paragraph: right above each other, with lines of
    /// about the same height and a gap of less than most of a line. (A rough test on the boxes
    /// alone: `TextLayout.blocks` decides by the size of the text, the gap and the alignment
    /// whether lines are one paragraph, once they are read together.)
    private func mayContinue(_ rect: CGRect, lineHeight: Double, _ other: CGRect, otherLineHeight: Double) -> Bool {
        guard other.minX < rect.maxX, rect.minX < other.maxX else { return false }
        let gap = max(other.minY - rect.maxY, rect.minY - other.maxY)
        return gap < configuration.paragraphGap * max(lineHeight, otherLineHeight)
            && abs(otherLineHeight - lineHeight) < configuration.sameLineHeight * max(lineHeight, otherLineHeight)
    }

    /// Two blocks right above each other with lines of the same height may be one paragraph that
    /// was read in two parts: both are read again together
    private func askToReadParagraphsTogether(_ taken: Set<Int>, time: TimeInterval) {
        for block in tracked where taken.contains(block.id) && block.seen != nil {
            let rect = thumbnailRect(of: block)
            let lineHeight = rect.height / Double(max(1, block.lineCount))
            for other in tracked where other.id != block.id && !taken.contains(other.id) && other.seen != nil {
                let otherRect = thumbnailRect(of: other)
                guard mayContinue(rect, lineHeight: lineHeight, otherRect,
                                                 otherLineHeight: otherRect.height / Double(max(1, other.lineCount)))
                else { continue }
                let air = configuration.rereadAir
                plan.add(UnreadArea(rect: rect.union(otherRect).insetBy(dx: -air, dy: -air),
                                    kind: .reread, since: time))
            }
        }
    }

    /// A block of a pass in the current frame: its patch from the frame that was read, found near
    /// where the probes say it went and checked against the picture; nil when it is not there
    private func makeBlock(_ found: RecognizedBlock, rect: CGRect, picture: LumaImage, shift: (dx: Double, dy: Double),
                           in current: LumaImage, mustShowWhole: Bool, keepsUnseen: Bool, time: TimeInterval) -> Block? {
        let margin = configuration.patchMargin
        let left = Int(floor(rect.minX)) - margin, top = Int(floor(rect.minY)) - margin
        let right = Int(ceil(rect.maxX)) + margin, bottom = Int(ceil(rect.maxY)) + margin
        let wanted = ThumbnailRect(x: left, y: top, width: right - left, height: bottom - top)
        let patchRect = wanted.intersection(ThumbnailRect(x: 0, y: 0, width: picture.width, height: picture.height))
        guard let patch = BlockPatch(image: picture, rect: patchRect) else { return nil }
        let inner = ThumbnailRect(x: Int(floor(rect.minX)) - patchRect.x, y: Int(floor(rect.minY)) - patchRect.y,
                              width: Int(ceil(rect.maxX)) - Int(floor(rect.minX)),
                              height: Int(ceil(rect.maxY)) - Int(floor(rect.minY)))
            .intersection(ThumbnailRect(x: 0, y: 0, width: patch.width, height: patch.height))
        guard !inner.isEmpty else { return nil }
        var x = Double(patchRect.x) + shift.dx, y = Double(patchRect.y) + shift.dy
        if shift.dx != 0 || shift.dy != 0,
           let located = matcher.locate(patch, in: current, x: x, y: y, part: inner, radius: configuration.carryRadius) {
            x = located.x
            y = located.y
        }
        var block = Block(id: 0, text: found.text, lineCount: max(1, found.lineCount), colors: found.colors,
                          width: Double(rect.width) * Double(scale), height: Double(rect.height) * Double(scale),
                          patch: patch, x: x, y: y,
                          insetX: rect.minX - Double(patchRect.x), insetY: rect.minY - Double(patchRect.y), inner: inner,
                          seen: nil, areaID: -1, lostSince: nil, earlier: nil, readAt: time,
                          openEdges: FrameMotion.top | FrameMotion.bottom, fit: 0,
                          texture: OverlayTracker.meanTexture(of: patch, inner: inner))
        if keepsUnseen {
            block.lostSince = time
            // (it must fit about as well as a block that is seen does, to be taken)
            block.fit = configuration.fitBase + configuration.sureFitTexture * block.texture
        } else {
            guard let (seen, fit) = check(block, in: current, x: x, y: y), !mustShowWhole || seen == inner else {
                return nil
            }
            block.seen = seen
            block.fit = fit
        }
        // the scrolling area it lies in, if it moved since the pass started
        if shift.dx != 0 || shift.dy != 0 {
            let center = thumbnailRect(of: block)
            if let index = movingArea(atX: center.midX, y: center.midY) { block.areaID = motionAreaIDs[index] }
        }
        if block.areaID < 0 {
            // (in a scrolling area that rests: it moves with it when it moves again)
            let center = thumbnailRect(of: block)
            var smallest = Int.max
            for area in areas where area.rect.contains(x: center.midX, y: center.midY) && area.rect.area < smallest {
                block.areaID = area.id
                smallest = area.rect.area
            }
        }
        return block
    }

    private static func meanTexture(of patch: BlockPatch, inner: ThumbnailRect) -> Double {
        var sum = 0.0
        for row in inner.y..<inner.maxY {
            sum += patch.rowTexture[row]
        }
        return sum / Double(max(1, inner.height))
    }

    /// Takes a new reading into the block known at its place, if there is one: same text (or
    /// nearly) keeps the block and its translation; related text keeps the translation shown
    /// as stale until the new one is there; other text replaces it. A part of a known paragraph
    /// read alone is left out (the paragraph took it). Returns the index of the block that took
    /// it, nil when it is a new block (then it has got an id). A reading that takes the place of
    /// a block whose place it does not cover has that place read again (`askToReadPlace`).
    private func absorb(_ block: inout Block, attempts: Int, time: TimeInterval) -> Int? {
        let rect = thumbnailRect(of: block)
        var match: Int?
        var bestOverlap = 0.0
        for (index, old) in tracked.enumerated() {
            let oldRect = thumbnailRect(of: old)
            let common = oldRect.intersection(rect)
            guard !common.isNull else { continue }
            let overlap = Double(common.width * common.height)
                / Double(max(oldRect.width * oldRect.height, rect.width * rect.height))
            if overlap >= configuration.sameBlockOverlap, overlap > bestOverlap {
                bestOverlap = overlap
                match = index
            }
        }
        guard let index = match else {
            // A part of a paragraph that is known, read alone (a line, a word): the paragraph stays.
            if let whole = knownWhole(of: rect, text: block.text) { return whole }
            // A line of it whose words are mostly the paragraph's but not a run of them (a counter,
            // a status in it changed): the paragraph stays until its place, read again, says how it
            // reads now. (Read with it by the same pass, it is a part of it after all.)
            let text = block.text, readAt = block.readAt
            if let changed = knownContainer(of: rect, where: { TextSimilarity.isRelated($0.text, text) }) {
                if tracked[changed].readAt != readAt {
                    askToReadPlace(thumbnailRect(of: tracked[changed]), attempts: attempts, time: time)
                }
                return changed
            }
            // A reading that holds blocks known before (lines of the paragraph read earlier) takes
            // their place, and shows the translation of the largest of them until its own is there.
            var largest: Block?
            var largestHeight = 0.0
            for old in tracked {
                let oldRect = thumbnailRect(of: old)
                let common = oldRect.intersection(rect)
                guard !common.isNull,
                      common.width * common.height >= configuration.containedShare * oldRect.width * oldRect.height,
                      TextSimilarity.isRelated(old.text, block.text), oldRect.height > largestHeight else { continue }
                largest = old
                largestHeight = oldRect.height
            }
            if let largest {
                block.earlier = shownTranslation(of: largest)
                block.id = largest.id
                if block.areaID < 0 { block.areaID = largest.areaID }
                if let place = tracked.firstIndex(where: { $0.id == largest.id }) {
                    tracked[place] = block
                    tracked.removeAll { old in
                        let oldRect = thumbnailRect(of: old)
                        let common = oldRect.intersection(rect)
                        return old.id != block.id && !common.isNull
                            && common.width * common.height >= configuration.containedShare * oldRect.width * oldRect.height
                            && TextSimilarity.isRelated(old.text, block.text)
                    }
                    return tracked.firstIndex { $0.id == block.id }
                }
            }
            block.id = nextBlockID
            nextBlockID += 1
            return nil
        }
        var old = tracked[index]
        let isSame = old.lineCount == block.lineCount && TextSimilarity.isNearlySame(old.text, block.text)
        if isSame {
            // keep what is known; take the new anchor when the old one no longer fits
            if old.seen == nil || old.lostSince != nil {
                old.patch = block.patch
                old.x = block.x
                old.y = block.y
                old.insetX = block.insetX
                old.insetY = block.insetY
                old.inner = block.inner
                old.seen = block.seen
                old.fit = block.fit
                old.texture = block.texture
                old.lostSince = nil
            }
            if abs(old.width - block.width) > configuration.sizeTolerance
                || abs(old.height - block.height) > configuration.sizeTolerance {
                old.width = block.width
                old.height = block.height
                old.patch = block.patch
                old.x = block.x
                old.y = block.y
                old.insetX = block.insetX
                old.insetY = block.insetY
                old.inner = block.inner
                old.seen = block.seen
                old.fit = block.fit
                old.texture = block.texture
            }
            if old.areaID < 0 { old.areaID = block.areaID }
            old.colors = block.colors
            old.readAt = block.readAt
            // (read once without anything that may continue it, it is complete)
            old.openEdges &= block.openEdges
            tracked[index] = old
            return index
        }
        if TextSimilarity.isRelated(old.text, block.text) {
            block.earlier = shownTranslation(of: old)
            block.id = old.id
        } else {
            block.id = nextBlockID
            nextBlockID += 1
        }
        if block.areaID < 0 { block.areaID = old.areaID }
        let oldRect = thumbnailRect(of: old)
        let common = oldRect.intersection(rect)
        if common.isNull || common.width * common.height < configuration.containedShare * oldRect.width * oldRect.height {
            // (the rest of the older block was not read: what is there now is read whole)
            askToReadPlace(oldRect.union(rect), attempts: attempts, time: time)
        }
        tracked[index] = block
        return index
    }

    // MARK: Changes of the picture

    /// The strips that came into view where moving content enters
    private func addEnteredStrips(_ motions: [FrameMotion], time: TimeInterval) {
        guard !motions.isEmpty else { return }
        var strips = [ThumbnailRect](repeating: .empty, count: motions.count)
        for tile in estimator.kinds.indices where estimator.kinds[tile] == .entered {
            let motion = Int(estimator.motionIndex[tile])
            strips[motion] = strips[motion].union(estimator.tileRect(tile))
        }
        for (index, strip) in strips.enumerated() where !strip.isEmpty {
            var rect = CGRect(x: strip.x, y: strip.y, width: strip.width, height: strip.height)
            if let area = scrollArea(id: motionAreaIDs[index]) {
                rect = rect.intersection(CGRect(x: area.rect.x, y: area.rect.y, width: area.rect.width,
                                                height: area.rect.height))
            }
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { continue }
            plan.add(UnreadArea(rect: rect, kind: .strip, since: time))
        }
    }

    /// Parts of the picture that changed in place: one area per group of touching tiles
    private func addChangedAreas(time: TimeInterval) {
        let columns = estimator.columns, count = estimator.kinds.count
        if visited.count != count {
            visited = [Bool](repeating: false, count: count)
        }
        for index in 0..<count {
            visited[index] = false
        }
        for start in 0..<count where estimator.kinds[start] == .changed && !visited[start] {
            var box = ThumbnailRect.empty
            var tiles = 0
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            while let tile = stack.popLast() {
                box = box.union(estimator.tileRect(tile))
                tiles += 1
                let column = tile % columns
                let neighbours = [column > 0 ? tile - 1 : -1, column + 1 < columns ? tile + 1 : -1, tile - columns,
                                  tile + columns]
                for next in neighbours where next >= 0 && next < count && !visited[next]
                    && estimator.kinds[next] == .changed {
                    visited[next] = true
                    stack.append(next)
                }
            }
            // (where content moves, a few tiles that fit no movement are damage of the codec)
            let center = (x: Double(box.x) + Double(box.width) / 2, y: Double(box.y) + Double(box.height) / 2)
            if tiles < configuration.minChangedTilesWhileMoving, movingArea(atX: center.x, y: center.y) != nil {
                continue
            }
            plan.add(UnreadArea(rect: CGRect(x: box.x, y: box.y, width: box.width, height: box.height), kind: .changed,
                                since: time))
        }
    }

    // MARK: Translations

    /// Distinct texts of the blocks on the screen that have no translation yet, in reading order,
    /// at most `limit`. They count as requested until `setTranslation` or `translationFailed` is
    /// called for them. A paragraph that may go on beyond what was seen of it is left out while
    /// the picture moves (`Configuration.continuationReach`, `restDelay`).
    func textsAwaitingTranslation(limit: Int, time: TimeInterval) -> [String] {
        var texts: [String] = []
        // what can be seen first, top to bottom
        let ordered = tracked.sorted { first, second in
            let firstSeen = first.seen != nil, secondSeen = second.seen != nil
            if firstSeen != secondSeen { return firstSeen }
            let a = thumbnailRect(of: first), b = thumbnailRect(of: second)
            return (a.minY, a.minX) < (b.minY, b.minX)
        }
        for block in ordered where texts.count < limit {
            let text = block.text
            if translations[text] != nil || requested.contains(text) || texts.contains(text) { continue }
            // (it may go on beyond what was seen of it: its text is not final while the picture moves)
            if block.openEdges != 0, time - lastMotion < configuration.restDelay { continue }
            if let failed = failedAt[text], time - failed < configuration.retryDelay { continue }
            requested.insert(text)
            texts.append(text)
        }
        return texts
    }

    /// A translation that equals the text (ignoring case and surrounding white space) means that
    /// there is nothing to show for it.
    func setTranslation(_ translation: String, for text: String) {
        requested.remove(text)
        failedAt[text] = nil
        if translations.count >= configuration.cacheLimit {
            let onScreen = Set(tracked.map(\.text))
            translations = translations.filter { onScreen.contains($0.key) }
        }
        translations[text] = translation
        for index in tracked.indices where tracked[index].text == text {
            tracked[index].earlier = nil
        }
    }

    /// Offered again by `textsAwaitingTranslation` after `Configuration.retryDelay`.
    func translationFailed(for text: String, time: TimeInterval) {
        requested.remove(text)
        failedAt[text] = time
    }

    /// Another language or another translator: every block needs a new translation.
    func forgetTranslations() {
        translations = [:]
        requested = []
        failedAt = [:]
        for index in tracked.indices {
            tracked[index].earlier = nil
        }
    }

    /// Forget everything, as before the first frame. A pass that is running is dropped: the
    /// caller may never finish or abandon it (its results belong to a turn that is over), and a
    /// new one can start at once. Its request can no longer match, because ids keep counting up.
    func reset() {
        forgetPicture()
        running = nil
        estimator.reset()
        previous = nil
        translations = [:]
        requested = []
        failedAt = [:]
    }

    // MARK: Internals

    private func forgetPicture() {
        tracked = []
        overlayHits = []
        overlayBoxes = []
        areas = []
        motionAreaIDs = []
        priors = []
        plan.reset()
        running?.isObsolete = true
        lastMotion = -1000
        lastSpeedShare = 0
    }

    private func shownTranslation(for text: String) -> String? {
        guard let translation = translations[text] else { return nil }
        let same = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(text.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        return same ? nil : translation
    }

    /// The translation drawn for a block: its own, or that of an earlier reading of its place
    private func shownTranslation(of block: Block) -> String? {
        if translations[block.text] != nil { return shownTranslation(for: block.text) }
        return block.earlier
    }
}

/// How much two readings of a place have in common
enum TextSimilarity {
    /// one letter in so many may be read differently in two readings of the same text
    static let misreadDivisor = 10
    /// texts longer than this (letters) are compared exactly: the edit distance grows with the
    /// square of the length
    static let longestCompared = 400
    /// two readings are related when this share of the words of the shorter one are in the other
    static let relatedWordShare = 0.6

    /// The same text but for a misread letter or two
    static func isNearlySame(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let a = Array(first.unicodeScalars), b = Array(second.unicodeScalars)
        let longest = max(a.count, b.count)
        let limit = max(1, longest / misreadDivisor)
        guard abs(a.count - b.count) * misreadDivisor <= longest, longest <= longestCompared else { return false }
        return editDistance(a, b, limit: limit) <= limit
    }

    /// One text grew out of the other (more lines of the same paragraph) or they share most words
    static func isRelated(_ first: String, _ second: String) -> Bool {
        let a = words(first), b = words(second)
        guard !a.isEmpty, !b.isEmpty else { return false }
        // (each word of one text counts once against an equal word of the other)
        var pool: [String: Int] = [:]
        for word in b {
            pool[word, default: 0] += 1
        }
        var common = 0
        for word in a {
            if let left = pool[word], left > 0 {
                pool[word] = left - 1
                common += 1
            }
        }
        return Double(common) >= relatedWordShare * Double(min(a.count, b.count))
    }

    /// The words of `part` are a run of the words of `whole`, but for a misread letter or two
    /// (`isNearlySame` against each run of as many words): a line or a piece of a line of that
    /// paragraph read alone, not a line of it that changed
    static func isRun(_ part: String, of whole: String) -> Bool {
        let piece = words(part), all = words(whole)
        guard !piece.isEmpty, piece.count <= all.count else { return false }
        let joined = piece.joined(separator: " ")
        for start in 0...(all.count - piece.count)
        where isNearlySame(all[start..<(start + piece.count)].joined(separator: " "), joined) {
            return true
        }
        return false
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }

    /// Levenshtein distance, giving up (returning more than `limit`) once it exceeds it
    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previousRow = Array(0...b.count)
        var currentRow = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            currentRow[0] = i
            var rowMinimum = i
            for j in 1...b.count {
                let substitution = previousRow[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                currentRow[j] = min(substitution, previousRow[j] + 1, currentRow[j - 1] + 1)
                rowMinimum = min(rowMinimum, currentRow[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previousRow, &currentRow)
        }
        return previousRow[b.count]
    }
}
